import
  std/[json, options, strformat, strutils, tables],
  curly, jsony,
  openai_leap/common

proc dumpHook(s: var string, v: object) =
  ## Jsony skip optional fields that are nil.
  s.add '{'
  var i = 0
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

# --- Anthropic-specific HTTP helpers ---

proc anthropicPost(api: OpenAiApi, path: string, body: string, opts: Opts = Opts()): Response =
  ## Make a POST request using Anthropic-style authentication (x-api-key header).
  var headers: curly.HttpHeaders
  headers["Content-Type"] = "application/json"
  headers["anthropic-version"] = "2023-06-01"
  if opts.bearerToken != "":
    headers["x-api-key"] = opts.bearerToken
  else:
    api.lock.sync:
      headers["x-api-key"] = api.apiKey
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
      &"API call {path} failed: {resp.code} {resp.body}"
    )
  result = resp

proc anthropicPostStream(api: OpenAiApi, path: string, body: string, opts: Opts = Opts()): ResponseStream =
  ## Make a streaming POST request using Anthropic-style authentication.
  var headers: curly.HttpHeaders
  headers["Content-Type"] = "application/json"
  headers["anthropic-version"] = "2023-06-01"
  if opts.bearerToken != "":
    headers["x-api-key"] = opts.bearerToken
  else:
    api.lock.sync:
      headers["x-api-key"] = api.apiKey
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
    var errorBody = ""
    try:
      var chunk = ""
      while true:
        let bytesRead = resp.read(chunk)
        if bytesRead == 0:
          break
        errorBody.add(chunk)
        chunk.setLen(0)
      resp.close()
    except:
      discard
    raise newException(
      OpenAiError,
      &"API call {path} failed: {resp.code} {errorBody}"
    )
  result = resp

# --- Helper procs for extracting content from responses ---

proc messageText*(resp: CreateMessageResp): string =
  ## Concatenate all text blocks from a message response.
  result = ""
  for item in resp.content:
    if item.kind == JObject and item.hasKey("type") and item["type"].getStr == "text":
      if item.hasKey("text"):
        if result.len > 0:
          result.add("\n")
        result.add(item["text"].getStr)

proc messageToolUses*(resp: CreateMessageResp): seq[ToolUseContentBlock] =
  ## Extract all tool_use blocks from a message response.
  result = @[]
  for item in resp.content:
    if item.kind == JObject and item.hasKey("type") and item["type"].getStr == "tool_use":
      result.add(ToolUseContentBlock(
        `type`: "tool_use",
        id: item["id"].getStr,
        name: item["name"].getStr,
        input: item["input"]
      ))

proc messageThinking*(resp: CreateMessageResp): seq[ThinkingContentBlock] =
  ## Extract all thinking blocks from a message response.
  result = @[]
  for item in resp.content:
    if item.kind == JObject and item.hasKey("type") and item["type"].getStr == "thinking":
      result.add(ThinkingContentBlock(
        `type`: "thinking",
        thinking: item["thinking"].getStr,
        signature: item["signature"].getStr
      ))

# --- Core procs ---

proc createMessage*(api: OpenAiApi, req: CreateMessageReq): CreateMessageResp =
  ## Create a message using the Anthropic Messages API.
  let mutableReq = fromJson(toJson(req), CreateMessageReq)
  mutableReq.stream = option(false)
  let reqBody = toJson(mutableReq)
  let resp = anthropicPost(api, "/messages", reqBody)
  result = fromJson(resp.body, CreateMessageResp)

proc createMessage*(api: OpenAiApi, model: string, maxTokens: int, prompt: string, system: string = ""): CreateMessageResp =
  ## Create a simple text message using the Anthropic Messages API.
  let req = CreateMessageReq()
  req.model = model
  req.max_tokens = maxTokens
  req.messages = @[
    AnthropicMessage(
      role: "user",
      content: % prompt
    )
  ]
  if system != "":
    req.system = option(% system)
  result = api.createMessage(req)

# --- Streaming ---

proc streamMessage*(api: OpenAiApi, req: CreateMessageReq): OpenAIStream =
  ## Stream a message response using the Anthropic Messages API.
  let mutableReq = fromJson(toJson(req), CreateMessageReq)
  mutableReq.stream = option(true)
  let reqBody = toJson(mutableReq)
  let stream = anthropicPostStream(api, "/messages", reqBody)
  result = OpenAIStream(stream: stream, buffer: "")

proc nextMessageEvent*(s: OpenAIStream): Option[JsonNode] =
  ## Get the next event from a streaming message response.
  ## Returns the parsed JSON event or none when stream ends.

  template returnIfChunk() =
    var msgEndIndex = s.buffer.find("\n\n")
    if msgEndIndex != -1:
      var message = s.buffer[0..msgEndIndex]
      s.buffer = s.buffer[msgEndIndex+2 .. ^1]

      var dataLine = ""
      for line in message.splitLines():
        if line.startsWith("data: "):
          dataLine = line
          break

      if dataLine != "":
        let jsonStr = dataLine[6..^1]
        if jsonStr == "[DONE]":
          return none(JsonNode)
        try:
          let parsed = parseJson(jsonStr)
          # Check for message_stop event
          if parsed.hasKey("type") and parsed["type"].getStr == "message_stop":
            return none(JsonNode)
          return option(parsed)
        except:
          return none(JsonNode)

  if s.buffer.len == 0:
    var chunk: string = ""
    try:
      let bytesRead = s.stream.read(chunk)
      if bytesRead == 0:
        s.stream.close()
        return none(JsonNode)
      s.buffer &= chunk
    except:
      s.stream.close()
      return none(JsonNode)

  returnIfChunk()

  while not s.buffer.contains("\n\n"):
    var chunk: string = ""
    try:
      let bytesRead = s.stream.read(chunk)
      if bytesRead == 0:
        s.stream.close()
        return none(JsonNode)
      s.buffer &= chunk
    except:
      s.stream.close()
      return none(JsonNode)

  returnIfChunk()
  return none(JsonNode)

# --- Tool calling ---

proc toAnthropicTool(name: string, toolFunc: ToolFunction): AnthropicTool =
  ## Convert a ToolFunction (Responses API format) to an AnthropicTool (Messages API format).
  var inputSchema = AnthropicToolInputSchema(`type`: "object")
  if toolFunc.parameters.isSome:
    let params = toolFunc.parameters.get
    if params.hasKey("properties"):
      inputSchema.properties = option(params["properties"])
    if params.hasKey("required"):
      var reqSeq: seq[string] = @[]
      for item in params["required"]:
        reqSeq.add(item.getStr)
      inputSchema.required = option(reqSeq)
  result = AnthropicTool(
    name: name,
    input_schema: inputSchema,
    description: toolFunc.description
  )

proc createMessageWithTools*(
  api: OpenAiApi,
  req: var CreateMessageReq,
  tools: ResponseToolsTable,
  callback: proc() = nil
): CreateMessageResp =
  ## Create a message with tool calling loop.
  ## Automatically handles tool execution until the model stops requesting tools.
  ## Accepts ResponseToolsTable (same table used by Responses API) and converts
  ## ToolFunction entries to AnthropicTool format for the request.
  req.stream = option(false)

  # Add tools to the request
  if tools.len > 0:
    var toolSeq: seq[AnthropicTool] = @[]
    for toolName, (toolFunc, impl) in tools.pairs:
      toolSeq.add(toAnthropicTool(toolName, toolFunc))
    req.tools = option(toolSeq)
    if req.tool_choice.isNone:
      req.tool_choice = option(ToolChoiceConfig(`type`: "auto"))

  let reqBody = toJson(req)
  let resp = anthropicPost(api, "/messages", reqBody)
  result = fromJson(resp.body, CreateMessageResp)

  if callback != nil:
    callback()

  if tools.len > 0:
    var toolUses = messageToolUses(result)

    while toolUses.len > 0 and result.stop_reason.isSome and result.stop_reason.get == "tool_use":
      # Append the assistant's response as a message
      req.messages.add(AnthropicMessage(
        role: "assistant",
        content: % result.content
      ))

      # Build tool result blocks
      var toolResults: seq[JsonNode] = @[]
      for toolUse in toolUses:
        let toolResult = if not tools.hasKey(toolUse.name):
          var availableTools: seq[string] = @[]
          for name in tools.keys:
            availableTools.add(name)
          let toolsList = availableTools.join(", ")
          &"Error: Tool '{toolUse.name}' does not exist. Available tools are: {toolsList}."
        else:
          let (_, toolImpl) = tools[toolUse.name]
          toolImpl(toolUse.input)

        toolResults.add(%* {
          "type": "tool_result",
          "tool_use_id": toolUse.id,
          "content": toolResult
        })

      # Add user message with tool results
      req.messages.add(AnthropicMessage(
        role: "user",
        content: % toolResults
      ))

      # Send follow-up request
      let followUpBody = toJson(req)
      let followUpResp = anthropicPost(api, "/messages", followUpBody)
      result = fromJson(followUpResp.body, CreateMessageResp)

      if callback != nil:
        callback()

      toolUses = messageToolUses(result)

  return result
