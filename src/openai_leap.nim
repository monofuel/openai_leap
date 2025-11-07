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

  Opts* = object # Per-request options
    bearerToken*: string = ""
    organization*: string = ""
    curlTimeout*: int = 0

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

  ToolResp* = ref object
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
    tool_calls*: Option[seq[ToolResp]]
    tool_call_id*: Option[string] # required for role = tool

  RespMessage* = ref object
    content*: string            # response always has content
    role*: string               # system | user | assisant | tool
    name*: Option[string]
    tool_calls*: Option[seq[ToolResp]]
    refusal*: Option[string]

  ResponseFormatObj* = ref object
    `type`*: string # must be text, json_object, or json_schema
    json_schema*: Option[JsonNode] # must be set if type is json_schema

  ToolFunction* = ref object
    description*: Option[string]
    name*: string
    parameters*: Option[JsonNode] # JSON Schema Object

  Tool* = ref object
    `type`*: string
    function*: ToolFunction

  ToolChoiceFuncion* = ref object
    name*: string

  ToolChoice* = ref object
    `type`*: string
    function*: ToolChoiceFuncion

  ToolImpl* = proc (args: JsonNode): string
  ToolsTable* = Table[string, (ToolFunction, ToolImpl)]
  ChatCompletionCallback* = proc(req: CreateChatCompletionReq, resp: CreateChatCompletionResp)

  # Responses API specific tool types
  ResponseTool* = ref object
    `type`*: string # "function"
    name*: string
    description*: Option[string]
    parameters*: Option[JsonNode] # JSON Schema Object

  ResponseToolCall* = ref object
    `type`*: string # "function_call"
    call_id*: string
    name*: string
    arguments*: string # JSON string

  ResponseToolCallOutput* = ref object
    `type`*: string # "function_call_output"
    call_id*: string
    output*: string # JSON string

  ResponseToolImpl* = proc (name: string, args: JsonNode): string
  ResponseToolsTable* = Table[string, ResponseToolImpl]

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
    tools*: Option[seq[Tool]]
    tool_choice*: Option[JsonNode]  # "auto" | function to use. using a JsonNode to allow either a string or a ToolChoice object
    user*: Option[string]

  # TODO should probably rename `ChatMessage` since it's used in both req and resp
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

# Responses API types
type
  ResponseInputText* = ref object
    text*: string

  ResponseInputImage* = ref object
    url*: string
    detail*: Option[string] # low, high, auto

  ResponseInputFile* = ref object
    file_id*: string

  ResponseInputContent* = ref object
    `type`*: string # input_text, input_image
    text*: Option[string]
    image_url*: Option[ResponseInputImage]

  ResponseInput* = ref object
    `type`*: string # message, image_url, file
    role*: Option[string] # user, assistant, system, developer (for message type)
    content*: Option[seq[ResponseInputContent]] # for message type

  ResponseOutputText* = ref object
    text*: string

  ResponseOutputImage* = ref object
    url*: string

  ResponseOutputToolCall* = ref object
    id*: string
    `type`*: string # function, builtin_function
    function*: Option[ToolFunctionResp] # for custom functions

  ResponseOutputContent* = ref object
    `type`*: string # text, tool_call, etc.
    text*: Option[string]
    tool_call*: Option[ResponseOutputToolCall]

  ResponseOutput* = ref object
    role*: string
    content*: seq[ResponseOutputContent]

  ResponseUsage* = ref object
    input_tokens*: int
    output_tokens*: int
    total_tokens*: int

  OpenAiResponse* = ref object
    id*: string
    `object`*: string # always "response"
    created_at*: int
    model*: string
    status*: string # completed, failed, in_progress, cancelled, queued, incomplete
    error*: Option[JsonNode]
    incomplete_details*: Option[string]
    instructions*: Option[string]
    max_output_tokens*: Option[int]
    max_tool_calls*: Option[int]
    metadata*: Option[Table[string, string]]
    output*: seq[ResponseOutput]
    output_text*: Option[string]
    parallel_tool_calls*: Option[bool]
    previous_response_id*: Option[string]
    prompt*: Option[JsonNode]
    prompt_cache_key*: Option[string]
    reasoning*: Option[JsonNode]
    safety_identifier*: Option[string]
    service_tier*: Option[string]
    store*: Option[bool]
    temperature*: Option[float32]
    text*: Option[JsonNode]
    tool_choice*: Option[JsonNode]
    tools*: Option[seq[Tool]]
    top_logprobs*: Option[int]
    top_p*: Option[float32]
    truncation*: Option[string]
    usage*: Option[ResponseUsage]
    user*: Option[string]

  CreateResponseReq* = ref object
    input*: Option[seq[ResponseInput]] # or string
    instructions*: Option[string]
    model*: string
    background*: Option[bool]
    `include`*: Option[seq[string]]
    max_output_tokens*: Option[int]
    max_tool_calls*: Option[int]
    metadata*: Option[Table[string, string]]
    parallel_tool_calls*: Option[bool]
    previous_response_id*: Option[string]
    prompt*: Option[JsonNode]
    prompt_cache_key*: Option[string]
    reasoning*: Option[JsonNode]
    safety_identifier*: Option[string]
    service_tier*: Option[string]
    store*: Option[bool]
    stream*: Option[bool]
    stream_options*: Option[JsonNode]
    temperature*: Option[float32]
    text*: Option[JsonNode]
    tool_choice*: Option[JsonNode]
    tools*: Option[seq[ResponseTool]]
    top_logprobs*: Option[int]
    top_p*: Option[float32]
    truncation*: Option[string]
    user*: Option[string]

  OpenAIResponseStream* = ref object
    stream*: ResponseStream
    buffer*: string

proc stripEscapeSequences*(input: string): string =
  ## Remove ANSI escape sequences from a string to ensure valid JSON payloads.
  result = ""
  var i = 0
  while i < input.len:
    if i < input.len and ord(input[i]) == 0x1B: # ESC character
      inc i
      # Skip characters until a letter (end of ANSI sequence)
      while i < input.len and ord(input[i]) in 32..126:
        let c = input[i]
        inc i
        if c in {'A'..'Z', 'a'..'z'}:
          break
    else:
      result.add(input[i])
      inc i

proc sanitizeText*(s: string): string =
  ## Strip ANSI escape sequences from plain text.
  stripEscapeSequences(s)

proc sanitizeMessageContentPart(part: var MessageContentPart) =
  ## Sanitize a single content part.
  if part.`type` == "text" and part.text.isSome:
    let cleaned = sanitizeText(part.text.get)
    part.text = option(cleaned)

proc sanitizeMessage(msg: var Message) =
  ## Sanitize all text content in a message.
  if msg.content.isSome:
    var cleanedParts: seq[MessageContentPart] = @[]
    for p in msg.content.get:
      var part = p
      sanitizeMessageContentPart(part)
      cleanedParts.add(part)
    msg.content = option(cleanedParts)

proc sanitizeChatReq*(req: var CreateChatCompletionReq) =
  ## Sanitize a chat request prior to JSON serialization.
  if req.messages.len > 0:
    for i in 0..req.messages.high:
      var m = req.messages[i]
      sanitizeMessage(m)
      req.messages[i] = m

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
    curlTimeout: int = 60 * 5 # 5 minutes
): OpenAiApi =
  ## Initialize a new OpenAI API client.
  ## Will use the provided apiKey,
  ## or look for the OPENAI_API_KEY environment variable.
  ## apiKey may also be provided on a per-request basis.
  var apiKeyVar = apiKey
  if apiKeyVar == "":
    apiKeyVar = getEnv("OPENAI_API_KEY", "")

  result = cast[OpenAiApi](allocShared0(sizeof(OpenAiApiObj)))
  result.curly = newCurly(maxInFlight)
  initLock(result.lock)
  result.baseUrl = baseUrl
  result.curlTimeout = curlTimeout
  result.apiKey = apiKeyVar
  result.organization = organization

template sync(a: Lock, body: untyped) =
  acquire(a)
  try:
      body
  finally:
    release(a)

proc newToolsTable*(): ToolsTable =
  ## Create a new empty tools table
  result = initTable[string, (ToolFunction, ToolImpl)]()

proc register*(table: var ToolsTable, name: string, toolFunc: ToolFunction, impl: ToolImpl) =
  ## Add a tool to the tools table
  table[name] = (toolFunc, impl)

proc updateApiKey*(api: OpenAiApi, apiKey: string) =
  ## Update the API key for the OpenAI API client.
  api.lock.sync:
    api.apiKey = apiKey

proc close*(api: OpenAiApi) =
  ## Clean up the OpenAPI API client.
  api.curly.close()
  deallocShared(api)

proc get*(
  api: OpenAiApi,
  path: string,
  opts: Opts = Opts(),
  ): Response =
  ## Make a GET request to the OpenAI API.
  var headers: curly.HttpHeaders
  headers["Content-Type"] = "application/json"
  if opts.bearerToken != "":
    headers["Authorization"] = "Bearer " & opts.bearerToken
  else:
    api.lock.sync:
      headers["Authorization"] = "Bearer " & api.apiKey
  if opts.organization != "":
    headers["Organization"] = opts.organization
  elif api.organization != "":
      headers["Organization"] = api.organization

  var timeout = api.curlTimeout
  if opts.curlTimeout != 0:
    timeout = opts.curlTimeout

  let resp = api.curly.get(api.baseUrl & path, headers, timeout)
  if resp.code != 200:
    raise newException(
      OpenAiError,
      &"API call {path} failed: {resp.code} {resp.body}"
    )
  result = resp

proc post*(
  api: OpenAiApi,
  path: string,
  body: string,
  opts: Opts = Opts(),
): Response =
  ## Make a POST request to the OpenAI API.
  var headers: curly.HttpHeaders
  headers["Content-Type"] = "application/json"
  if opts.bearerToken != "":
    headers["Authorization"] = "Bearer " & opts.bearerToken
  else:
    api.lock.sync:
      headers["Authorization"] = "Bearer " & api.apiKey
  if opts.organization != "":
    headers["Organization"] = opts.organization
  elif api.organization != "":
      headers["Organization"] = api.organization
  var timeout = api.curlTimeout
  if opts.curlTimeout != 0:
    timeout = opts.curlTimeout
  let resp = api.curly.post(
    api.baseUrl & path,
    headers,
    body,
    timeout
  )
  if resp.code != 200:
    raise newException(
      OpenAiError,
      &"API call {path} failed: {resp.code} {resp.body}\nRequest body: {toJson(body)}"
    )
  result = resp

proc postStream(
  api: OpenAiApi,
  path: string,
  body: string,
  opts: Opts = Opts()
): ResponseStream =
  ## Make a streaming POST request to the OpenAI API.
  var headers: curly.HttpHeaders
  headers["Content-Type"] = "application/json"
  if opts.bearerToken != "":
    headers["Authorization"] = "Bearer " & opts.bearerToken
  else:
    api.lock.sync:
      headers["Authorization"] = "Bearer " & api.apiKey
  if opts.organization != "":
    headers["Organization"] = opts.organization
  elif api.organization != "":
      headers["Organization"] = api.organization
  var timeout = api.curlTimeout
  if opts.curlTimeout != 0:
    timeout = opts.curlTimeout

  let resp = api.curly.request("POST",
    api.baseUrl & path,
    headers,
    body,
    timeout
  )
  if resp.code != 200:
    raise newException(
      OpenAiError,
      &"API call {path} failed: {resp.code}\nRequest body: {toJson(body)}"
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
      &"API call {path} failed: {resp.code} {resp.body}\nRequest body: {toJson(body)}"
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
  req.input = sanitizeText(input)
  req.model = model
  req.dimensions = dimensions
  if user != "":
    req.user = option(sanitizeText(user))
  let reqBody = toJson(req)
  let resp = post(api, "/embeddings", reqBody)
  result = fromJson(resp.body, CreateEmbeddingResp)

proc createChatCompletion*(
  api: OpenAiApi,
  req: CreateChatCompletionReq
): CreateChatCompletionResp =
  ## Create a chat completion without tool calling.
  var mutableReq = req
  mutableReq.stream = option(false)
  sanitizeChatReq(mutableReq)
  
  let reqBody = toJson(mutableReq)
  let resp = post(api, "/chat/completions", reqBody)
  result = fromJson(resp.body, CreateChatCompletionResp)

proc createChatCompletionWithTools*(
  api: OpenAiApi,
  req: CreateChatCompletionReq,
  tools: ToolsTable,
  callback: ChatCompletionCallback = nil
): CreateChatCompletionResp =
  ## Create a chat completion with tool calling.
  ## The callback is called after each response, allowing the caller to observe the conversation flow.
  
  # Work with a copy to avoid mutating the input
  var workingReq = req
  workingReq.stream = option(false)
  sanitizeChatReq(workingReq)

  # Add the tools to the request
  if tools.len > 0:
    var toolSeq: seq[Tool] = @[]
    for toolName, (toolFunc, toolImpl) in tools.pairs:
      let tool = Tool(
        `type`: "function",
        function: toolFunc
      )
      toolSeq.add(tool)
    workingReq.tools = option(toolSeq)
    # Set tool_choice to "auto" when tools are provided
    workingReq.tool_choice = option(% "auto")

  let reqBody = toJson(workingReq)
  let resp = post(api, "/chat/completions", reqBody)
  result = fromJson(resp.body, CreateChatCompletionResp)

  # Call callback after initial response
  if callback != nil:
    callback(workingReq, result)

  # Handle tool calls by iterating until no more tool calls are needed
  if tools.len > 0:
    while result.choices[0].message.get.tool_calls.isSome and 
          result.choices[0].message.get.tool_calls.get.len > 0:
      
      let toolMsg = result.choices[0].message.get
      
      # Add the assistant's message with tool calls to the conversation
      var assistantMessage = Message(
        role: "assistant",
        tool_calls: toolMsg.tool_calls
      )
      
      # Only add content if there's actual text content
      if toolMsg.content.strip() != "":
        assistantMessage.content = option(@[
          MessageContentPart(
            `type`: "text", 
            text: option(sanitizeText(toolMsg.content))
          )
        ])
      
      workingReq.messages.add(assistantMessage)
      
      # Execute each tool call and add results as tool messages
      # TODO parallel tool handling
      for toolCallReq in toolMsg.tool_calls.get:
        let toolFunc = toolCallReq.function
        
        let toolResult = if not tools.hasKey(toolFunc.name):
          # Handle unknown tools gracefully by returning an error message to the LLM
          var availableTools: seq[string] = @[]
          for name in tools.keys:
            availableTools.add(name)
          let toolsList = availableTools.join(", ")
          &"Error: Tool '{toolFunc.name}' does not exist. Available tools are: {toolsList}. Please use one of the available tools instead."
        else:
          let (_, toolImpl) = tools[toolFunc.name]
          let toolFuncArgs = parseJson(toolFunc.arguments)
          toolImpl(toolFuncArgs)
        
        # Add tool result message
        workingReq.messages.add(Message(
          role: "tool",
          content: option(@[
            MessageContentPart(
              `type`: "text", 
              text: option(sanitizeText(toolResult))
            )
          ]),
          tool_call_id: option(toolCallReq.id)
        ))
      
      # Make follow-up request with updated messages
      sanitizeChatReq(workingReq)
      let followUpReqBody = toJson(workingReq)
      let followUpResp = post(api, "/chat/completions", followUpReqBody)
      result = fromJson(followUpResp.body, CreateChatCompletionResp)

      # Call callback after each follow-up response
      if callback != nil:
        callback(workingReq, result)

  return result

proc streamChatCompletion*(
  api: OpenAiApi,
  req: CreateChatCompletionReq
): OpenAIStream =
  ## Stream a chat completion response
  req.stream = option(true)
  var sanitizedReq = req
  sanitizeChatReq(sanitizedReq)
  let reqBody = toJson(sanitizedReq)
  return OpenAIStream(stream: postStream(api, "/chat/completions", reqBody))

proc createChatCompletion*(
  api: OpenAiApi,
  model: string,
  systemPrompt: string,
  input: string,
  responseFormat: JsonNode = nil
): string =
  ## Create a chat completion.
  let req = CreateChatCompletionReq()
  req.model = model

  if responseFormat != nil:
    let respObj = ResponseFormatObj()
    respObj.`type` = "json_schema"
    respObj.json_schema = option(responseFormat)
    req.response_format = option(respObj)

  req.messages = @[
    Message(
      role: "system",
      content: option(@[
        MessageContentPart(`type`: "text", text: option(sanitizeText(systemPrompt)))
      ])
    ),
    Message(
      role: "user",
      content: option(@[
        MessageContentPart(`type`: "text", text: option(sanitizeText(input)))
      ])
    )
  ]
  var mutableReq = req
  sanitizeChatReq(mutableReq)
  let resp = api.createChatCompletion(mutableReq)
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

proc createResponse*(
  api: OpenAiApi,
  req: CreateResponseReq
): OpenAiResponse =
  ## Create a model response using the new Responses API.
  ## This is OpenAI's newer, more advanced API that supports multiple input types,
  ## built-in tools, and more sophisticated reasoning.
  var mutableReq = req
  mutableReq.stream = option(false)
  let reqBody = toJson(mutableReq)
  let resp = post(api, "/responses", reqBody)
  result = fromJson(resp.body, OpenAiResponse)

proc createResponse*(
  api: OpenAiApi,
  model: string,
  input: string,
  instructions: string = ""
): OpenAiResponse =
  ## Create a simple text response using the Responses API.
  let req = CreateResponseReq()
  req.model = model
  req.input = option(@[
    ResponseInput(
      `type`: "message",
      role: option("user"),
      content: option(@[ResponseInputContent(
        `type`: "input_text",
        text: option(input)
      )])
    )
  ])
  if instructions != "":
    req.instructions = option(instructions)
  result = api.createResponse(req)

# proc streamResponse*(
#   api: OpenAiApi,
#   req: CreateResponseReq
# ): OpenAIResponseStream =
#   ## Stream a response using the Responses API.
#   var mutableReq = req
#   mutableReq.stream = option(true)
#   let reqBody = toJson(mutableReq)
#   result = OpenAIResponseStream(stream: postStream(api, "/responses", reqBody))

# proc nextResponseChunk*(s: OpenAIResponseStream): Option[JsonNode] =
#   ## Get the next chunk from a streaming response.
#   ## Returns the parsed JSON chunk or none when stream ends.

#   template returnIfChunk() =
#     var newLineIndex = s.buffer.find("\n")
#     if newLineIndex != -1:
#       var line = s.buffer[0..newLineIndex]
#       s.buffer = s.buffer[newLineIndex+1 .. ^1]

#       if line.startsWith("data: "):
#         line.removePrefix("data: ")
#         if line.strip() != "[DONE]":
#           try:
#             return option(parseJson(line))
#           except:
#             discard # Skip invalid JSON

#   # return any existing objects in the buffer
#   returnIfChunk()

#   # read in from the socket until s.buffer has a newline
#   while not s.buffer.contains("\n"):
#     try:
#       var chunk: string
#       let bytesRead = s.stream.read(chunk)
#       s.buffer &= chunk
#       if bytesRead == 0:
#         s.stream.close()
#         return none(JsonNode)
#     except:
#       s.stream.close()

#   # handle the fresh read in line
#   returnIfChunk()

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


proc pullModel*(api: OpenAiApi, model: string, timeout: int = 0) =
  ## Ask Ollama to pull a model.
  ## Only for ollama! not for other providers!
  var pullTimeout = timeout
  if pullTimeout == 0:
    pullTimeout = api.curlTimeout

  var baseUrl = api.baseUrl
  baseUrl.removeSuffix("/v1")
  let url = baseUrl & "/api/pull"
  let req = %*{
    "model": model,
    "stream": false
  }
  var headers: curly.HttpHeaders
  headers["Content-Type"] = "application/json"
  let resp = api.curly.post(url, headers, toJson(req), pullTimeout)
  if resp.code != 200:
    raise newException(OpenAiError, "Failed to pull model: " & resp.body)



# -------------------------------
# Utils

# Some helpers to help with converting requests / responses to markdown.
# these are useful for testing, debugging, and making templates of requests at runtime without a whole lot of code.
# eg: rather than log a huge json object, just write the markdown to a file somewhere.

proc toMarkdown*(req: CreateChatCompletionReq): string =
  ## Serialize a create chat completion request into markdown.
  result = "# Chat Completion Request\n\n"
  
  # Basic settings
  result &= "## Request Settings\n\n"
  result &= &"- **Model**: {req.model}\n"
  
  if req.temperature.isSome:
    result &= &"- **Temperature**: {req.temperature.get}\n"
  if req.max_tokens.isSome:
    result &= &"- **Max Tokens**: {req.max_tokens.get}\n"
  if req.top_p.isSome:
    result &= &"- **Top P**: {req.top_p.get}\n"
  if req.frequency_penalty.isSome:
    result &= &"- **Frequency Penalty**: {req.frequency_penalty.get}\n"
  if req.presence_penalty.isSome:
    result &= &"- **Presence Penalty**: {req.presence_penalty.get}\n"
  if req.n.isSome:
    result &= &"- **N (Choices)**: {req.n.get}\n"
  if req.seed.isSome:
    result &= &"- **Seed**: {req.seed.get}\n"
  if req.stop.isSome:
    result &= &"- **Stop**: {req.stop.get}\n"
  if req.stream.isSome:
    result &= &"- **Stream**: {req.stream.get}\n"
  if req.user.isSome:
    result &= &"- **User**: {req.user.get}\n"
  
  # Response format
  if req.response_format.isSome:
    result &= &"- **Response Format**: {req.response_format.get.`type`}\n"
    if req.response_format.get.json_schema.isSome:
      result &= "- **JSON Schema**: Available\n"
  
  # Advanced settings
  if req.logprobs.isSome:
    result &= &"- **Log Probs**: {req.logprobs.get}\n"
  if req.top_logprobs.isSome:
    result &= &"- **Top Log Probs**: {req.top_logprobs.get}\n"
  if req.logit_bias.isSome and req.logit_bias.get.len > 0:
    result &= &"- **Logit Bias**: {req.logit_bias.get.len} entries\n"
  
  result &= "\n"
  
  # Messages
  result &= "## Messages\n\n"
  for i, msg in req.messages:
    result &= &"### Message {i + 1} ({msg.role})\n\n"
    
    if msg.name.isSome:
      result &= &"- **Name**: {msg.name.get}\n"
    
    if msg.tool_call_id.isSome:
      result &= &"- **Tool Call ID**: {msg.tool_call_id.get}\n"
    
    if msg.content.isSome:
      result &= "- **Content**:\n\n"
      for part in msg.content.get:
        case part.`type`:
        of "text":
          if part.text.isSome:
            result &= "```\n" & part.text.get & "\n```\n\n"
        of "image_url":
          if part.image_url.isSome:
            result &= &"**Image URL**: {part.image_url.get.url}\n"
            if part.image_url.get.detail.isSome:
              result &= &"**Detail Level**: {part.image_url.get.detail.get}\n"
            result &= "\n"
        else:
          result &= &"**Unknown content type**: {part.`type`}\n\n"
    
    if msg.tool_calls.isSome:
      result &= "- **Tool Calls**:\n"
      for tool_call in msg.tool_calls.get:
        result &= &"  - **ID**: {tool_call.id}\n"
        result &= &"  - **Type**: {tool_call.`type`}\n"
        result &= &"  - **Function**: {tool_call.function.name}\n"
        result &= &"  - **Arguments**: `{tool_call.function.arguments}`\n"
    
    result &= "\n"
  
  # Tools
  if req.tools.isSome and req.tools.get.len > 0:
    result &= "## Available Tools\n\n"
    for i, tool in req.tools.get:
      result &= &"### Tool {i + 1}: {tool.function.name}\n\n"
      result &= &"- **Type**: {tool.`type`}\n"
      if tool.function.description.isSome:
        result &= &"- **Description**: {tool.function.description.get}\n"
      if tool.function.parameters.isSome:
        result &= "- **Parameters**:\n```json\n" & $tool.function.parameters.get & "\n```\n"
      result &= "\n"
    
    # Tool choice
    if req.tool_choice.isSome:
      result &= "## Tool Choice\n\n"
      result &= "```json\n" & $req.tool_choice.get & "\n```\n\n"

proc toMarkdown*(resp: CreateChatCompletionResp): string =
  ## Serialize a create chat completion response into markdown.
  result = "# Chat Completion Response\n\n"
  
  # Basic metadata
  result &= "## Response Details\n\n"
  result &= &"- **ID**: {resp.id}\n"
  result &= &"- **Model**: {resp.model}\n"
  result &= &"- **Created**: {resp.created}\n"
  result &= &"- **Object**: {resp.`object`}\n"
  result &= &"- **System Fingerprint**: {resp.system_fingerprint}\n\n"
  
  # Choices/Messages
  result &= "## Response Choices\n\n"
  for i, choice in resp.choices:
    result &= &"### Choice {choice.index}\n\n"
    result &= &"- **Finish Reason**: {choice.finish_reason}\n"
    
    if choice.message.isSome:
      let msg = choice.message.get
      result &= &"- **Role**: {msg.role}\n"
      if msg.content != "":
        result &= "- **Content**:\n\n"
        result &= &"```\n{msg.content}\n```\n\n"
      
      if msg.name.isSome:
        result &= &"- **Name**: {msg.name.get}\n"
      
      if msg.refusal.isSome:
        result &= &"- **Refusal**: {msg.refusal.get}\n"
      
      if msg.tool_calls.isSome and msg.tool_calls.get.len > 0:
        result &= "- **Tool Calls**:\n"
        for tool_call in msg.tool_calls.get:
          result &= &"  - **ID**: {tool_call.id}\n"
          result &= &"  - **Type**: {tool_call.`type`}\n"
          result &= &"  - **Function**: {tool_call.function.name}\n"
          result &= &"  - **Arguments**: `{tool_call.function.arguments}`\n"
    
    if choice.delta.isSome:
      let delta = choice.delta.get
      result &= "- **Delta**:\n"
      result &= &"  - **Role**: {delta.role}\n"
      if delta.content != "":
        result &= &"  - **Content**: {delta.content}\n"
    
    if choice.log_probs.isSome:
      result &= "- **Log Probs**: Available\n"
    
    result &= "\n"
  
  # Usage statistics
  if resp.usage != nil:
    result &= "## Usage Statistics\n\n"
    result &= &"- **Prompt Tokens**: {resp.usage.prompt_tokens}\n"
    result &= &"- **Total Tokens**: {resp.usage.total_tokens}\n"
    if resp.usage.total_tokens > 0 and resp.usage.prompt_tokens > 0:
      let completion_tokens = resp.usage.total_tokens - resp.usage.prompt_tokens
      result &= &"- **Completion Tokens**: {completion_tokens}\n"

proc toMarkdown*(req: CreateChatCompletionReq, resp: CreateChatCompletionResp): string =
  ## Serialize both a create chat completion request and response into markdown.
  result = "# Chat Completion Exchange\n\n"
  
  # Add request section
  result &= "## Request\n\n"
  let reqMarkdown = req.toMarkdown()
  # Remove the main title from request markdown since we have our own
  var reqLines = reqMarkdown.splitLines()
  if reqLines.len > 0 and reqLines[0].startsWith("# "):
    reqLines = reqLines[1..^1]
    # Also remove empty line after title if present
    if reqLines.len > 0 and reqLines[0].strip() == "":
      reqLines = reqLines[1..^1]
  result &= reqLines.join("\n")
  
  result &= "\n\n---\n\n"
  
  # Add response section
  result &= "## Response\n\n"
  let respMarkdown = resp.toMarkdown()
  # Remove the main title from response markdown since we have our own
  var respLines = respMarkdown.splitLines()
  if respLines.len > 0 and respLines[0].startsWith("# "):
    respLines = respLines[1..^1]
    # Also remove empty line after title if present
    if respLines.len > 0 and respLines[0].strip() == "":
      respLines = respLines[1..^1]
  result &= respLines.join("\n")


proc toCreateChatCompletionReq*(markdown: string): CreateChatCompletionReq =
  ## Deserialize a create chat completion request from markdown.
  result = CreateChatCompletionReq()
  
  let lines = markdown.splitLines()
  var i = 0
  
  # Helper proc to find next section
  proc findNextSection(startIdx: int, sectionName: string): int =
    for j in startIdx..<lines.len:
      if lines[j].startsWith("## " & sectionName):
        return j
    return -1
  
  # Helper proc to extract value from bullet point
  proc extractValue(line: string, key: string): string =
    let prefix = "- **" & key & "**: "
    if line.startsWith(prefix):
      return line[prefix.len..^1]
    return ""
  
  # Helper proc to parse float from line
  proc extractFloat(line: string, key: string): float32 =
    let val = extractValue(line, key)
    if val != "":
      try:
        return parseFloat(val).float32
      except:
        return 0.0f
    return 0.0f
  
  # Helper proc to parse int from line
  proc extractInt(line: string, key: string): int =
    let val = extractValue(line, key)
    if val != "":
      try:
        return parseInt(val)
      except:
        return 0
    return 0
  
  # Helper proc to parse bool from line
  proc extractBool(line: string, key: string): bool =
    let val = extractValue(line, key)
    return val == "true"
  
  # Parse Request Settings section
  let settingsIdx = findNextSection(0, "Request Settings")
  if settingsIdx >= 0:
    i = settingsIdx + 1
    while i < lines.len and not lines[i].startsWith("## "):
      let line = lines[i].strip()
      if line.startsWith("- **"):
        let model = extractValue(line, "Model")
        if model != "": result.model = model
        
        let temp = extractFloat(line, "Temperature")
        if temp > 0.0f: result.temperature = option(temp)
        
        let maxTokens = extractInt(line, "Max Tokens")
        if maxTokens > 0: result.max_tokens = option(maxTokens)
        
        let topP = extractFloat(line, "Top P")
        if topP > 0.0f: result.top_p = option(topP)
        
        let freqPenalty = extractFloat(line, "Frequency Penalty")
        if freqPenalty != 0.0f: result.frequency_penalty = option(freqPenalty)
        
        let presPenalty = extractFloat(line, "Presence Penalty")
        if presPenalty != 0.0f: result.presence_penalty = option(presPenalty)
        
        let n = extractInt(line, "N (Choices)")
        if n > 0: result.n = option(n)
        
        let seed = extractInt(line, "Seed")
        if seed > 0: result.seed = option(seed)
        
        let stop = extractValue(line, "Stop")
        if stop != "": result.stop = option(stop)
        
        let stream = extractBool(line, "Stream")
        if line.contains("Stream"): result.stream = option(stream)
        
        let user = extractValue(line, "User")
        if user != "": result.user = option(user)
        
        let responseFormat = extractValue(line, "Response Format")
        if responseFormat != "":
          var respFmt = ResponseFormatObj()
          respFmt.`type` = responseFormat
          result.response_format = option(respFmt)
        
        let logprobs = extractBool(line, "Log Probs")
        if line.contains("Log Probs"): result.logprobs = option(logprobs)
        
        let topLogprobs = extractInt(line, "Top Log Probs")
        if topLogprobs > 0: result.top_logprobs = option(topLogprobs)
      
      inc i
  
  # Parse Messages - scan entire document for Message headers
  result.messages = @[]
  i = 0
  
  while i < lines.len:
    let line = lines[i].strip()
    
    # Look for message sections
    if line.startsWith("### Message ") and line.contains("(") and line.contains(")"):
      var message = Message()
      
      # Extract role from "### Message N (role)"
      let roleStart = line.find("(") + 1
      let roleEnd = line.find(")")
      if roleStart > 0 and roleEnd > roleStart:
        message.role = line[roleStart..<roleEnd]
      
      inc i
      var content = ""
      var inContentBlock = false
      var contentParts: seq[MessageContentPart] = @[]
      
      # Parse message details
      while i < lines.len:
        let msgLine = lines[i].strip()
        
        if inContentBlock:
          if msgLine == "```":
            inContentBlock = false
            # Add text content part
            contentParts.add(MessageContentPart(
              `type`: "text",
              text: option(content)
            ))
            content = ""
          else:
            if content != "": content &= "\n"
            content &= lines[i] # preserve original indentation
        # Only exit on section headers when NOT in a content block
        elif not inContentBlock and (lines[i].startsWith("### ") or lines[i].startsWith("## ")):
          break
        elif msgLine.startsWith("- **"):
          let name = extractValue(msgLine, "Name")
          if name != "": message.name = option(name)
          
          let toolCallId = extractValue(msgLine, "Tool Call ID")
          if toolCallId != "": message.tool_call_id = option(toolCallId)
          
          if msgLine.startsWith("- **Content**:"):
            # Content follows on next lines in a code block
            inc i
            # Skip empty lines until we find the opening ```
            while i < lines.len and lines[i].strip() == "":
              inc i
            if i < lines.len and lines[i].strip() == "```":
              inContentBlock = true
              content = ""
            else:
              dec i # Back up if we didn't find code block
          elif msgLine.startsWith("- **Tool Calls**:"):
            # Parse tool calls that follow
            inc i
            var toolCalls: seq[ToolResp] = @[]
            while i < lines.len and not lines[i].startsWith("- **") and not lines[i].startsWith("### ") and not lines[i].startsWith("## "):
              let toolLine = lines[i]
              if toolLine.startsWith("  - **ID**: "):
                var toolCall = ToolResp()
                toolCall.id = toolLine[12..^1]
                
                # Parse the rest of this tool call
                inc i
                if i < lines.len and lines[i].startsWith("  - **Type**: "):
                  toolCall.`type` = lines[i][14..^1]
                inc i
                if i < lines.len and lines[i].startsWith("  - **Function**: "):
                  var funcResp = ToolFunctionResp()
                  funcResp.name = lines[i][18..^1]
                  inc i
                  if i < lines.len and lines[i].startsWith("  - **Arguments**: `") and lines[i].endsWith("`"):
                    let argsLine = lines[i]
                    funcResp.arguments = argsLine[20..^2]
                  toolCall.function = funcResp
                
                toolCalls.add(toolCall)
              else:
                inc i
            
            if toolCalls.len > 0:
              message.tool_calls = option(toolCalls)
            dec i # Back up since outer loop will increment
        elif msgLine.startsWith("**Image URL**: "):
          # Parse image content
          let imageUrl = msgLine[15..^1]
          var imagePart = MessageContentPart(`type`: "image_url")
          var imageUrlPart = ImageUrlPart(url: imageUrl)
          
          # Check next line for detail level
          if i + 1 < lines.len and lines[i + 1].strip().startsWith("**Detail Level**: "):
            inc i
            let detail = lines[i].strip()[18..^1]
            imageUrlPart.detail = option(detail)
          
          imagePart.image_url = option(imageUrlPart)
          contentParts.add(imagePart)
        elif msgLine == "```" and not inContentBlock:
          inContentBlock = true
          content = ""
        
        inc i
      
      # Set message content if we have parts
      if contentParts.len > 0:
        message.content = option(contentParts)
      
      result.messages.add(message)
      dec i # Back up one since the outer loop will increment
    
    inc i
  
  # Parse Available Tools section
  let toolsIdx = findNextSection(0, "Available Tools")
  if toolsIdx >= 0:
    i = toolsIdx + 1
    var tools: seq[Tool] = @[]
    
    while i < lines.len and not lines[i].startsWith("## "):
      let line = lines[i].strip()
      
      # Look for tool sections
      if line.startsWith("### Tool ") and line.contains(": "):
        var tool = Tool()
        var toolFunc = ToolFunction()
        
        # Extract tool name from "### Tool N: name"
        let nameStart = line.find(": ") + 2
        toolFunc.name = line[nameStart..^1]
        
        inc i
        var inParamsBlock = false
        var paramsJson = ""
        
        # Parse tool details
        while i < lines.len and not lines[i].startsWith("### ") and not lines[i].startsWith("## "):
          let toolLine = lines[i].strip()
          
          if inParamsBlock:
            if toolLine == "```":
              inParamsBlock = false
              # Parse the JSON
              try:
                toolFunc.parameters = option(parseJson(paramsJson))
              except:
                discard # ignore JSON parse errors
              paramsJson = ""
            else:
              paramsJson &= lines[i] & "\n"
          elif toolLine.startsWith("- **"):
            let toolType = extractValue(toolLine, "Type")
            if toolType != "": tool.`type` = toolType
            
            let description = extractValue(toolLine, "Description")
            if description != "": toolFunc.description = option(description)
            
            if toolLine.startsWith("- **Parameters**:"):
              # Parameters follow in a JSON code block
              inc i
              # Skip empty lines until we find the opening ```
              while i < lines.len and lines[i].strip() == "":
                inc i
              if i < lines.len and lines[i].strip().startsWith("```"):
                inParamsBlock = true
                paramsJson = ""
              else:
                dec i # Back up if we didn't find code block
          elif toolLine.startsWith("```") and toolLine.len > 3:
            # Handle single-line JSON blocks
            let jsonStr = toolLine[3..^3] # Remove ``` from both ends
            try:
              toolFunc.parameters = option(parseJson(jsonStr))
            except:
              discard
          
          inc i
        
        tool.function = toolFunc
        tools.add(tool)
        dec i # Back up one since the outer loop will increment
      
      inc i
    
    if tools.len > 0:
      result.tools = option(tools)
  
  # Parse Tool Choice section
  let toolChoiceIdx = findNextSection(0, "Tool Choice")
  if toolChoiceIdx >= 0:
    i = toolChoiceIdx + 1
    var inJsonBlock = false
    var jsonStr = ""
    
    while i < lines.len and not lines[i].startsWith("## "):
      let line = lines[i].strip()
      
      if inJsonBlock:
        if line == "```":
          inJsonBlock = false
          # Parse the JSON
          try:
            result.tool_choice = option(parseJson(jsonStr))
          except:
            discard # ignore JSON parse errors
          jsonStr = ""
        else:
          jsonStr &= lines[i] & "\n"
      elif line == "```json":
        inJsonBlock = true
        jsonStr = ""
      
      inc i

proc toCreateChatCompletionResp*(markdown: string): CreateChatCompletionResp =
  ## Deserialize a create chat completion response from markdown.
  result = CreateChatCompletionResp()
  
  let lines = markdown.splitLines()
  var i = 0
  
  # Helper proc to find next section
  proc findNextSection(startIdx: int, sectionName: string): int =
    for j in startIdx..<lines.len:
      if lines[j].startsWith("## " & sectionName):
        return j
    return -1
  
  # Helper proc to extract value from bullet point
  proc extractValue(line: string, key: string): string =
    let prefix = "- **" & key & "**: "
    if line.startsWith(prefix):
      return line[prefix.len..^1]
    return ""
  
  # Helper proc to parse integer from line
  proc extractInt(line: string, key: string): int =
    let val = extractValue(line, key)
    if val != "":
      try:
        return parseInt(val)
      except:
        return 0
    return 0
  
  # Parse Response Details section
  let detailsIdx = findNextSection(0, "Response Details")
  if detailsIdx >= 0:
    i = detailsIdx + 1
    while i < lines.len and not lines[i].startsWith("## "):
      let line = lines[i].strip()
      if line.startsWith("- **"):
        let id = extractValue(line, "ID")
        if id != "": result.id = id
        
        let model = extractValue(line, "Model")
        if model != "": result.model = model
        
        let created = extractInt(line, "Created")
        if created > 0: result.created = created
        
        let obj = extractValue(line, "Object")
        if obj != "": result.`object` = obj
        
        let fingerprint = extractValue(line, "System Fingerprint")
        if fingerprint != "": result.system_fingerprint = fingerprint
      
      inc i
  
  # Parse Response Choices section
  result.choices = @[]
  let choicesIdx = findNextSection(0, "Response Choices")
  if choicesIdx >= 0:
    i = choicesIdx + 1
    
    while i < lines.len and not lines[i].startsWith("## "):
      let line = lines[i].strip()
      
      # Look for choice sections
      if line.startsWith("### Choice "):
        var choice = CreateChatMessage()
        let choiceNumStr = line[11..^1] # "### Choice " is 11 chars
        try:
          choice.index = parseInt(choiceNumStr)
        except:
          choice.index = 0
                
        inc i
        var content = ""
        var inContentBlock = false
        var toolCalls: seq[ToolResp] = @[]
        var message = RespMessage()
        message.role = "assistant" # Default role
        message.content = ""
        
        # Parse choice details
        while i < lines.len and not lines[i].startsWith("### ") and not lines[i].startsWith("## "):
          let choiceLine = lines[i].strip()
          
          if inContentBlock:
            if choiceLine == "```":
              inContentBlock = false
              message.content = content
            else:
              if content != "": content &= "\n"
              content &= lines[i] # preserve original indentation in content
          elif choiceLine.startsWith("- **"):
            let finishReason = extractValue(choiceLine, "Finish Reason")
            if finishReason != "": choice.finish_reason = finishReason
            
            let role = extractValue(choiceLine, "Role")
            if role != "": message.role = role
            
            let name = extractValue(choiceLine, "Name")
            if name != "": message.name = option(name)
            
            let refusal = extractValue(choiceLine, "Refusal")
            if refusal != "": message.refusal = option(refusal)
            
            if choiceLine.startsWith("- **Content**:"):
              # Content follows on next lines in a code block
              inc i
              # Skip empty lines until we find the opening ```
              while i < lines.len and lines[i].strip() == "":
                inc i
              if i < lines.len and lines[i].strip() == "```":
                inContentBlock = true
                content = ""
              else:
                dec i # Back up if we didn't find code block
            elif choiceLine.startsWith("- **Tool Calls**:"):
              # Parse tool calls that follow
              inc i
              toolCalls = @[]
              while i < lines.len and not lines[i].startsWith("- **") and not lines[i].startsWith("### ") and not lines[i].startsWith("## "):
                let toolLine = lines[i] # Don't strip - need indentation to detect structure
                if toolLine.startsWith("  - **ID**: "):
                  var toolCall = ToolResp()
                  toolCall.id = toolLine[12..^1]
                  
                  # Parse the rest of this tool call
                  inc i
                  if i < lines.len and lines[i].startsWith("  - **Type**: "):
                    toolCall.`type` = lines[i][14..^1]
                  inc i
                  if i < lines.len and lines[i].startsWith("  - **Function**: "):
                    var funcResp = ToolFunctionResp()
                    funcResp.name = lines[i][18..^1]
                    inc i
                    if i < lines.len and lines[i].startsWith("  - **Arguments**: `") and lines[i].endsWith("`"):
                      let argsLine = lines[i]
                      funcResp.arguments = argsLine[20..^2] # Remove "  - **Arguments**: `" and trailing "`"
                    toolCall.function = funcResp
                  
                  toolCalls.add(toolCall)
                else:
                  inc i
              
              if toolCalls.len > 0:
                message.tool_calls = option(toolCalls)
              dec i # Back up since outer loop will increment
          elif choiceLine == "```" and not inContentBlock:
            inContentBlock = true
            content = ""
          
          inc i
        
        # Set up the choice - always add the message since we have defaults
        choice.message = option(message)
        
        result.choices.add(choice)
        dec i # Back up one since the outer loop will increment
      
      inc i
  
  # Parse Usage Statistics section  
  let usageIdx = findNextSection(0, "Usage Statistics")
  if usageIdx >= 0:
    i = usageIdx + 1
    result.usage = Usage()
    
    while i < lines.len and not lines[i].startsWith("## "):
      let line = lines[i].strip()
      if line.startsWith("- **"):
        let promptTokens = extractInt(line, "Prompt Tokens")
        if promptTokens > 0: result.usage.prompt_tokens = promptTokens
        
        let totalTokens = extractInt(line, "Total Tokens")  
        if totalTokens > 0: result.usage.total_tokens = totalTokens
      
      inc i

proc toCreateChatCompletionReqAndResp*(markdown: string): (CreateChatCompletionReq, CreateChatCompletionResp) =
  ## Deserialize a create chat completion request and response from markdown.
  let lines = markdown.splitLines()
  
  # Find the Request and Response sections
  var requestStartIdx = -1
  var responseStartIdx = -1
  
  for i, line in lines:
    if line.strip() == "## Request":
      requestStartIdx = i
    elif line.strip() == "## Response":
      responseStartIdx = i
  
  if requestStartIdx == -1 or responseStartIdx == -1:
    # If we can't find the sections, return empty objects
    return (CreateChatCompletionReq(), CreateChatCompletionResp())
  
  # Extract request section
  var requestLines: seq[string] = @[]
  var i = requestStartIdx + 1
  while i < responseStartIdx and i < lines.len:
    # Skip the separator line "---"
    if lines[i].strip() != "---":
      requestLines.add(lines[i])
    inc i
  
  # Extract response section  
  var responseLines: seq[string] = @[]
  i = responseStartIdx + 1
  while i < lines.len:
    responseLines.add(lines[i])
    inc i
  
  # Add back the main titles that our individual parsers expect
  let requestMarkdown = "# Chat Completion Request\n\n" & requestLines.join("\n")
  let responseMarkdown = "# Chat Completion Response\n\n" & responseLines.join("\n")
  
  # Parse each section
  let req = toCreateChatCompletionReq(requestMarkdown)
  let resp = toCreateChatCompletionResp(responseMarkdown)
  
  return (req, resp)
