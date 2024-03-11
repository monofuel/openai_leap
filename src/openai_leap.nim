import curly, jsony, std/[os, json, options, strformat, tables]
## OpenAI Api Library
## https://platform.openai.com/docs/api-reference/introduction

type
  OpenAIAPI* = ref object
    curlPool: CurlPool
    baseUrl: string
    curlTimeout: float32
    apiKey: string
    organization: string
  OpenAIModel* = ref object
    id*: string
    created*: int
    objectStr*: string
    ownedBy*: string
  Usage* = ref object
    promptTokens*: int
    totalTokens*: int
  ListModelResponse* = ref object
    data*: seq[OpenAIModel]
    objectStr*: string
  DeleteModelResponse* = ref object
    id*: string
    objectStr*: string
    deleted*: bool
  CreateEmbeddingReq* = ref object
    input*: string           # | seq[string] | seq[int] | seq[seq[int]]
    model*: string
    encodingFormat*: Option[string] # can be "float" or "base64", defaults to float
    dimensions*: Option[int] # only supported on text-embedding-3 and later
    user*: Option[string]
  CreateEmbeddingRespObj* = ref object
    index*: int              # index into the input sequence in the request
    embedding*: seq[float32] # https://platform.openai.com/docs/guides/embeddings
    objectStr*: string
  CreateEmbeddingResp* = ref object
    data*: seq[CreateEmbeddingRespObj]
    objectStr*: string
    model*: string
    usage*: Usage
  ToolFunctionResp* = ref object
    name*: string
    arguments*: string
  ToolCallResp* = ref object
    id*: string
    typeStr*: string
    function*: ToolFunctionResp
  Message* = ref object
    content*: Option[string]    # requied for role = system | user
    role*: string               # system | user | assisant | tool
    name*: Option[string]
    toolCalls*: Option[seq[ToolCallResp]]
    toolCallid*: Option[string] # required for role = tool
  ResponseFormatObj* = ref object
    typeStr*: string # must be text or json_object
  ToolFunction* = ref object
    description*: Option[string]
    name*: string
    parameters*: Option[JsonNode] # JSON Schema Object
  ToolCall* = ref object
    typeStr*: string
    function*: ToolFunction
  ToolChoiceFuncion* = ref object
    name*: string
  ToolChoice* = ref object
    typeStr*: string
    function*: ToolChoiceFuncion
  CreateChatCompletionReq* = ref object
    messages*: seq[Message]
    model*: string
    frequencyPenalty*: Option[float32] # between -2.0 and 2.0
    logitBias*: Option[Table[string, float32]]
    logprobs*: Option[bool]
    topLogprobs*: Option[int]          # 0 - 20
    maxTokens*: Option[int]
    n*: Option[int]                    # count of completion choices to generate
    presencePenalty*: Option[float32]  # between -2.0 and 2.0
    responseFormat*: Option[ResponseFormatObj]
    seed*: Option[int]
    stop*: Option[string]              # up to 4 stop sequences
                            #stop*: Option[string | seq[string]] # up to 4 stop sequences
    stream*: Option[bool]              # always use false for this library
    topP*: Option[float32]             # between 0.0 and 1.0
    tools*: Option[seq[ToolCall]]
    # toolChoice*: Option[string | ToolChoice] # "auto" | function to use
    user*: Option[string]
    # function_call
    # functions
  CreateChatMessage* = ref object
    finishReason*: string
    index*: int
    message: Message
    logProbs*: Option[JsonNode]
  CreateChatCompletionResp* = ref object
    id*: string
    choices*: seq[CreateChatMessage]
    created*: int
    model*: string
    systemFingerprint*: string
    objectStr*: string
    usage*: Usage



type HookedTypes = OpenAIModel | ListModelResponse | DeleteModelResponse |
  CreateEmbeddingRespObj | CreateEmbeddingResp | ToolCall | ToolCallResp |
  ResponseFormatObj | ToolChoice

proc renameHook*(v: var HookedTypes, fieldName: var string) =
  ## `object` is a special keyword in nim, so we need to rename it during serialization
  if fieldName == "object":
    fieldName = "object_str"
  ## `type` is a special keyword in nim, so we need to rename it during serialization
  if fieldName == "type":
    fieldName = "type_str"

proc dumpHook*(v: var HookedTypes, fieldName: var string) =
  if fieldName == "object_str":
    fieldName = "object"
  if fieldName == "type_str":
    fieldName = "type"



proc dumpHook(s: var string, v: object) =
  ## jsony `hack` to skip optional fields that are nil
  s.add '{'
  var i = 0
  # Normal objects.
  for k, e in v.fieldPairs:
    when compiles(e.isSome):
      if e.isSome:
        if i > 0:
          s.add ','
        s.dumpHook(k)
        s.add ':'
        s.dumpHook(e)
        inc i
    else:
      if i > 0:
        s.add ','
      s.dumpHook(k)
      s.add ':'
      s.dumpHook(e)
      inc i
  s.add '}'

proc newOpenAIAPI*(
    baseUrl: string = "https://api.openai.com/v1",
    apiKeyParam: string = "",
    organization: string = "",
    curlPoolSize: int = 4,
    curlTimeout: float32 = 10000
): OpenAIAPI =
  ## Initialize a new OpenAI API client
  ## Will use the provided apiKey, or look for the OPENAI_API_KEY environment variable
  var apiKey = apiKeyParam
  if apiKey == "":
    apiKey = getEnv("OPENAI_API_KEY", "")
  if apiKey == "":
    raise newException(CatchableError, "OpenAI API key is required")

  result = OpenAIAPI()
  result.curlPool = newCurlPool(curlPoolSize)
  result.baseUrl = baseUrl
  result.curlTimeout = curlTimeout
  result.apiKey = apiKey
  result.organization = organization

proc close*(api: OpenAIAPI) =
  ## clean up the OpenAPI API client
  api.curlPool.close()


proc get(api: OpenAIAPI, path: string): Response =
  ## Make a GET request to the OpenAI API
  var headers: curly.HttpHeaders
  headers["Content-Type"] = "application/json"
  headers["Authorization"] = "Bearer " & api.apiKey
  if api.organization != "":
    headers["Organization"] = api.organization
  let resp = api.curlPool.get(api.baseUrl & path, headers, api.curlTimeout)
  if resp.code != 200:
    raise newException(CatchableError, &"openai call {path} failed: {resp.code} {resp.body}")
  result = resp

proc post(api: OpenAIAPI, path: string, body: string): Response =
  ## Make a POST request to the OpenAI API
  var headers: curly.HttpHeaders
  headers["Content-Type"] = "application/json"
  headers["Authorization"] = "Bearer " & api.apiKey
  if api.organization != "":
    headers["Organization"] = api.organization
  let resp = api.curlPool.post(api.baseUrl & path, headers, body,
      api.curlTimeout)
  if resp.code != 200:
    raise newException(CatchableError, &"openai call {path} failed: {resp.code} {resp.body}")
  result = resp

proc delete(api: OpenAIAPI, path: string): Response =
  ## Make a DELETE request to the OpenAI API
  var headers: curly.HttpHeaders
  headers["Content-Type"] = "application/json"
  headers["Authorization"] = "Bearer " & api.apiKey
  if api.organization != "":
    headers["Organization"] = api.organization
  let resp = api.curlPool.delete(api.baseUrl & path, headers, api.curlTimeout)
  if resp.code != 200:
    raise newException(CatchableError, &"openai call {path} failed: {resp.code} {resp.body}")
  result = resp

proc listModels*(api: OpenAIAPI): seq[OpenAIModel] =
  let resp = api.get("/models")
  let data = fromJson(resp.body, ListModelResponse)
  return data.data

proc getModel*(api: OpenAIAPI, modelId: string): OpenAIModel =
  let resp = api.get("/models/" & modelId)
  result = fromJson(resp.body, OpenAIModel)

proc deleteModel*(api: OpenAIAPI, modelId: string): DeleteModelResponse =
  let resp = api.delete("/models/" & modelId)
  result = fromJson(resp.body, DeleteModelResponse)

proc generateEmbeddings*(
  api: OpenAIAPI,
  model: string,
  input: string,
  dimensions: Option[int] = none(int),
  user: string = ""
): CreateEmbeddingResp =
  ## Generate embeddings for a list of documents
  let req = CreateEmbeddingReq()
  req.input = input
  req.model = model
  req.dimensions = dimensions
  if user != "":
    req.user = option(user)
  let reqBody = toJson(req)
  let resp = post(api, "/embeddings", reqBody)
  result = fromJson(resp.body, CreateEmbeddingResp)

proc createChatCompletion*(
  api: OpenAIAPI,
  req: CreateChatCompletionReq
): CreateChatCompletionResp =
  ## Create a chat completion
  let reqBody = toJson(req)
  let resp = post(api, "/chat/completions", reqBody)
  result = fromJson(resp.body, CreateChatCompletionResp)

proc createChatCompletion*(
  api: OpenAIAPI,
  model: string,
  systemPrompt: string,
  input: string
): string =
  ## Create a chat completion
  let req = CreateChatCompletionReq()
  req.model = model
  req.messages = @[
    Message(role: "system", content: option(systemPrompt)),
    Message(role: "user", content: option(input))
    ]
  let resp = api.createChatCompletion(req)
  result = resp.choices[0].message.content.get
