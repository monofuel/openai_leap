import
  std/[json, net, os, options, strutils, tables, unittest],
  jsony,
  openai_leap

type
  CapturedRequest = object
    requestLine: string
    headers: Table[string, string]
    body: string

  ServerConfig = object
    ports: ptr Channel[int]
    requests: ptr Channel[CapturedRequest]
    status: string
    response: string
    delayMs: int

const
  MixedResponse = """{
    "model":"kev-4b",
    "answers":{
      "action":{"type":"choice","choice":"stay","probabilities":{"stay":0.8,"follow":0.2},"confidence":0.6},
      "wait":{"type":"noul","noul":0.75},
      "urgency":{"type":"score","score":0.25,"legend":{"0":"low","1":"high"},"probabilities":{"0":0.75,"1":0.25},"confidence":0.5}
    },
    "usage":{"input_tokens":56,"output_tokens":0}
  }"""

proc questions(): OrderedTable[string, SystemOneQuestion] =
  ## Construct a mixed request with stable question ordering.
  result["action"] = SystemOneQuestion(`type`: "choice", instructions: %"What should Wayfarer do?",
    criteria: some(%*{"stay": "wait here", "follow": newJNull()}))
  result["wait"] = SystemOneQuestion(`type`: "noul", instructions: %"Should Wayfarer wait?")
  result["urgency"] = SystemOneQuestion(`type`: "score", instructions: %"How urgent is this?",
    criteria: some(%*["low", "high"]))

proc request(): CreateSystemOneReq =
  ## Construct a text request for the fixture.
  CreateSystemOneReq(model: "kev-4b", state: %"wait here", questions: questions())

proc serve(config: ServerConfig) {.thread.} =
  ## Receive one HTTP request and return the configured response.
  let listener = newSocket()
  defer: listener.close()
  listener.bindAddr(Port(0), "127.0.0.1")
  listener.listen()
  config.ports[].send(listener.getLocalAddr()[1].int)
  var
    client: Socket
    captured: CapturedRequest
  listener.accept(client)
  defer: client.close()
  captured.requestLine = client.recvLine(timeout = 5000)
  while true:
    let line = client.recvLine(timeout = 5000)
    if line.strip.len == 0:
      break
    let separator = line.find(':')
    doAssert separator > 0
    captured.headers[line[0..<separator].toLowerAscii] = line[separator + 1..^1].strip
  let length = parseInt(captured.headers["content-length"])
  while captured.body.len < length:
    let chunk = client.recv(length - captured.body.len, timeout = 5000)
    doAssert chunk.len > 0
    captured.body.add chunk
  config.requests[].send(captured)
  if config.delayMs > 0:
    sleep(config.delayMs)
    return
  client.send("HTTP/1.1 " & config.status & "\r\nContent-Type: application/json\r\n" &
    "Connection: close\r\nContent-Length: " & $config.response.len & "\r\n\r\n" & config.response)

proc withServer(
  callback: proc(api: OpenAiApi, requests: var Channel[CapturedRequest]),
  status = "200 OK",
  response = MixedResponse,
  delayMs = 0
) =
  ## Run a client check against an isolated HTTP fixture.
  var
    ports: Channel[int]
    requests: Channel[CapturedRequest]
    server: Thread[ServerConfig]
  ports.open()
  requests.open()
  defer:
    requests.close()
    ports.close()
  createThread(server, serve, ServerConfig(ports: addr ports, requests: addr requests,
    status: status, response: response, delayMs: delayMs))
  defer: joinThread(server)
  let api = newOpenAiApi("http://127.0.0.1:" & $ports.recv() & "/v1",
    apiKey = "default-token", organization = "default-org", curlTimeout = 5)
  defer: api.close()
  callback(api, requests)

suite "System One serialization":
  test "mixed questions preserve wire shapes and omit optional fields":
    let
      req = request()
      serialized = toJson(req)
      body = parseJson(serialized)
    check body["state"].getStr == "wait here"
    check body["questions"].kind == JObject
    check body["questions"]["action"]["criteria"]["follow"].kind == JNull
    check body["questions"]["urgency"]["criteria"] == %*["low", "high"]
    check not body["questions"]["wait"].hasKey("criteria")
    check not body.hasKey("files")
    check not body.hasKey("images")
    var names: seq[string]
    for name, _ in body["questions"]:
      names.add name
    check names == @["action", "wait", "urgency"]
    let roundTrip = fromJson(serialized, CreateSystemOneReq)
    check parseJson(toJson(roundTrip)) == body

  test "structured state instructions and criteria remain JSON values":
    let req = request()
    req.state = %*{"chat": [{"player": "monofuel", "text": "wait"}], "inventory": ["iron"]}
    req.questions["action"].instructions = %*{"question": "Pick a task", "context": ["base", "farm"]}
    req.questions["action"].criteria = some(%*{"stay": {"goal": "wait"}, "follow": ["walk", "behind"]})
    req.questions["wait"].instructions = %*["Should Wayfarer wait?", {"player": "monofuel"}]
    req.questions["wait"].criteria = some(%*{"true": {"description": "wait"}, "false": ["move"]})
    req.questions["urgency"].criteria = some(%*[{"level": "low"}, ["high", "urgent"]])
    let body = parseJson(toJson(req))
    check body["state"] == req.state
    for name, question in req.questions:
      check body["questions"][name]["instructions"] == question.instructions
      check body["questions"][name]["criteria"] == question.criteria.get
    req.state = %*[{"player": "monofuel"}, "wait here"]
    check parseJson(toJson(req))["state"] == req.state

  test "media fields and explicit nulls are preserved":
    let req = request()
    req.state = newJNull()
    req.files = some(@["data:audio/wav;base64,YXVkaW8="])
    req.images = some(@["data:image/png;base64,aW1hZ2U="])
    req.questions["wait"].criteria = some(newJNull())
    let body = parseJson(toJson(req))
    check body["state"].kind == JNull
    check body["questions"]["wait"]["criteria"].kind == JNull
    check body["files"] == %req.files.get
    check body["images"] == %req.images.get
    req.files = some(newSeq[string]())
    check parseJson(toJson(req))["files"] == newJArray()

  test "nil request and question references serialize as null":
    check toJson(CreateSystemOneReq(nil)) == "null"
    check toJson(SystemOneQuestion(nil)) == "null"

suite "System One response parsing":
  test "mixed answers retain fractional values and type-dependent fields":
    let response = fromJson(MixedResponse, CreateSystemOneResp)
    check response.model == "kev-4b"
    check response.answers.len == 3
    check response.answers["action"].choice.get == "stay"
    check response.answers["action"].probabilities.get["stay"] == 0.8
    check response.answers["action"].confidence.get == 0.6
    check response.answers["action"].noul.isNone
    check response.answers["wait"].noul.get == 0.75
    check response.answers["wait"].choice.isNone
    check response.answers["wait"].confidence.isNone
    check response.answers["urgency"].score.get == 0.25
    check response.answers["urgency"].legend.get["0"] == "low"
    check response.answers["urgency"].probabilities.get["1"] == 0.25
    check response.usage.input_tokens == 56
    check response.usage.output_tokens == 0

  test "nonzero output usage and unknown response fields are accepted":
    let response = fromJson("""{"model":"jev-latest","answers":{"ok":{"type":"noul","noul":0}},
      "usage":{"input_tokens":12,"output_tokens":20},"extension":"ignored"}""", CreateSystemOneResp)
    check response.answers["ok"].noul.get == 0.0
    check response.usage.output_tokens == 20

suite "System One HTTP client":
  test "request overload posts exact body and preserves caller data":
    withServer(proc(api: OpenAiApi, requests: var Channel[CapturedRequest]) =
      let
        req = request()
        original = toJson(req)
        response = api.createSystemOne(req)
        captured = requests.recv()
      check captured.requestLine == "POST /v1/systemone HTTP/1.1"
      check captured.headers["content-type"] == "application/json"
      check captured.headers["authorization"] == "Bearer default-token"
      check captured.headers["organization"] == "default-org"
      check captured.body == original
      check toJson(req) == original
      check response.answers["action"].choice.get == "stay"
    )

  test "text overload passes per-request options and preserves raw text":
    withServer(proc(api: OpenAiApi, requests: var Channel[CapturedRequest]) =
      let
        text = "\e[31mwait here\e[0m\n\"please\""
        originalQuestions = questions()
        original = toJson(originalQuestions)
        response = api.createSystemOne("kev-4b", text, originalQuestions,
          Opts(bearerToken: "override-token", organization: "override-org", curlTimeout: 3))
        captured = requests.recv()
      check parseJson(captured.body)["state"].getStr == text
      check captured.headers["authorization"] == "Bearer override-token"
      check captured.headers["organization"] == "override-org"
      check toJson(originalQuestions) == original
      check api.apiKey == "default-token"
      check api.organization == "default-org"
      check api.curlTimeout == 5
      check response.answers["wait"].noul.get == 0.75
    )

  test "request overload passes per-request options":
    withServer(proc(api: OpenAiApi, requests: var Channel[CapturedRequest]) =
      discard api.createSystemOne(request(), Opts(bearerToken: "request-token", organization: "request-org"))
      let captured = requests.recv()
      check captured.headers["authorization"] == "Bearer request-token"
      check captured.headers["organization"] == "request-org"
    )

  test "per-request timeout overrides the client default":
    withServer(proc(api: OpenAiApi, requests: var Channel[CapturedRequest]) =
      try:
        discard api.createSystemOne(request(), Opts(curlTimeout: 1))
        check false
      except CatchableError as error:
        check "timeout" in error.msg.toLowerAscii or "timed out" in error.msg.toLowerAscii
      discard requests.recv()
    , delayMs = 1300)

  test "HTTP failures retain server details":
    withServer(proc(api: OpenAiApi, requests: var Channel[CapturedRequest]) =
      try:
        discard api.createSystemOne(request())
        check false
      except OpenAiError as error:
        check "422" in error.msg
        check "invalid question" in error.msg
      discard requests.recv()
    , status = "422 Unprocessable Entity", response = "{\"error\":\"invalid question\"}")

  test "HTTP 200 string and object errors are raised":
    for body in ["{\"error\":\"Unexpected endpoint or method\"}",
        "{\"error\":{\"message\":\"unknown model\"},\"answers\":{}}"]:
      withServer(proc(api: OpenAiApi, requests: var Channel[CapturedRequest]) =
        expect OpenAiError:
          discard api.createSystemOne(request())
        discard requests.recv()
      , response = body)

  test "missing or malformed answers and non-object responses are raised":
    for body in ["{}", "{\"answers\":null}", "{\"answers\":[]}", "{\"answers\":\"invalid\"}", "[]"]:
      withServer(proc(api: OpenAiApi, requests: var Channel[CapturedRequest]) =
        expect OpenAiError:
          discard api.createSystemOne(request())
        discard requests.recv()
      , response = body)

  test "malformed JSON propagates its parsing error":
    withServer(proc(api: OpenAiApi, requests: var Channel[CapturedRequest]) =
      expect JsonParsingError:
        discard api.createSystemOne(request())
      discard requests.recv()
    , response = "{")
