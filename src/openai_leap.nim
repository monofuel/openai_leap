import
  std/[os, locks, osproc, json, options, strutils, strformat, tables],
  curly, jsony, webby

## OpenAI Api Reference: https://platform.openai.com/docs/api-reference/introduction
## 
## Readme: https://github.com/monofuel/openai_leap/blob/master/README.md

# Important: the OpenAI API uses snake_case. request objects must be snake_case this or the fields will be ignored by the API.
# jsony is flexible in parsing the responses in either camelCase or snake_case but better to use snake_case for consistency.
type
  OpenAiApiObj* = object
    curly: Curly
    lock: Lock # lock for modifying the openai api object
    baseUrl: string
    curlTimeout: int
    apiKey: string
    organization: string
  OpenAiApi* = ptr OpenAiApiObj

  OpenAiError* = object of CatchableError ## Raised if an operation fails.

  OpenAIStream* = ref object
    stream: ResponseStream
    buffer: string

  OpenAiModel* = ref object
    id*: string
    created*: int
    `object`*: string
    owned_by*: string

  Usage* = ref object
    prompt_tokens*: int
    total_tokens*: int

  ListModelResponse* = ref object
    data*: seq[OpenAiModel]
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
    embedding*: seq[float64] # https://platform.openai.com/docs/guides/embeddings
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

  ImageUrlPart* = ref object
    url*: string
    detail*: Option[string] # detail level of image, refer to Vision Guide in the docs

  MessageContentPart* = ref object
    `type`*: string # must be text or image_url
    text*: options.Option[string]
    image_url*: options.Option[ImageUrlPart]

  Message* = ref object
    ## ChatGPT Message object for chat completions and responses
    ## NB. `content` can be a string or a sequence of MessageContentPart objects, however this cannot be expressed in Nim easily, so we require a sequence of MessageContentPart objects
    content*: Option[seq[MessageContentPart]]    # requied for role = system | user
    role*: string               # system | user | assisant | tool
    name*: Option[string]
    tool_calls*: Option[seq[ToolCallResp]]
    tool_call_id*: Option[string] # required for role = tool

  RespMessage* = ref object
    content*: string            # response always has content
    role*: string               # system | user | assisant | tool
    name*: Option[string]
    tool_calls*: Option[seq[ToolCallResp]]
    refusal*: Option[string]

  ResponseFormatObj* = ref object
    `type`*: string # must be text, json_object, or json_schema
    json_schema*: Option[JsonNode] # must be set if type is json_schema

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
    temperature*: Option[float32]       # between 0.0 and 2.0
    seed*: Option[int]
    stop*: Option[string]              # up to 4 stop sequences
                            #stop*: Option[string | seq[string]] # up to 4 stop sequences
    stream*: Option[bool]              # do not set this, either call createChatCompletion or streamChatCompletion
    top_p*: Option[float32]             # between 0.0 and 1.0
    tools*: Option[seq[ToolCall]]
    tool_choice*: Option[JsonNode]  # "auto" | function to use. using a JsonNode to allow either a string or a ToolChoice object
    user*: Option[string]

  CreateChatMessage* = ref object
    finish_reason*: string
    index*: int
    message*: Option[RespMessage]           # full response message when streaming = false
    delta*: Option[RespMessage]             # message delta when streaming = true
    log_probs*: Option[JsonNode]

  CreateChatCompletionResp* = ref object
    id*: string
    choices*: seq[CreateChatMessage]
    created*: int
    model*: string
    system_fingerprint*: string
    `object`*: string
    usage*: Usage

  AudioTranscription* = object
    text*: string

  ChatCompletionChunk* = object # chat completion streaming response
    id*: string
    `object`*: string           # always "chat.completion.chunk"
    created*: int               # unix timestamp
    model*: string              # model id
    system_fingerprint*: string
    choices*: seq[CreateChatMessage]

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
    batch_size*: Option[int]
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
  ## Jsony skip optional fields that are nil.
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

proc newOpenAiApi*(
    baseUrl: string = "https://api.openai.com/v1",
    apiKey: string = "",
    organization: string = "",
    maxInFlight: int = 16,
    curlTimeout: int = 60
): OpenAiApi =
  ## Initialize a new OpenAI API client.
  ## Will use the provided apiKey,
  ## or look for the OPENAI_API_KEY environment variable.
  var apiKeyVar = apiKey
  if apiKeyVar == "":
    apiKeyVar = getEnv("OPENAI_API_KEY", "")
  if apiKeyVar == "":
    raise newException(
      OpenAiError,
      "OPENAI_API_KEY must be set for OpenAI API authorization"
    )

  result = cast[OpenAiApi](allocShared0(sizeof(OpenAiApiObj)))
  result.curly = newCurly(maxInFlight)
  initLock(result.lock)
  result.baseUrl = baseUrl
  result.curlTimeout = curlTimeout
  result.apiKey = apiKeyVar
  result.organization = organization

template sync*(a: Lock, body: untyped) =
  acquire(a)
  try:
      body
  finally:
    release(a)

proc updateApiKey*(api: OpenAiApi, apiKey: string) =
  ## Update the API key for the OpenAI API client.
  api.lock.sync:
    api.apiKey = apiKey

proc close*(api: OpenAiApi) =
  ## Clean up the OpenAPI API client.
  api.curly.close()
  deallocShared(api)

proc get(api: OpenAiApi, path: string): Response =
  ## Make a GET request to the OpenAI API.
  var headers: curly.HttpHeaders
  headers["Content-Type"] = "application/json"
  api.lock.sync:
    headers["Authorization"] = "Bearer " & api.apiKey
  if api.organization != "":
    headers["Organization"] = api.organization
  let resp = api.curly.get(api.baseUrl & path, headers, api.curlTimeout)
  if resp.code != 200:
    raise newException(
      OpenAiError,
      &"API call {path} failed: {resp.code} {resp.body}"
    )
  result = resp

proc post(api: OpenAiApi, path: string, body: string): Response =
  ## Make a POST request to the OpenAI API.
  var headers: curly.HttpHeaders
  headers["Content-Type"] = "application/json"
  api.lock.sync:
    headers["Authorization"] = "Bearer " & api.apiKey
  if api.organization != "":
    headers["Organization"] = api.organization
  let resp = api.curly.post(
    api.baseUrl & path,
    headers,
    body,
    api.curlTimeout
  )
  if resp.code != 200:
    raise newException(
      OpenAiError,
      &"API call {path} failed: {resp.code} {resp.body}"
    )
  result = resp

proc postStream(api: OpenAiApi, path: string, body: string): ResponseStream =
  ## Make a streaming POST request to the OpenAI API.
  var headers: curly.HttpHeaders
  headers["Content-Type"] = "application/json"
  api.lock.sync:
    headers["Authorization"] = "Bearer " & api.apiKey
  if api.organization != "":
    headers["Organization"] = api.organization

  let resp = api.curly.request("POST",
    api.baseUrl & path,
    headers,
    body,
    api.curlTimeout
  )
  if resp.code != 200:
    raise newException(
      OpenAiError,
      &"API call {path} failed: {resp.code}"
    )
  result = resp

proc post(
  api: OpenAiApi,
  path: string,
  entries: seq[MultipartEntry]
): Response =
  ## Make a POST request to the OpenAI API.
  var headers: curly.HttpHeaders
  api.lock.sync:
    headers["Authorization"] = "Bearer " & api.apiKey
  if api.organization != "":
    headers["Organization"] = api.organization
  let (contentType, body) = encodeMultipart(entries)
  headers["Content-Type"] = contentType
  let resp = api.curly.post(
    api.baseUrl & path,
    headers,
    body,
    api.curlTimeout
  )
  if resp.code != 200:
    raise newException(
      OpenAiError,
      &"API call {path} failed: {resp.code} {resp.body}"
    )
  result = resp

proc delete(api: OpenAiApi, path: string): Response =
  ## Make a DELETE request to the OpenAI API.
  var headers: curly.HttpHeaders
  headers["Content-Type"] = "application/json"
  api.lock.sync:
    headers["Authorization"] = "Bearer " & api.apiKey
  if api.organization != "":
    headers["Organization"] = api.organization
  let resp = api.curly.delete(api.baseUrl & path, headers, api.curlTimeout)
  if resp.code != 200:
    raise newException(
      OpenAiError,
      &"API call {path} failed: {resp.code} {resp.body}"
    )
  result = resp

proc listModels*(api: OpenAiApi): seq[OpenAiModel] =
  ## List available models.
  let resp = api.get("/models")
  let data = fromJson(resp.body, ListModelResponse)
  return data.data

proc getModel*(api: OpenAiApi, modelId: string): OpenAiModel =
  ## Get a specific model.
  let resp = api.get("/models/" & modelId)
  result = fromJson(resp.body, OpenAiModel)

proc deleteModel*(api: OpenAiApi, modelId: string): DeleteModelResponse =
  ## Delete a specific model.
  let resp = api.delete("/models/" & modelId)
  result = fromJson(resp.body, DeleteModelResponse)

proc generateEmbeddings*(
  api: OpenAiApi,
  model: string,
  input: string,
  dimensions: Option[int] = none(int),
  user: string = ""
): CreateEmbeddingResp =
  ## Generate embeddings for a list of documents.
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
  api: OpenAiApi,
  req: CreateChatCompletionReq
): CreateChatCompletionResp =
  ## Create a chat completion. without streaming.
  req.stream = option(false)
  let reqBody = toJson(req)
  let resp = post(api, "/chat/completions", reqBody)
  result = fromJson(resp.body, CreateChatCompletionResp)

proc streamChatCompletion*(
  api: OpenAiApi,
  req: CreateChatCompletionReq
): OpenAIStream =
  ## Stream a chat completion response
  req.stream = option(true)
  let reqBody = toJson(req)
  return OpenAIStream(stream: postStream(api, "/chat/completions", reqBody))

proc createChatCompletion*(
  api: OpenAiApi,
  model: string,
  systemPrompt: string,
  input: string
): string =
  ## Create a chat completion.
  let req = CreateChatCompletionReq()
  req.model = model
  req.messages = @[
    Message(
      role: "system",
      content: option(@[
        MessageContentPart(`type`: "text", text: option(systemPrompt))
      ])
    ),
    Message(
      role: "user",
      content: option(@[
        MessageContentPart(`type`: "text", text: option(input))
      ])
    )
  ]
  let resp = api.createChatCompletion(req)
  result = resp.choices[0].message.get.content

proc streamChatCompletion*(
  api: OpenAiApi,
  model: string,
  systemPrompt: string,
  input: string
): OpenAIStream =
  ## Create a chat completion.
  let req = CreateChatCompletionReq()
  req.model = model
  req.messages = @[
    Message(
      role: "system",
      content: option(@[
        MessageContentPart(`type`: "text", text: option(systemPrompt))
      ])
    ),
    Message(
      role: "user",
      content: option(@[
        MessageContentPart(`type`: "text", text: option(input))
      ])
    )
  ]
  return api.streamChatCompletion(req)

proc next*(s: OpenAIStream): Option[ChatCompletionChunk] =
  ## next iterates over the response stream.
  ## returns the next chunk
  ## an empty seq is returned when the stream has been closed.
  ## nb. streams must be iterated to completion to avoid leaking streams

  template returnIfChunk() =
    var newLineIndex = s.buffer.find("\n") 
    if newLineIndex != -1:
      var line = s.buffer[0..newLineIndex]
      s.buffer = s.buffer[newLineIndex+1 .. ^1]

      if line.startsWith("data: "):
        line.removePrefix("data: ")
        if line.strip() != "[DONE]":
          return option(fromJson(line, ChatCompletionChunk))
        
  # return any existing objects in the buffer
  returnIfChunk()

  # read in from the socket until s.buffer has a newline
  while not s.buffer.contains("\n"):
    try:
      var chunk: string
      let bytesRead = s.stream.read(chunk)
      s.buffer &= chunk
      if bytesRead == 0:
        s.stream.close()
        return none(ChatCompletionChunk)
    except:
      s.stream.close()
  
  # handle the fresh read in line
  returnIfChunk()
  
   
  

proc createFineTuneDataset*(api: OpenAiApi, filepath: string): OpenAIFile =
  ## OpenAI fine tuning format is a jsonl file.
  ## At least 10 examples are required. 50 to 100 recommended.
  ## For a training file with 100,000 tokens trained over 3 epochs,
  ## the expected cost would be ~$2.40 USD.
  ## File will take time to process while uploading.
  ## Maximum file size is 512MB, but not files that big are not recommended.
  ## There is a 100gb limit across an organization.
  ## See: https://platform.openai.com/docs/api-reference/files/create

  # This API call is special and uses a form for file upload
  # HACK using execCmd to call curl directly instead of use curly

  if not fileExists(filepath):
    raise newException(OpenAiError, "File does not exist: " & filepath)
  var authToken: string
  api.lock.sync:
    authToken = "Bearer " & api.apiKey
  var orgLine = ""
  if api.organization != "":
    orgLine = "-H \"Organization: " & api.organization & "\""
  let curlUploadCmd = &"""
curl -s https://api.openai.com/v1/files \
  -H "Authorization: {authToken}" \
  {orgLine} \
  -F purpose="fine-tune" \
  -F file="@{filepath}"
"""
  let (output, res) = execCmdEx(curlUploadCmd)
  if res != 0:
    raise newException(
      OpenAiError,
      "Failed to upload file, curl returned " & $res
    )
  result = fromJson(output, OpenAIFile)

proc listFiles*(api: OpenAiApi): OpenAIListFiles =
  ## List all the files.
  let resp = api.get("/files")
  result = fromJson(resp.body, OpenAIListFiles)

proc getFileDetails*(api: OpenAiApi, fileId: string): OpenAIFile =
  ## Get the details of a file.
  let resp = api.get("/files/" & fileId)
  result = fromJson(resp.body, OpenAIFile)

proc deleteFile*(api: OpenAiApi, fileId: string) =
  ## Delete a file.
  discard api.delete("/files/" & fileId)

# TODO retrieve file content

proc createFineTuneJob*(
  api: OpenAiApi, req: OpenAIFinetuneRequest
): OpenAIFinetuneJob =
  ## Create a fine tune job.
  let reqStr = toJson(req)
  echo reqStr
  let resp = api.post("/fine_tuning/jobs", reqStr)
  result = fromJson(resp.body, OpenAIFinetuneJob)

proc getFineTuneModel*(api: OpenAiApi, modelId: string) =
  ## Get the status of the model.
  raiseAssert("Unimplemented proc")

proc listFineTuneJobs*(api: OpenAiApi): OpenAIFinetuneList =
  ## List all the fine tune jobs.
  let resp = api.get("/fine_tuning/jobs")
  echo resp.body
  result = fromJson(resp.body, OpenAIFinetuneList)

proc listFineTuneModelEvents*(api: OpenAiApi, modelId: string) =
  ## List all the events for the fine tune model.
  raiseAssert("Unimplemented proc")

proc listFineTuneCheckpoints*(api: OpenAiApi, modelId: string) =
  ## List all the checkpoints for the fine tune model.
  ## See: https://platform.openai.com/docs/api-reference/fine-tuning/list-checkpoints
  raiseAssert("Unimplemented proc")

proc cancelFineTuneModel*(api: OpenAiApi, modelId: string) =
  ## Cancel the fine tune model.
  raiseAssert("Unimplemented proc")

proc deleteFineTuneModel*(api: OpenAiApi, modelId: string) =
  ## Delete the fine tune model.
  raiseAssert("Unimplemented proc")

proc audioTranscriptions*(
  api: OpenAiApi,
  model: string,
  audioData: string
): AudioTranscription =
  ## Transcribe audio data.
  let entries = @[
    MultipartEntry(
      name: "file",
      fileName: "input.wav",
      contentType: "audio/wav",
      payload: audioData
    ),
    MultipartEntry(
      name: "model",
      payload: model
    )
  ]
  let response = api.post(
    "/audio/transcriptions",
    entries
  )
  return response.body.fromJson(AudioTranscription)
