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
  ## Create a ResponseInput for a tool call (function_call type).
  result = ResponseInput(
    `type`: "function_call",
    call_id: option(toolCall.call_id),
    name: option(toolCall.name),
    arguments: option(toolCall.arguments)
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

      var followUpReq = fromJson(toJson(req), CreateResponseReq)
      followUpReq.input = none(seq[ResponseInput])
      followUpReq.previous_response_id = none(string)
      followUpReq.stream = none(bool)
      followUpReq.tool_choice = followUpToolChoice


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


type
  StreamChunkKind* = enum
    ScReasoning
    ScOutputText
    ScToolCall
    ScDone

  ResponseStreamChunk* = object
    kind*: StreamChunkKind
    text*: string
    toolName*: string
    toolCallId*: string
    toolArgs*: string

  StreamingToolSession* = ref object
    api: OpenAiApi
    tools: ResponseToolsTable
    req*: CreateResponseReq
    stream: OpenAIResponseStream
    completedResponse*: OpenAiResponse
    done*: bool
    usePreviousResponseId: bool


proc newStreamingToolSession*(
  api: OpenAiApi,
  req: CreateResponseReq,
  tools: ResponseToolsTable,
  usePreviousResponseId: bool = true
): StreamingToolSession =
  ## Start a streaming tool session. Call next() repeatedly to get chunks.
  let mutableReq = fromJson(toJson(req), CreateResponseReq)

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
    mutableReq.tools = option(toolSeq)
    if mutableReq.tool_choice.isNone:
      mutableReq.tool_choice = option(% "auto")
    if mutableReq.store.isNone or mutableReq.store.get == false:
      mutableReq.store = option(true)

  result = StreamingToolSession(
    api: api,
    tools: tools,
    req: mutableReq,
    stream: api.streamResponse(mutableReq),
    completedResponse: nil,
    done: false,
    usePreviousResponseId: usePreviousResponseId
  )


proc startFollowUp(session: StreamingToolSession, toolOutputs: seq[ResponseInput]) =
  ## Start a new streaming request with tool results.
  var followUpReq = fromJson(toJson(session.req), CreateResponseReq)
  followUpReq.input = none(seq[ResponseInput])
  followUpReq.previous_response_id = none(string)
  followUpReq.stream = none(bool)

  if session.usePreviousResponseId and session.completedResponse != nil:
    followUpReq.previous_response_id = option(session.completedResponse.id)
    if session.req.store.isSome and session.req.store.get:
      followUpReq.store = option(true)
    followUpReq.input = option(toolOutputs)
  else:
    if session.req.input.isNone:
      session.req.input = option(toolOutputs)
    else:
      var currentHistory = session.req.input.get
      for output in toolOutputs:
        currentHistory.add(output)
      session.req.input = option(currentHistory)
    followUpReq.input = session.req.input

  session.stream = session.api.streamResponse(followUpReq)
  session.completedResponse = nil


proc next*(session: StreamingToolSession): Option[ResponseStreamChunk] =
  ## Get the next chunk from the streaming tool session.
  ## Handles tool execution automatically between streaming rounds.
  if session.done:
    return none(ResponseStreamChunk)

  while true:
    let chunkOpt = session.stream.nextResponseChunk()
    if chunkOpt.isNone:
      session.done = true
      return none(ResponseStreamChunk)

    let chunk = chunkOpt.get()
    if not chunk.hasKey("type") or chunk["type"].kind != JString:
      continue

    let eventType = chunk["type"].str

    if eventType == "response.reasoning_text.delta":
      if chunk.hasKey("delta") and chunk["delta"].kind == JString:
        let delta = chunk["delta"].str
        if delta.len > 0:
          return option(ResponseStreamChunk(kind: ScReasoning, text: delta))

    elif eventType == "response.output_text.delta":
      if chunk.hasKey("delta") and chunk["delta"].kind == JString:
        let delta = chunk["delta"].str
        if delta.len > 0:
          return option(ResponseStreamChunk(kind: ScOutputText, text: delta))

    elif eventType == "response.function_call_arguments.done":
      var toolName = ""
      var callId = ""
      var args = ""
      if chunk.hasKey("arguments") and chunk["arguments"].kind == JString:
        args = chunk["arguments"].str
      if chunk.hasKey("item_id") and chunk["item_id"].kind == JString:
        callId = chunk["item_id"].str
      # item_id is the function_call item id, not the call_id. We'll get call_id from completed response.
      return option(ResponseStreamChunk(kind: ScToolCall, toolName: toolName, toolCallId: callId, toolArgs: args))

    elif eventType == "response.completed":
      if not chunk.hasKey("response") or chunk["response"].kind != JObject:
        session.done = true
        return none(ResponseStreamChunk)

      let respNode = chunk["response"]
      session.completedResponse = fromJson($respNode, OpenAiResponse)

      let toolCalls = extractToolCallsFromResponse(session.completedResponse)
      if toolCalls.len == 0:
        session.done = true
        return option(ResponseStreamChunk(kind: ScDone))

      # Execute tool calls and start follow-up
      var toolOutputs: seq[ResponseInput] = @[]
      for toolCall in toolCalls:
        let toolResult = executeToolCall(session.tools, toolCall)
        let toolOutput = createToolOutputInput(toolCall.call_id, toolResult)
        toolOutputs.add(toolOutput)

      # Also accumulate tool call inputs in the request history for non-previous_response_id mode
      if not session.usePreviousResponseId:
        var toolCallInputs: seq[ResponseInput] = @[]
        for toolCall in toolCalls:
          toolCallInputs.add(createToolCallInput(toolCall))
        if session.req.input.isNone:
          session.req.input = option(toolCallInputs)
        else:
          var currentHistory = session.req.input.get
          for input in toolCallInputs:
            currentHistory.add(input)
          session.req.input = option(currentHistory)

      startFollowUp(session, toolOutputs)
      # Continue the while loop to read from the new stream
