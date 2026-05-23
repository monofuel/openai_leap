import
  std/[locks, monotimes, options, os, sequtils, strformat, strutils, times],
  openai_leap

const
  BaseUrl = "http://localhost:1234/v1"
  Model = "gpt-oss-20b"
  ApiKey = "lm-studio"
  PollIntervalMs = 200
  FinalMarker = "# FINAL"
  # Test prompts at increasing difficulty. Uncomment one and comment the rest.
  # UserQuestion = "What is the capital of France?"                          # trivial: convergence sanity check
  UserQuestion = "What causes the seasons on Earth?"                         # medium: factual, has a common misconception (proximity vs axial tilt)
  # UserQuestion = "What is a Wild n' Wooly Shambler?"                       # hard: hallucination probe, agents will bicker

type
  AgentSpec = object
    name: string
    role: string
    isLeader: bool

  TranscriptEntry = object
    agentName: string
    text: string

  AgentTask = object
    api: OpenAiApi
    model: string
    agentName: string
    isLeader: bool
    systemPrompt: string
    question: string

let
  Agents = @[
    AgentSpec(
      name: "Alice",
      role: "Synthesizer — weigh perspectives, find common ground, decide when to converge.",
      isLeader: true
    ),
    AgentSpec(
      name: "Bob",
      role: "Skeptic — challenge assumptions, point out gaps. Only disagree where there is real doubt.",
      isLeader: false
    ),
    AgentSpec(
      name: "Carol",
      role: "Researcher — ground claims in concrete facts. Add specifics others missed.",
      isLeader: false
    )
  ]

var
  stateLock: Lock
  outputLock: Lock
  transcript: seq[TranscriptEntry] = @[]
  finalSignalled: bool = false

initLock(stateLock)
initLock(outputLock)

proc isFinalSignalled(): bool {.gcsafe.} =
  ## Check whether the leader (or main thread) has signalled stop.
  {.cast(gcsafe).}:
    withLock(stateLock):
      result = finalSignalled

proc setFinalSignalled() {.gcsafe.} =
  ## Signal all agents that the conversation is over.
  {.cast(gcsafe).}:
    withLock(stateLock):
      finalSignalled = true

proc snapshotTranscript(): seq[TranscriptEntry] {.gcsafe.} =
  ## Read a consistent copy of the current transcript.
  {.cast(gcsafe).}:
    withLock(stateLock):
      result = transcript

proc appendTranscript(name: string, text: string) {.gcsafe.} =
  ## Atomically append one entry to the shared transcript.
  {.cast(gcsafe).}:
    withLock(stateLock):
      transcript.add(TranscriptEntry(agentName: name, text: text))

proc transcriptLen(): int {.gcsafe.} =
  ## Current shared transcript length.
  {.cast(gcsafe).}:
    withLock(stateLock):
      result = transcript.len

template log(msg: string) =
  ## Thread-safe stdout writer with explicit flush.
  withLock(outputLock):
    echo msg
    flushFile(stdout)

proc buildSystemPrompt(agent: AgentSpec): string =
  ## Build the per-agent system prompt with council framing and role.
  result = &"""Reasoning: low

You are {agent.name}, one of three AI agents in a group chat that exists to answer the user's question. This is a rapid-fire conversation, not an essay assignment. Say partial ideas, half-formed reactions, and things you are not yet sure about. The conversation itself is how the reasoning happens — your words to the others ARE your reasoning.

Other agents in the chat:
- Alice (leader)
- Bob
- Carol

Your role: {agent.role}

Style rules:
- You are in a chat channel. Short messages, fast back-and-forth.
- Address others by name when reacting to what they said.
- Disagree out loud when you actually disagree. Be useful, not polite.
- Do not write essays. Do not restate. Do not summarize. Add one new thing per turn."""

  if agent.isLeader:
    result &= "\n\nYou are the leader. You decide when the group has talked enough. When the conversation has converged on a real answer, emit a message that begins with \"# FINAL\" on its own line. Everything after that line is what the user sees — that one can be longer and well-structured. Until you fire \"# FINAL\", keep the chat going naturally."

proc renderTranscript(transcript: seq[TranscriptEntry]): string =
  ## Render the transcript as user-visible text with name prefixes.
  for entry in transcript:
    result &= &"{entry.agentName}: {entry.text}\n\n"

proc buildUserPayload(question: string, snapshot: seq[TranscriptEntry], agentName: string, isLeader: bool): string =
  ## Build the user-message payload from the current transcript snapshot.
  ## Leaders also get a reminder to fire # FINAL when the group has converged.
  result = &"User's question: {question}\n\n"
  if snapshot.len > 0:
    result &= "Chat so far:\n" & renderTranscript(snapshot)
  else:
    result &= "Chat so far: (empty — you're first to speak)\n\n"
  result &= &"You are {agentName}. Say your next message in the chat. One contribution."

  if isLeader:
    # Escalating reminder so the leader keeps the # FINAL mechanism in mind as the chat grows.
    if snapshot.len >= 4 and snapshot.len < 10:
      result &= "\n\n[Reminder for the leader: when the group has converged on an answer, emit a message starting with \"# FINAL\" on its own line. Everything after that line is the user-facing answer.]"
    elif snapshot.len >= 10 and snapshot.len < 20:
      result &= "\n\n[Reminder for the leader: this chat is getting long. Decide whether the group has enough material to converge. If yes, fire \"# FINAL\" now — start a message with that marker on its own line, and put the answer after it.]"
    elif snapshot.len >= 20:
      result &= "\n\n[STRONG REMINDER for the leader: this chat has gone on a while. You should likely fire \"# FINAL\" now with the group's best synthesis. Start your message with \"# FINAL\" on its own line, then write the user-facing answer.]"

proc fireOnce(task: AgentTask, snapshot: seq[TranscriptEntry]): tuple[text: string, failed: bool, error: string] =
  ## Stream one completion based on the given transcript snapshot. Returns the response text or an error.
  let started = getMonoTime()
  let userPayload = buildUserPayload(task.question, snapshot, task.agentName, task.isLeader)
  log &"  [{task.agentName}] streaming (transcript len: {snapshot.len})..."
  try:
    let req = CreateChatCompletionReq()
    req.model = task.model
    req.messages = @[
      Message(
        role: "system",
        content: option(@[MessageContentPart(`type`: "text", text: option(task.systemPrompt))])
      ),
      Message(
        role: "user",
        content: option(@[MessageContentPart(`type`: "text", text: option(userPayload))])
      )
    ]
    let stream = task.api.streamChatCompletion(req)
    var buf = ""
    var chunkCount = 0
    var lastReport = getMonoTime()
    while true:
      let chunk = stream.next()
      if chunk.isNone:
        break
      inc chunkCount
      if chunk.get.choices.len > 0 and chunk.get.choices[0].delta.isSome:
        let content = chunk.get.choices[0].delta.get.content
        if content.len > 0:
          buf &= content
      # Report progress roughly every second so the user sees motion without spam.
      let now = getMonoTime()
      if inMilliseconds(now - lastReport) >= 1000:
        log &"  [{task.agentName}] streaming: {chunkCount} chunks, {buf.len} chars..."
        lastReport = now
    let elapsed = inMilliseconds(getMonoTime() - started)
    log &"  [{task.agentName}] done in {elapsed}ms ({chunkCount} chunks, {buf.len} chars)"
    result.text = buf
  except CatchableError as e:
    # Per-agent error isolation. One stuck agent must not kill the council.
    let elapsed = inMilliseconds(getMonoTime() - started)
    log &"  [{task.agentName}] FAILED in {elapsed}ms: {e.msg}"
    result.failed = true
    result.error = e.msg

proc hasFinalMarker(text: string): bool =
  ## Detect the # FINAL marker at the start of a line, ignoring fenced code blocks.
  var inFence = false
  for line in text.splitLines():
    if line.startsWith("```"):
      inFence = not inFence
      continue
    if not inFence and line.startsWith(FinalMarker):
      result = true
      break

proc extractFinal(text: string): string =
  ## Extract everything after the # FINAL line.
  var inFence = false
  var foundIdx = -1
  let lines = text.splitLines()
  for i, line in lines:
    if line.startsWith("```"):
      inFence = not inFence
      continue
    if not inFence and line.startsWith(FinalMarker):
      foundIdx = i
      break
  if foundIdx >= 0:
    result = lines[(foundIdx + 1) .. ^1].join("\n").strip()

proc agentLoop(task: AgentTask) {.thread.} =
  ## Per-agent loop: fire whenever others have spoken since our last contribution. No rounds.
  var seenLen = 0  # transcript length right after our most recent append (0 = never fired)
  while true:
    if isFinalSignalled():
      log &"  [{task.agentName}] stopping: final signalled"
      break

    let snapshot = snapshotTranscript()

    # Decide whether to fire. First time (seenLen == 0) we always fire.
    # Otherwise we only fire if at least one OTHER agent has spoken since our last append.
    var shouldFire = seenLen == 0
    if not shouldFire:
      for i in seenLen ..< snapshot.len:
        if snapshot[i].agentName != task.agentName:
          shouldFire = true
          break

    if not shouldFire:
      sleep(PollIntervalMs)
      continue

    let res = fireOnce(task, snapshot)
    if isFinalSignalled():
      # Someone (probably the leader) finished while we were streaming. Discard our reply.
      log &"  [{task.agentName}] discarding response (final already signalled mid-stream)"
      break

    if res.failed:
      appendTranscript(task.agentName, &"[FAILED: {res.error}]")
    else:
      appendTranscript(task.agentName, res.text)
    seenLen = transcriptLen()

    if task.isLeader and not res.failed and hasFinalMarker(res.text):
      log &"  [{task.agentName}] emitted # FINAL — signalling stop"
      setFinalSignalled()
      break

proc main() =
  ## Spawn one thread per agent. Each agent runs its own async loop. Joins when leader signals stop.
  let api = newOpenAiApi(baseUrl = BaseUrl, apiKey = ApiKey)
  defer: api.close()

  var leaderName = ""
  for a in Agents:
    if a.isLeader:
      leaderName = a.name

  log "Multi-agent council starting"
  log &"  baseUrl: {BaseUrl}"
  log &"  model:   {Model}"
  log &"  agents:  " & Agents.mapIt(it.name).join(", ") & &" (leader: {leaderName})"
  log &"  question: {UserQuestion}"
  log ""

  let runStart = getMonoTime()

  var threads = newSeq[Thread[AgentTask]](Agents.len)
  for i, agent in Agents:
    let task = AgentTask(
      api: api,
      model: Model,
      agentName: agent.name,
      isLeader: agent.isLeader,
      systemPrompt: buildSystemPrompt(agent),
      question: UserQuestion
    )
    log &"  [{agent.name}] spawning agent loop"
    createThread(threads[i], agentLoop, task)

  joinThreads(threads)
  let totalElapsed = inMilliseconds(getMonoTime() - runStart)

  let finalTranscript = snapshotTranscript()
  log &"\n=== Transcript ({finalTranscript.len} messages, total wall-clock: {totalElapsed}ms) ==="
  for entry in finalTranscript:
    log &"\n--- {entry.agentName} ---\n{entry.text}"

  # Extract the leader's # FINAL message from the transcript.
  var finalAnswer = ""
  for i in countdown(finalTranscript.high, 0):
    let entry = finalTranscript[i]
    if entry.agentName == leaderName and hasFinalMarker(entry.text):
      finalAnswer = extractFinal(entry.text)
      break

  log "\n=== Result ==="
  if finalAnswer.len > 0:
    log finalAnswer
  else:
    log "(No # FINAL answer in transcript.)"

when isMainModule:
  main()
