import curly, jsony, std/[os, osproc, json, options, strformat, tables]
## OpenAI Api Library
## https://platform.openai.com/docs/api-reference/introduction

# Important: the OpenAI API uses camel_case. you must match this or the fields will be ignored
# this does not matter for responses but is critical for requests
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
    `object`*: string
    owned_by*: string
  Usage* = ref object
    prompt_tokens*: int
    total_tokens*: int
  ListModelResponse* = ref object
    data*: seq[OpenAIModel]
    `object`*: string
  DeleteModelResponse* = ref object
    id*: string
    `object`*: string
    deleted*: bool
  CreateEmbeddingReq* = ref object
    input*: string           # | seq[string] | seq[int] | seq[seq[int]]
    model*: string
    encoding_format*: Option[string] # can be "float" or "base64", defaults to float
    dimensions*: Option[int] # only supported on text-embedding-3 and later
    user*: Option[string]
  CreateEmbeddingRespObj* = ref object
    index*: int              # index into the input sequence in the request
    embedding*: seq[float32] # https://platform.openai.com/docs/guides/embeddings
    `object`*: string
  CreateEmbeddingResp* = ref object
    data*: seq[CreateEmbeddingRespObj]
    `object`*: string
    model*: string
    usage*: Usage
  ToolFunctionResp* = ref object
    name*: string
    arguments*: string # string of a JSON object
  ToolCallResp* = ref object
    id*: string
    `type`*: string
    function*: ToolFunctionResp
  Message* = ref object
    content*: Option[string]    # requied for role = system | user
    role*: string               # system | user | assisant | tool
    name*: Option[string]
    tool_calls*: Option[seq[ToolCallResp]]
    tool_call_id*: Option[string] # required for role = tool
  ResponseFormatObj* = ref object
    `type`*: string # must be text or json_object
  ToolFunction* = ref object
    description*: Option[string]
    name*: string
    parameters*: Option[JsonNode] # JSON Schema Object
  ToolCall* = ref object
    `type`*: string
    function*: ToolFunction
  ToolChoiceFuncion* = ref object
    name*: string
  ToolChoice* = ref object
    `type`*: string
    function*: ToolChoiceFuncion
  CreateChatCompletionReq* = ref object
    messages*: seq[Message]
    model*: string
    frequency_penalty*: Option[float32] # between -2.0 and 2.0
    logit_bias*: Option[Table[string, float32]]
    logprobs*: Option[bool]
    top_logprobs*: Option[int]          # 0 - 20
    max_tokens*: Option[int]
    n*: Option[int]                    # count of completion choices to generate
    presence_penalty*: Option[float32]  # between -2.0 and 2.0
    response_format*: Option[ResponseFormatObj]
    seed*: Option[int]
    stop*: Option[string]              # up to 4 stop sequences
                            #stop*: Option[string | seq[string]] # up to 4 stop sequences
    stream*: Option[bool]              # always use false for this library
    top_p*: Option[float32]             # between 0.0 and 1.0
    tools*: Option[seq[ToolCall]]
    #toolChoice*: Option[string | ToolChoice] # "auto" | function to use
    tool_choice*: Option[JsonNode]  # "auto" | function to use
    user*: Option[string]
  CreateChatMessage* = ref object
    finish_reason*: string
    index*: int
    message*: Message
    log_probs*: Option[JsonNode]
  CreateChatCompletionResp* = ref object
    id*: string
    choices*: seq[CreateChatMessage]
    created*: int
    model*: string
    system_fingerprint*: string
    `object`*: string
    usage*: Usage

# Finetuning types
type
  OpenAIFineTuneMessage* = ref object
    role*: string # system, user, or assistant
    content*: string
  OpenAIFineTuneChat* = ref object
    messages*: seq[OpenAIFineTuneMessage]
  OpenAIFile* = ref object
    id*: string
    `object`*: string
    bytes*: int
    created_at*: int
    filename*: string
    purpose*: string
  OpenAIListFiles* = ref object
    data*: seq[OpenAIFile]
    `object`*: string
  OpenAIHyperParameters* = ref object
    # TODO needs to handle "auto" or int / float
    batchSize*: Option[int]
    learning_rate_multiplier*: Option[float]
    n_epochs*: Option[int]
  OpenAIFinetuneRequest* = ref object
    model*: string
    training_file*: string # file ID
    hyperparameters*: Option[OpenAIHyperParameters]
    suffix*: Option[string] # up to 18 character finetune suffix
    validation_file*: Option[string] # file ID
    # integrations
    seed*: Option[int] # Job seed
  FineTuneError* = ref object
    code*: string
    param*: string
    message*: string
  OpenAIFinetuneJob* = ref object
    `object`*: string
    id*: string
    model*: string
    created_at*: int
    fine_tuned_model*: Option[string]
    organization_id*: string
    status*: string
    training_file*: string
    validation_file*: string
    result_files*: seq[string]
    #hyperparameters*: Option[OpenAIHyperParameters]
    #
    # trained_tokens
    error*: Option[FineTuneError]
    user_provided_suffix*: Option[string]
    seed*: int
    # integrations
  OpenAIFinetuneList* = ref object
    `object`*: string
    data*: seq[OpenAIFinetuneJob]
    has_more*: bool

proc dumpHook(s: var string, v: object) =
  ## jsony skip optional fields that are nil
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


# openai fine tuning format is a jsonl file
# at least 10 examples are required. 50 to 100 recommended.
# For a training file with 100,000 tokens trained over 3 epochs, the expected cost would be ~$2.40 USD.

proc createFineTuneDataset*(api: OpenAIAPI, filepath: string): OpenAIFile =
  # file will take time to process while uploading
  # maximum file size is 512MB, but not recommended that big.
  # 100gb limit across an organization
  #https://platform.openai.com/docs/api-reference/files/create

  # This API call is special and uses a form for file upload
  # HACK using execCmd to call curl directly instead of use curly

  if not fileExists(filepath):
    raise newException(CatchableError, "File does not exist: " & filepath)

  let auth = "Bearer " & api.apiKey
  var orgLine = ""
  if api.organization != "":
    orgLine = "-H \"Organization: " & api.organization & "\""
  let curlUploadCmd = &"""
curl -s https://api.openai.com/v1/files \
  -H "Authorization: {auth}" \
  {orgLine} \
  -F purpose="fine-tune" \
  -F file="@{filepath}"
"""
  let (output, res) = execCmdEx(curlUploadCmd)
  if res != 0:
    raise newException(CatchableError, "Failed to upload file, curl returned " & $res)
  result = fromJson(output, OpenAIFile)
  
proc listFiles*(api: OpenAIAPI): OpenAIListFiles =
  let resp = api.get("/files")
  result = fromJson(resp.body, OpenAIListFiles)

proc getFileDetails*(api: OpenAIAPI, fileId: string): OpenAIFile =
  let resp = api.get("/files/" & fileId)
  result = fromJson(resp.body, OpenAIFile)

proc deleteFile*(api: OpenAIAPI, fileId: string) =
  discard api.delete("/files/" & fileId)

# TODO retrieve file content

proc createFineTuneJob*(api: OpenAIAPI, req: OpenAIFinetuneRequest): OpenAIFinetuneJob =
  let reqStr = toJson(req)
  echo reqStr
  let resp = api.post("/fine_tuning/jobs", reqStr)
  result = fromJson(resp.body, OpenAIFinetuneJob)

proc getFineTuneModel*(api: OpenAIAPI, modelId: string) =
  echo "TODO"
  # get the status of the model

proc listFineTuneJobs*(api: OpenAIAPI): OpenAIFinetuneList =
  let resp = api.get("/fine_tuning/jobs")
  echo resp.body
  result = fromJson(resp.body, OpenAIFinetuneList)

proc listFineTuneModelEvents*(api: OpenAIAPI, modelId: string) =
  echo "TODO"
  # list all the events for the fine tune model
proc listFineTuneCheckpoints*(api: OpenAIAPI, modelId: string) =
  echo "TODO"
  # https://platform.openai.com/docs/api-reference/fine-tuning/list-checkpoints
  # list all the checkpoints for the fine tune model

proc cancelFineTuneModel*(api: OpenAIAPI, modelId: string) =
  echo "TODO"
  # cancel the fine tune model
proc deleteFineTuneModel*(api: OpenAIAPI, modelId: string) =
  echo "TODO"
  # delete the fine tune model