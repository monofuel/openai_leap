import
  std/[locks, monotimes, options, os, strformat, strutils, times],
  openai_leap/[chat, common, messages]

type
  Provider* = enum
    ProviderOpenAI
    ProviderAnthropic

  AgentSpec* = object
    name*: string
    role*: string
    isLeader*: bool
    provider*: Provider
    baseUrl*: string
    apiKey*: string
    model*: string

  CouncilConfig* = object
    pollIntervalMs*: int
    finalMarker*: string
    leaderReminderStart*: int
    leaderReminderStrong*: int
    leaderReminderForce*: int

  TranscriptEntry* = object
    agentName*: string
    text*: string

  CouncilResult* = object
    transcript*: seq[TranscriptEntry]
    finalAnswer*: string
    elapsedMs*: int64

  CouncilObj = object
    agents: seq[AgentSpec]
    apis: seq[OpenAiApi]
    question: string
    config: CouncilConfig
    stateLock: Lock
    outputLock: Lock
    transcript: seq[TranscriptEntry]
    finalSignalled: bool

  Council* = ptr CouncilObj

  AgentTask = object
    council: Council
    api: OpenAiApi
    model: string
    agentName: string
    isLeader: bool
    provider: Provider
    systemPrompt: string
    question: string

const
  DefaultConfig* = CouncilConfig(
    pollIntervalMs: 200,
    finalMarker: "# FINAL",
    leaderReminderStart: 4,
    leaderReminderStrong: 10,
    leaderReminderForce: 20
  )

proc newCouncil*(agents: seq[AgentSpec], question: string, config: CouncilConfig = DefaultConfig): Council =
  ## Create a new council instance. Call run() to execute the multi-agent discussion.
  result = cast[Council](allocShared0(sizeof(CouncilObj)))
  result.agents = agents
  result.question = question
  result.config = config
  result.transcript = @[]
  result.finalSignalled = false
  initLock(result.stateLock)
  initLock(result.outputLock)

  result.apis = newSeq[OpenAiApi](agents.len)
  for i, agent in agents:
    result.apis[i] = newOpenAiApi(baseUrl = agent.baseUrl, apiKey = agent.apiKey)

proc close*(council: Council) =
  ## Clean up council resources.
  for api in council.apis:
    api.close()
  deinitLock(council.stateLock)
  deinitLock(council.outputLock)
  deallocShared(council)

proc isFinalSignalled(council: Council): bool {.gcsafe.} =
  {.cast(gcsafe).}:
    withLock(council.stateLock):
      result = council.finalSignalled

proc setFinalSignalled(council: Council) {.gcsafe.} =
  {.cast(gcsafe).}:
    withLock(council.stateLock):
      council.finalSignalled = true

proc snapshotTranscript(council: Council): seq[TranscriptEntry] {.gcsafe.} =
  {.cast(gcsafe).}:
    withLock(council.stateLock):
      result = council.transcript

proc appendTranscript(council: Council, name: string, text: string) {.gcsafe.} =
  {.cast(gcsafe).}:
    withLock(council.stateLock):
      council.transcript.add(TranscriptEntry(agentName: name, text: text))

proc transcriptLen(council: Council): int {.gcsafe.} =
  {.cast(gcsafe).}:
    withLock(council.stateLock):
      result = council.transcript.len

template log(council: Council, msg: string) =
  withLock(council.outputLock):
    echo msg
    flushFile(stdout)

proc buildSystemPrompt*(council: Council, agent: AgentSpec): string =
  ## Build the per-agent system prompt with council framing and role.
  var roster = ""
  for a in council.agents:
    if a.isLeader:
      roster &= &"- {a.name} (leader)\n"
    else:
      roster &= &"- {a.name}\n"

  result = &"""Reasoning: low

You are {agent.name}, one of {council.agents.len} AI agents in a group chat that exists to answer the user's question. This is a rapid-fire conversation, not an essay assignment. Say partial ideas, half-formed reactions, and things you are not yet sure about. The conversation itself is how the reasoning happens — your words to the others ARE your reasoning.

Other agents in the chat:
{roster.strip()}

Your role: {agent.role}

Style rules:
- You are in a chat channel. Short messages, fast back-and-forth.
- Address others by name when reacting to what they said.
- Disagree out loud when you actually disagree. Be useful, not polite.
- Do not write essays. Do not restate. Do not summarize. Add one new thing per turn."""

  if agent.isLeader:
    result &= &"\n\nYou are the leader. You decide when the group has talked enough. When the conversation has converged on a real answer, emit a message that begins with \"{council.config.finalMarker}\" on its own line. Everything after that line is what the user sees — that one can be longer and well-structured. Until you fire \"{council.config.finalMarker}\", keep the chat going naturally."

proc renderTranscript(transcript: seq[TranscriptEntry]): string =
  ## Render the transcript as user-visible text with name prefixes.
  for entry in transcript:
    result &= &"{entry.agentName}: {entry.text}\n\n"

proc buildUserPayload(task: AgentTask, snapshot: seq[TranscriptEntry]): string =
  ## Build the user-message payload from the current transcript snapshot.
  let config = task.council.config
  result = &"User's question: {task.question}\n\n"
  if snapshot.len > 0:
    result &= "Chat so far:\n" & renderTranscript(snapshot)
  else:
    result &= "Chat so far: (empty — you're first to speak)\n\n"
  result &= &"You are {task.agentName}. Say your next message in the chat. One contribution."

  if task.isLeader:
    if snapshot.len >= config.leaderReminderForce:
      result &= &"\n\n[STRONG REMINDER for the leader: this chat has gone on a while. You should likely fire \"{config.finalMarker}\" now with the group's best synthesis. Start your message with \"{config.finalMarker}\" on its own line, then write the user-facing answer.]"
    elif snapshot.len >= config.leaderReminderStrong:
      result &= &"\n\n[Reminder for the leader: this chat is getting long. Decide whether the group has enough material to converge. If yes, fire \"{config.finalMarker}\" now — start a message with that marker on its own line, and put the answer after it.]"
    elif snapshot.len >= config.leaderReminderStart:
      result &= &"\n\n[Reminder for the leader: when the group has converged on an answer, emit a message starting with \"{config.finalMarker}\" on its own line. Everything after that line is the user-facing answer.]"

proc streamOpenAI(task: AgentTask, userPayload: string): tuple[text: string, chunks: int] =
  ## Stream a chat completion via the OpenAI-compat path.
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
  var lastReport = getMonoTime()
  while true:
    let chunk = stream.next()
    if chunk.isNone:
      break
    inc result.chunks
    if chunk.get.choices.len > 0 and chunk.get.choices[0].delta.isSome:
      let content = chunk.get.choices[0].delta.get.content
      if content.len > 0:
        result.text &= content
    let now = getMonoTime()
    if inMilliseconds(now - lastReport) >= 1000:
      task.council.log &"  [{task.agentName}] streaming: {result.chunks} chunks, {result.text.len} chars..."
      lastReport = now

proc callAnthropic(task: AgentTask, userPayload: string): tuple[text: string, chunks: int] =
  ## Non-streaming Anthropic call via the unified converter pattern.
  {.cast(gcsafe).}:
    let respReq = CreateResponseReq()
    respReq.model = task.model
    respReq.max_output_tokens = option(4096)
    respReq.instructions = option(task.systemPrompt)
    respReq.input = option(@[
      ResponseInput(
        `type`: "message",
        role: option("user"),
        content: option(@[ResponseInputContent(`type`: "input_text", text: option(userPayload))])
      )
    ])
    var msgReq = toMessageReq(respReq)
    var emptyTools = newResponseToolsTable()
    let msgResp = task.api.createMessageWithTools(msgReq, emptyTools)
    let unified = toOpenAiResponse(msgResp)
    if unified.output_text.isSome:
      result.text = unified.output_text.get
    result.chunks = 1

proc hasFinalMarker*(text: string, marker: string = "# FINAL"): bool =
  ## Detect the final marker at the start of a line, ignoring fenced code blocks.
  var inFence = false
  for line in text.splitLines():
    if line.startsWith("```"):
      inFence = not inFence
      continue
    if not inFence and line.startsWith(marker):
      result = true
      break

proc extractFinal*(text: string, marker: string = "# FINAL"): string =
  ## Extract everything after the final marker line.
  var inFence = false
  var foundIdx = -1
  let lines = text.splitLines()
  for i, line in lines:
    if line.startsWith("```"):
      inFence = not inFence
      continue
    if not inFence and line.startsWith(marker):
      foundIdx = i
      break
  if foundIdx >= 0:
    result = lines[(foundIdx + 1) .. ^1].join("\n").strip()

proc fireOnce(task: AgentTask, snapshot: seq[TranscriptEntry]): tuple[text: string, failed: bool, error: string] =
  ## Stream one completion based on the given transcript snapshot.
  let started = getMonoTime()
  let userPayload = buildUserPayload(task, snapshot)
  task.council.log &"  [{task.agentName}] streaming (transcript len: {snapshot.len})..."
  try:
    let streamed = case task.provider
      of ProviderOpenAI:    streamOpenAI(task, userPayload)
      of ProviderAnthropic: callAnthropic(task, userPayload)
    let elapsed = inMilliseconds(getMonoTime() - started)
    task.council.log &"  [{task.agentName}] done in {elapsed}ms ({streamed.chunks} chunks, {streamed.text.len} chars)"
    result.text = streamed.text
  except CatchableError as e:
    let elapsed = inMilliseconds(getMonoTime() - started)
    task.council.log &"  [{task.agentName}] FAILED in {elapsed}ms: {e.msg}"
    result.failed = true
    result.error = e.msg

proc agentLoop(task: AgentTask) {.thread.} =
  ## Per-agent loop: fire whenever others have spoken since our last contribution.
  var seenLen = 0
  while true:
    if task.council.isFinalSignalled():
      task.council.log &"  [{task.agentName}] stopping: final signalled"
      break

    let snapshot = task.council.snapshotTranscript()

    var shouldFire = seenLen == 0
    if not shouldFire:
      for i in seenLen ..< snapshot.len:
        if snapshot[i].agentName != task.agentName:
          shouldFire = true
          break

    if not shouldFire:
      sleep(task.council.config.pollIntervalMs)
      continue

    let res = fireOnce(task, snapshot)
    if task.council.isFinalSignalled():
      task.council.log &"  [{task.agentName}] discarding response (final already signalled mid-stream)"
      break

    if res.failed:
      task.council.appendTranscript(task.agentName, &"[FAILED: {res.error}]")
    else:
      task.council.appendTranscript(task.agentName, res.text)
    seenLen = task.council.transcriptLen()

    if task.isLeader and not res.failed and hasFinalMarker(res.text, task.council.config.finalMarker):
      task.council.log &"  [{task.agentName}] emitted {task.council.config.finalMarker} — signalling stop"
      task.council.setFinalSignalled()
      break

proc run*(council: Council): CouncilResult =
  ## Execute the council discussion. Blocks until the leader fires the final marker or all agents stop.
  var leaderName = ""
  for a in council.agents:
    if a.isLeader:
      leaderName = a.name

  council.log "Multi-agent council starting"
  council.log &"  question: {council.question}"
  council.log &"  agents:"
  for agent in council.agents:
    let leaderTag = if agent.isLeader: " (leader)" else: ""
    council.log &"    {agent.name}{leaderTag}: {agent.model} @ {agent.baseUrl}"
  council.log ""

  let runStart = getMonoTime()

  var threads = newSeq[Thread[AgentTask]](council.agents.len)
  for i, agent in council.agents:
    let task = AgentTask(
      council: council,
      api: council.apis[i],
      model: agent.model,
      agentName: agent.name,
      isLeader: agent.isLeader,
      provider: agent.provider,
      systemPrompt: council.buildSystemPrompt(agent),
      question: council.question
    )
    council.log &"  [{agent.name}] spawning agent loop"
    createThread(threads[i], agentLoop, task)

  joinThreads(threads)
  let totalElapsed = inMilliseconds(getMonoTime() - runStart)

  result.transcript = council.snapshotTranscript()
  result.elapsedMs = totalElapsed

  for i in countdown(result.transcript.high, 0):
    let entry = result.transcript[i]
    if entry.agentName == leaderName and hasFinalMarker(entry.text, council.config.finalMarker):
      result.finalAnswer = extractFinal(entry.text, council.config.finalMarker)
      break
