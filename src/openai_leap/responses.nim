import
  std/[json, options, os, strformat, strutils, tables],
  curly, webby, jsony,
  openai_leap/common

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

proc newResponseToolsTable*(): ResponseToolsTable =
  ## Create a new empty response tools table
  result = ResponseToolsTable(data: initTable[string, (ToolFunction, ToolImpl)]())

proc register*(table: var ResponseToolsTable, name: string, toolFunc: ToolFunction, impl: ToolImpl) =
  ## Add a tool to the response tools table
  table[name] = (toolFunc, impl)

proc registerResponseTool*(table: var ResponseToolsTable, name: string, toolFunc: ToolFunction, impl: ToolImpl) =
  ## Add a tool to the response tools table (deprecated; use register)
  table.register(name, toolFunc, impl)

proc createResponse*(
  api: OpenAiApi,
  req: CreateResponseReq
): OpenAiResponse =
  ## Create a model response using the new Responses API.
  ## This is OpenAI's newer, more advanced API that supports multiple input types,
  ## built-in tools, and more sophisticated reasoning.
  # Create a deep copy to avoid mutating the input
  let mutableReq = fromJson(toJson(req), CreateResponseReq)
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

proc getResponse*(api: OpenAiApi, responseId: string): OpenAiResponse =
  ## Get a model response by ID.
  let resp = api.get("/responses/" & responseId)
  result = fromJson(resp.body, OpenAiResponse)

proc deleteResponse*(
  api: OpenAiApi,
  responseId: string
): DeleteResponse =
  ## Delete a model response by ID.
  let resp = api.delete("/responses/" & responseId)
  result = fromJson(resp.body, DeleteResponse)

proc streamGetResponse*(api: OpenAiApi, responseId: string): OpenAIResponseStream =
  ## Stream a model response by ID.
  let queryParams = @[("stream", "true")]
  result = OpenAIResponseStream(stream: getStream(api, "/responses/" & responseId, queryParams))

proc streamResponse*(
  api: OpenAiApi,
  req: CreateResponseReq
): OpenAIResponseStream =
  ## Stream a response using the Responses API.
  # Create a deep copy to avoid mutating the input
  let mutableReq = fromJson(toJson(req), CreateResponseReq)
  mutableReq.stream = option(true)
  let reqBody = toJson(mutableReq)
  let stream = postStream(api, "/responses", reqBody)
  result = OpenAIResponseStream(stream: stream)

proc extractToolCallsFromResponse(resp: OpenAiResponse): seq[ResponseToolCall] =
  ## Extract all tool calls from a response's output.
  result = @[]
  for output in resp.output:
    if output.`type` == "function_call" and output.call_id.isSome and output.name.isSome and output.arguments.isSome:
      result.add(ResponseToolCall(
        `type`: output.`type`,
        call_id: output.call_id.get,
        name: output.name.get,
        arguments: output.arguments.get
      ))
    elif output.content.isSome:
      for content in output.content.get:
        if content.`type` == "function_call" and content.tool_call.isSome:
          let toolCall = content.tool_call.get
          if toolCall.function.isSome:
            result.add(ResponseToolCall(
              `type`: toolCall.`type`,
              call_id: toolCall.id,
              name: toolCall.function.get.name,
              arguments: toolCall.function.get.arguments
            ))

proc waitForResponseCompletion(api: OpenAiApi, resp: OpenAiResponse, maxWaitTime: int = 300): OpenAiResponse =
  ## Wait for a response to complete, polling if status is "in_progress".
  ## maxWaitTime is in seconds.
  result = resp
  var elapsed = 0
  while result.status == "in_progress" and elapsed < maxWaitTime:
    sleep(1000)  # Wait 1 second
    elapsed += 1
    result = api.getResponse(result.id)

  if result.status == "in_progress":
    raise newException(OpenAiError, "Response did not complete within timeout")

proc createToolOutputInput(toolCallId: string, toolResult: string): ResponseInput =
  ## Create a ResponseInput for a tool call output.
  result = ResponseInput(
    `type`: "function_call_output",
    call_id: option(toolCallId),
    output: option(sanitizeText(toolResult))
  )

proc createToolCallInput(toolCall: ResponseToolCall): ResponseInput =
  ## Create a ResponseInput for a tool call request.
  let name = toolCall.name
  let args = toolCall.arguments
  let callId = toolCall.call_id
  let contentText = "Tool call: " & name & "\nCall ID: " & callId & "\nArguments: " & args
  result = ResponseInput(
    `type`: "message",
    role: option("assistant"),
    content: option(@[ResponseInputContent(
      `type`: "input_text",
      text: option(contentText)
    )])
  )

proc executeToolCall(tools: ResponseToolsTable, toolCall: ResponseToolCall): string =
  ## Execute a tool call and return the result.
  ## Handles error cases for missing tools.
  if not tools.hasKey(toolCall.name):
    var availableTools: seq[string] = @[]
    for name in tools.keys:
      availableTools.add(name)
    let toolsList = availableTools.join(", ")
    result = &"Error: Tool '{toolCall.name}' does not exist. Available tools are: {toolsList}."
  else:
    let (_, toolImpl) = tools[toolCall.name]
    let toolFuncArgs = parseJson(toolCall.arguments)
    result = toolImpl(toolFuncArgs)

proc createResponseWithTools*(
  api: OpenAiApi,
  req: var CreateResponseReq,
  tools: ResponseToolsTable,
  callback: ResponseCallback = nil,
  usePreviousResponseId: bool = true
): OpenAiResponse =
  ## Create a response with tool calling, similar to createChatCompletionWithTools.
  ## Handles tool execution loop automatically with async status polling.
  ## usePreviousResponseId can be used to turn the feature off for servers that don't support it, like llama.cpp.
  ## The req parameter is mutated to include the full conversation history.

  req.stream = option(false)

  # Convert ToolsTable to ResponseTool sequence
  var toolSeq: seq[ResponseTool] = @[]
  if tools.len > 0:
    for toolName, (toolFunc, toolImpl) in tools.pairs:
      let tool = ResponseTool(
        `type`: "function",
        name: toolName,
        description: toolFunc.description,
        parameters: toolFunc.parameters
      )
      toolSeq.add(tool)
    req.tools = option(toolSeq)
    if req.tool_choice.isNone:
      req.tool_choice = option(% "auto")
    if req.store.isNone or req.store.get == false:
      req.store = option(true)

  var followUpToolChoice = req.tool_choice
  if followUpToolChoice.isSome:
    let choiceNode = followUpToolChoice.get
    if choiceNode.kind == JObject and choiceNode.hasKey("type"):
      let typeNode = choiceNode["type"]
      if typeNode.kind == JString and typeNode.getStr == "function":
        followUpToolChoice = option(% "auto")

  let reqBody = toJson(req)
  let resp = post(api, "/responses", reqBody)
  result = fromJson(resp.body, OpenAiResponse)

  result = waitForResponseCompletion(api, result)

  if callback != nil:
    callback(req, result)

  if tools.len > 0:
    var toolCalls = extractToolCallsFromResponse(result)

    while toolCalls.len > 0:
      var toolCallInputs: seq[ResponseInput] = @[]
      for toolCall in toolCalls:
        toolCallInputs.add(createToolCallInput(toolCall))

      if toolCallInputs.len > 0:
        if req.input.isNone:
          req.input = option(toolCallInputs)
        else:
          var currentHistory = req.input.get
          for toolCallInput in toolCallInputs:
            currentHistory.add(toolCallInput)
          req.input = option(currentHistory)

      var toolOutputs: seq[ResponseInput] = @[]
      for toolCall in toolCalls:
        let toolResult = executeToolCall(tools, toolCall)
        let toolOutput = createToolOutputInput(toolCall.call_id, toolResult)
        toolOutputs.add(toolOutput)

      # Always add tool outputs to the top-level request's conversation history
      if req.input.isNone:
        req.input = option(toolOutputs)
      else:
        var currentHistory = req.input.get
        for output in toolOutputs:
          currentHistory.add(output)
        req.input = option(currentHistory)

      var followUpReq = CreateResponseReq()
      followUpReq.model = req.model
      followUpReq.tools = req.tools
      followUpReq.tool_choice = followUpToolChoice
      followUpReq.store = req.store
      followUpReq.parallel_tool_calls = req.parallel_tool_calls
      followUpReq.temperature = req.temperature
      followUpReq.max_output_tokens = req.max_output_tokens
      followUpReq.reasoning = req.reasoning


      if usePreviousResponseId:
        # Use previous_response_id for providers that support it
        followUpReq.previous_response_id = option(result.id)
        if req.store.isSome and req.store.get:
          followUpReq.store = option(true)

        # Only send the new tool outputs as input - previous_response_id provides conversation context
        followUpReq.input = option(toolOutputs)
      else:
        # when not using previous_response_id, we need to send the full accumulated conversation history from the top-level req
        # Send the full accumulated conversation history from the top-level req
        # (we previously appended the tool output so we can just use the input as-is)
        followUpReq.input = req.input

      let followUpReqBody = toJson(followUpReq)
      let followUpResp = post(api, "/responses", followUpReqBody)
      result = fromJson(followUpResp.body, OpenAiResponse)
      result = waitForResponseCompletion(api, result)

      if callback != nil:
        callback(followUpReq, result)

      toolCalls = extractToolCallsFromResponse(result)

  return result

proc nextResponseChunk*(s: OpenAIResponseStream): Option[JsonNode] =
  ## Get the next chunk from a streaming response.
  ## Returns the parsed JSON chunk or none when stream ends.

  template returnIfChunk() =
    # Find complete SSE message (ends with double newline)
    var msgEndIndex = s.buffer.find("\n\n")
    if msgEndIndex != -1:
      var message = s.buffer[0..msgEndIndex]
      s.buffer = s.buffer[msgEndIndex+2 .. ^1]

      # Parse the SSE message
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
          return option(parseJson(jsonStr))
        except:
          return none(JsonNode)

  if s.buffer.len == 0:
    # If buffer is empty, read from stream
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

  # Check if we have a complete message
  returnIfChunk()

  # read in from the socket until s.buffer has a complete SSE message (double newline)
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
