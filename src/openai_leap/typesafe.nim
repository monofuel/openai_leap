import
  std/[json, options, tables],
  jsony,
  openai_leap/common

proc dumpHook*(s: var string, question: SystemOneQuestion) =
  ## Serialize a question while omitting absent criteria.
  if question.isNil:
    s.add "null"
    return
  s.add "{\"type\":"
  s.dumpHook(question.`type`)
  s.add ",\"instructions\":"
  s.dumpHook(question.instructions)
  if question.criteria.isSome:
    s.add ",\"criteria\":"
    s.dumpHook(question.criteria.get)
  s.add '}'

proc dumpHook*(s: var string, req: CreateSystemOneReq) =
  ## Serialize a System One request while omitting absent media fields.
  if req.isNil:
    s.add "null"
    return
  s.add "{\"model\":"
  s.dumpHook(req.model)
  s.add ",\"state\":"
  s.dumpHook(req.state)
  s.add ",\"questions\":{"
  var first = true
  for name, question in req.questions:
    if not first:
      s.add ','
    first = false
    s.dumpHook(name)
    s.add ':'
    s.dumpHook(question)
  s.add '}'
  if req.files.isSome:
    s.add ",\"files\":"
    s.dumpHook(req.files.get)
  if req.images.isSome:
    s.add ",\"images\":"
    s.dumpHook(req.images.get)
  s.add '}'

proc createSystemOne*(
  api: OpenAiApi,
  req: CreateSystemOneReq,
  opts: Opts = Opts()
): CreateSystemOneResp =
  ## Evaluate named choice, noul, and score questions through /systemone.
  let
    response = api.post("/systemone", toJson(req), opts)
    envelope = parseJson(response.body)
  if envelope.kind != JObject:
    raise newException(OpenAiError, "API call /systemone returned a non-object response: " & response.body)
  if envelope.hasKey("error") and envelope["error"].kind != JNull:
    raise newException(OpenAiError, "API call /systemone failed: " & response.body)
  if not envelope.hasKey("answers") or envelope["answers"].kind != JObject:
    raise newException(OpenAiError, "API call /systemone returned invalid answers: " & response.body)
  result = fromJson(response.body, CreateSystemOneResp)

proc createSystemOne*(
  api: OpenAiApi,
  model: string,
  state: string,
  questions: OrderedTable[string, SystemOneQuestion],
  opts: Opts = Opts()
): CreateSystemOneResp =
  ## Evaluate questions about plain text without constructing a request.
  api.createSystemOne(CreateSystemOneReq(model: model, state: %state, questions: questions), opts)
