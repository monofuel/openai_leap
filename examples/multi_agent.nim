import
  std/[os, strformat],
  openai_leap

const
  LocalBaseUrl = "http://localhost:1234/v1"
  LocalModel = "gpt-oss-20b"
  LocalApiKey = "lm-studio"
  CloudBaseUrl = "https://api.openai.com/v1"
  # Uncomment one question at a time:
  # UserQuestion = "What is the capital of France?"                          # trivial
  UserQuestion = "What causes the seasons on Earth?"                         # medium
  # UserQuestion = "What is a Wild n' Wooly Shambler?"                       # hard: hallucination probe

let agents = @[
  AgentSpec(
    name: "Alice",
    role: "Synthesizer — weigh perspectives, find common ground, decide when to converge.",
    isLeader: true,
    provider: ProviderOpenAI,
    baseUrl: LocalBaseUrl, apiKey: LocalApiKey, model: LocalModel
  ),
  AgentSpec(
    name: "Bob",
    role: "Skeptic — challenge assumptions, point out gaps. Only disagree where there is real doubt.",
    isLeader: false,
    provider: ProviderOpenAI,
    baseUrl: LocalBaseUrl, apiKey: LocalApiKey, model: LocalModel
  ),
  AgentSpec(
    name: "Carol",
    role: "Researcher — ground claims in concrete facts. Add specifics others missed.",
    isLeader: false,
    provider: ProviderOpenAI,
    baseUrl: LocalBaseUrl, apiKey: LocalApiKey, model: LocalModel
  ),
  AgentSpec(
    name: "Dave",
    role: "Outside voice — you come from a different background than the others. Push back when the group is converging too easily and probe whether they are missing angles or settling for groupthink.",
    isLeader: false,
    provider: ProviderOpenAI,
    baseUrl: CloudBaseUrl, apiKey: getEnv("OPENAI_API_KEY", ""), model: "gpt-5.4-mini"
  ),
  AgentSpec(
    name: "Eve",
    role: "Pragmatist — translate the discussion into concrete, actionable, real-world implications. Cut through abstraction.",
    isLeader: false,
    provider: ProviderAnthropic,
    baseUrl: "https://api.anthropic.com/v1", apiKey: getEnv("ANTHROPIC_API_KEY", ""), model: "claude-haiku-4-5"
  )
]

proc main() =
  ## Run a multi-agent council discussion.
  let council = newCouncil(agents, UserQuestion)
  defer: council.close()

  let result = council.run()

  echo &"\n=== Transcript ({result.transcript.len} messages, total wall-clock: {result.elapsedMs}ms) ==="
  for entry in result.transcript:
    echo &"\n--- {entry.agentName} ---\n{entry.text}"

  echo "\n=== Result ==="
  if result.finalAnswer.len > 0:
    echo result.finalAnswer
  else:
    echo "(No # FINAL answer in transcript.)"

when isMainModule:
  main()
