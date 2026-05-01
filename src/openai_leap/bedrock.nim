import
  std/[base64, json, options, strformat, strutils, tables],
  curly, jsony,
  openai_leap/[aws_credentials, common, eventstream, sigv4]

export aws_credentials, eventstream, sigv4

type
  BedrockStream* = ref object
    stream*: ResponseStream
    parser*: EventStreamParser

proc bedrockUrl(region, modelId, action: string): string =
  &"https://bedrock-runtime.{region}.amazonaws.com/model/{modelId}/{action}"

proc stripNulls(node: var JsonNode) =
  if node.kind == JObject:
    var keysToDelete: seq[string] = @[]
    for key, val in node:
      if val.kind == JNull:
        keysToDelete.add(key)
      else:
        var mutableVal = val
        stripNulls(mutableVal)
        node[key] = mutableVal
    for key in keysToDelete:
      node.delete(key)
  elif node.kind == JArray:
    for i in 0 ..< node.len:
      var elem = node[i]
      stripNulls(elem)
      node.elems[i] = elem

proc prepareBedrockBody(req: CreateMessageReq): string =
  var j = parseJson(toJson(req))
  j.delete("model")
  j.delete("stream")
  stripNulls(j)
  j["anthropic_version"] = %"bedrock-2023-05-31"
  result = $j

proc bedrockPost(
  api: OpenAiApi,
  config: BedrockConfig,
  url, body: string
): Response =
  let creds = loadAwsCredentials(config.profile)
  var headers: curly.HttpHeaders
  headers["Content-Type"] = "application/json"
  headers["Accept"] = "application/json"
  signRequest(creds, "POST", url, config.region, "bedrock", headers, body)

  let resp = api.curly.post(url, headers, body, api.curlTimeout)
  if resp.code != 200:
    raise newException(
      OpenAiError,
      &"Bedrock API call failed: {resp.code} {resp.body}"
    )
  result = resp

proc bedrockPostStream(
  api: OpenAiApi,
  config: BedrockConfig,
  url, body: string
): ResponseStream =
  let creds = loadAwsCredentials(config.profile)
  var headers: curly.HttpHeaders
  headers["Content-Type"] = "application/json"
  headers["Accept"] = "application/vnd.amazon.eventstream"
  signRequest(creds, "POST", url, config.region, "bedrock", headers, body)

  let resp = api.curly.request("POST", url, headers, body, api.curlTimeout)
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
      &"Bedrock streaming API call failed: {resp.code} {errorBody}"
    )
  result = resp

proc createBedrockMessage*(
  api: OpenAiApi,
  config: BedrockConfig,
  req: CreateMessageReq
): CreateMessageResp =
  let url = bedrockUrl(config.region, req.model, "invoke")
  let body = prepareBedrockBody(req)
  let resp = bedrockPost(api, config, url, body)
  result = fromJson(resp.body, CreateMessageResp)

proc streamBedrockMessage*(
  api: OpenAiApi,
  config: BedrockConfig,
  req: CreateMessageReq
): BedrockStream =
  let url = bedrockUrl(config.region, req.model, "invoke-with-response-stream")
  let body = prepareBedrockBody(req)
  let stream = bedrockPostStream(api, config, url, body)
  result = BedrockStream(stream: stream, parser: newEventStreamParser())

proc nextBedrockMessageEvent*(s: BedrockStream): Option[JsonNode] =
  while true:
    var msg = s.parser.next()
    if msg.isSome:
      let m = msg.get()
      var messageType = ""
      for (k, v) in m.headers:
        if k == ":message-type":
          messageType = v
      if messageType == "exception":
        let errorJson = try: parseJson(m.payload) except: %*{"error": m.payload}
        raise newException(OpenAiError, "Bedrock stream error: " & $errorJson)
      if messageType == "event" and m.payload.len > 0:
        let wrapper = try: parseJson(m.payload) except: continue
        if wrapper.hasKey("bytes"):
          let decoded = decode(wrapper["bytes"].getStr)
          let event = try: parseJson(decoded) except: continue
          if event.hasKey("type") and event["type"].getStr == "message_stop":
            return none(JsonNode)
          return some(event)
      continue

    var chunk = ""
    try:
      let bytesRead = s.stream.read(chunk)
      if bytesRead == 0:
        s.stream.close()
        return none(JsonNode)
      s.parser.feed(chunk)
    except:
      try: s.stream.close() except: discard
      return none(JsonNode)

proc createBedrockMessageWithTools*(
  api: OpenAiApi,
  config: BedrockConfig,
  req: var CreateMessageReq,
  tools: ResponseToolsTable,
  callback: proc() = nil
): CreateMessageResp =
  req.stream = option(false)

  if tools.len > 0 and req.tools.isNone:
    var toolSeq: seq[AnthropicTool] = @[]
    for toolName, (toolFunc, impl) in tools.pairs:
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
      toolSeq.add(AnthropicTool(
        name: toolName,
        input_schema: inputSchema,
        description: toolFunc.description
      ))
    req.tools = option(toolSeq)
    if req.tool_choice.isNone:
      req.tool_choice = option(ToolChoiceConfig(`type`: "auto"))

  let url = bedrockUrl(config.region, req.model, "invoke")
  let body = prepareBedrockBody(req)
  let resp = bedrockPost(api, config, url, body)
  result = fromJson(resp.body, CreateMessageResp)

  if callback != nil:
    callback()

  if tools.len > 0:
    var toolUses: seq[ToolUseContentBlock] = @[]
    for item in result.content:
      if item.kind == JObject and item.hasKey("type") and item["type"].getStr == "tool_use":
        toolUses.add(ToolUseContentBlock(
          `type`: "tool_use",
          id: item["id"].getStr,
          name: item["name"].getStr,
          input: item["input"]
        ))

    while toolUses.len > 0 and result.stop_reason.isSome and result.stop_reason.get == "tool_use":
      req.messages.add(AnthropicMessage(
        role: "assistant",
        content: % result.content
      ))

      var toolResults: seq[JsonNode] = @[]
      for toolUse in toolUses:
        let toolResult = if not tools.hasKey(toolUse.name):
          var availableTools: seq[string] = @[]
          for name in tools.keys:
            availableTools.add(name)
          &"Error: Tool '{toolUse.name}' does not exist. Available tools are: {availableTools.join(\", \")}."
        else:
          let (_, toolImpl) = tools[toolUse.name]
          toolImpl(toolUse.input)

        toolResults.add(%* {
          "type": "tool_result",
          "tool_use_id": toolUse.id,
          "content": toolResult
        })

      req.messages.add(AnthropicMessage(
        role: "user",
        content: % toolResults
      ))

      let followUpUrl = bedrockUrl(config.region, req.model, "invoke")
      let followUpBody = prepareBedrockBody(req)
      let followUpResp = bedrockPost(api, config, followUpUrl, followUpBody)
      result = fromJson(followUpResp.body, CreateMessageResp)

      if callback != nil:
        callback()

      toolUses = @[]
      for item in result.content:
        if item.kind == JObject and item.hasKey("type") and item["type"].getStr == "tool_use":
          toolUses.add(ToolUseContentBlock(
            `type`: "tool_use",
            id: item["id"].getStr,
            name: item["name"].getStr,
            input: item["input"]
          ))
