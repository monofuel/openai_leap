import
  std/[json, math, options, os, tables],
  openai_leap

proc verify(response: CreateSystemOneResp) =
  ## Verify a mixed set of live decisions without assuming exact probabilities.
  doAssert response.model.len > 0
  doAssert response.answers.len == 3
  doAssert response.usage.input_tokens > 0
  doAssert response.usage.output_tokens >= 0
  let
    action = response.answers["action"]
    wait = response.answers["wait"]
    urgency = response.answers["urgency"]
  doAssert action.`type` == "choice"
  doAssert action.choice.get == "stay"
  doAssert action.probabilities.get.len == 3
  doAssert wait.`type` == "noul"
  doAssert wait.noul.get in 0.0..1.0
  doAssert urgency.`type` == "score"
  doAssert urgency.score.get in 0.0..2.0
  doAssert urgency.legend.get.len == 3
  for answer in [action, urgency]:
    doAssert answer.confidence.get in 0.0..1.0
    var total = 0.0
    for _, probability in answer.probabilities.get:
      doAssert probability in 0.0..1.0
      total += probability
    doAssert abs(total - 1.0) < 0.000001

proc main() =
  ## Exercise the TypeSafe endpoint on a loaded decision model.
  let
    api = newOpenAiApi(getEnv("SYSTEMONE_BASE_URL", "http://10.11.2.22:1234/v1"),
      apiKey = getEnv("SYSTEMONE_API_KEY", "lm-studio"), curlTimeout = 30)
    model = getEnv("SYSTEMONE_MODEL", "kev-4b")
  defer: api.close()
  var questions: OrderedTable[string, SystemOneQuestion]
  questions["action"] = SystemOneQuestion(`type`: "choice", instructions: %"What should Wayfarer do next?",
    criteria: some(%*{"stay": "stop and wait here", "follow": "walk after the player", "idle": "keep chatting"}))
  questions["wait"] = SystemOneQuestion(`type`: "noul", instructions: %"Should Wayfarer wait here?")
  questions["urgency"] = SystemOneQuestion(`type`: "score", instructions: %"How urgent is this request?",
    criteria: some(%*["not urgent", "somewhat urgent", "very urgent"]))
  verify api.createSystemOne(model, "Player tells Wayfarer: wait here while I collect iron.", questions)
  verify api.createSystemOne(CreateSystemOneReq(model: model,
    state: %*{"player": "monofuel", "chat": "Wayfarer, wait here while I collect iron."}, questions: questions))

when isMainModule:
  main()
