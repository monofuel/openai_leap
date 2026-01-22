import
  std/[json, options, strformat, strutils, tables],
  curly, jsony, webby,
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

proc newToolsTable*(): ToolsTable =
  ## Create a new empty tools table
  result = initTable[string, (ToolFunction, ToolImpl)]()

proc register*(table: var ToolsTable, name: string, toolFunc: ToolFunction, impl: ToolImpl) =
  ## Add a tool to the tools table
  table[name] = (toolFunc, impl)

proc createChatCompletion*(
  api: OpenAiApi,
  req: CreateChatCompletionReq
): CreateChatCompletionResp =
  ## Create a chat completion without tool calling.
  # Create a deep copy to avoid mutating the input
  var mutableReq = fromJson(toJson(req), CreateChatCompletionReq)
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

  # Create a deep copy to avoid mutating the input
  var workingReq = fromJson(toJson(req), CreateChatCompletionReq)
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
  # Create a deep copy to avoid mutating the request
  var mutableReq = fromJson(toJson(req), CreateChatCompletionReq)
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
