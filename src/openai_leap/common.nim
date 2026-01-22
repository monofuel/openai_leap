import
  std/[json, locks, options, tables],
  curly

# Important: the OpenAI API uses snake_case. request objects must be snake_case this or the fields will be ignored by the API.
# jsony is flexible in parsing the responses in either camelCase or snake_case but better to use snake_case for consistency.

type
  OpenAiApiObj* = object
    curly*: Curly
    lock*: Lock # lock for modifying the openai api object
    baseUrl*: string
    curlTimeout*: int
    apiKey*: string
    organization*: string
  OpenAiApi* = ptr OpenAiApiObj

  OpenAiError* = object of CatchableError ## Raised if an operation fails.

  Opts* = object # Per-request options
    bearerToken*: string = ""
    organization*: string = ""
    curlTimeout*: int = 0

  OpenAIStream* = ref object
    stream*: ResponseStream
    buffer*: string

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

  DeleteResponse* = ref object
    id*: string
    `object`*: string
    deleted*: bool

  EmbeddingTask* = enum
    RetrievalQuery
    RetrievalDocument
    QuestionAnswering
    FactVerification
    Classification
    Clustering
    SemanticSimilarity
    CodeRetrieval

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

  ResponseToolsTable* = Table[string, (ToolFunction, ToolImpl)]

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
    `type`*: string # message, image_url, file, function_call_output
    role*: Option[string] # user, assistant, system, developer (for message type)
    content*: Option[seq[ResponseInputContent]] # for message type
    call_id*: Option[string] # for function_call_output
    output*: Option[string] # for function_call_output

  ResponseOutputText* = ref object
    text*: string

  ResponseOutputImage* = ref object
    url*: string

  ResponseOutputToolCall* = ref object
    id*: string
    `type`*: string # function, builtin_function
    function*: Option[ToolFunctionResp] # for custom functions

  ResponseOutputContent* = ref object
    `type`*: string # output_text, tool_call, etc.
    text*: Option[string]
    tool_call*: Option[ResponseOutputToolCall]

  ResponseOutput* = ref object
    id*: string
    `type`*: string # message, function_call, etc.
    status*: Option[string]
    role*: Option[string]
    content*: Option[seq[ResponseOutputContent]]
    call_id*: Option[string]
    name*: Option[string]
    arguments*: Option[string]

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

  ResponseCallback* = proc(req: CreateResponseReq, resp: OpenAiResponse)

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
    store*: Option[bool] = option(false)
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
