import
  std/[asyncdispatch, base64, httpclient, httpcore, json, options, random, strformat, strutils, uri],
  jsony, ws,
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

# --- Types ---

type
  RealtimeTranscriptionConfig* = ref object
    ## Configuration for input audio transcription.
    model*: Option[string]
    language*: Option[string]
    prompt*: Option[string]

  RealtimeSessionConfig* = ref object
    ## Configuration for a realtime session.
    model*: Option[string]
    instructions*: Option[string]
    modalities*: Option[seq[string]]
    temperature*: Option[float32]
    max_response_output_tokens*: Option[JsonNode]
    voice*: Option[string]
    input_audio_format*: Option[string]
    output_audio_format*: Option[string]
    input_audio_transcription*: Option[RealtimeTranscriptionConfig]
    turn_detection*: Option[JsonNode]
    tools*: Option[seq[ResponseTool]]
    tool_choice*: Option[JsonNode]

  RealtimeContentPart* = ref object
    ## A content part within a realtime conversation item.
    `type`*: string
    text*: Option[string]
    audio*: Option[string]
    transcript*: Option[string]
    # NOT YET IMPLEMENTED: image_url

  RealtimeConversationItem* = ref object
    ## A conversation item in the realtime session.
    id*: Option[string]
    `type`*: Option[string]
    `object`*: Option[string]
    status*: Option[string]
    role*: Option[string]
    content*: Option[seq[RealtimeContentPart]]
    call_id*: Option[string]
    name*: Option[string]
    arguments*: Option[string]
    output*: Option[string]

  RealtimeResponseConfig* = ref object
    ## Configuration for triggering a response.
    modalities*: Option[seq[string]]
    instructions*: Option[string]
    temperature*: Option[float32]
    max_output_tokens*: Option[JsonNode]
    voice*: Option[string]
    tools*: Option[seq[ResponseTool]]
    tool_choice*: Option[JsonNode]

  RealtimeClientEvent* = ref object
    ## A client event sent to the realtime API.
    event_id*: Option[string]
    `type`*: string
    session*: Option[RealtimeSessionConfig]
    item*: Option[RealtimeConversationItem]
    item_id*: Option[string]
    content_index*: Option[int]
    audio_end_ms*: Option[int]
    response*: Option[RealtimeResponseConfig]
    audio*: Option[string]

  RealtimeRateLimit* = ref object
    ## Rate limit information from the server.
    name*: string
    limit*: int
    remaining*: int
    reset_seconds*: float

  RealtimeError* = ref object
    ## Error details from the realtime API.
    `type`*: string
    code*: Option[string]
    message*: string
    param*: Option[string]

  RealtimeResponseObject* = ref object
    ## The response object returned within server events.
    id*: Option[string]
    `object`*: Option[string]
    status*: Option[string]
    output*: Option[seq[RealtimeConversationItem]]
    usage*: Option[JsonNode]
    # NOT YET IMPLEMENTED: status_details

  RealtimeServerEvent* = ref object
    ## A server event received from the realtime API.
    ## The type field discriminates which other fields are populated.
    event_id*: Option[string]
    `type`*: string
    session*: Option[RealtimeSessionConfig]
    conversation*: Option[JsonNode]
    item*: Option[RealtimeConversationItem]
    response*: Option[RealtimeResponseObject]
    delta*: Option[string]
    text*: Option[string]
    part*: Option[RealtimeContentPart]
    content_index*: Option[int]
    output_index*: Option[int]
    response_id*: Option[string]
    item_id*: Option[string]
    error*: Option[RealtimeError]
    rate_limits*: Option[seq[RealtimeRateLimit]]
    audio_start_ms*: Option[int]
    audio_end_ms*: Option[int]
    transcript*: Option[string]
    previous_item_id*: Option[string]
    name*: Option[string]
    call_id*: Option[string]
    arguments*: Option[string]

  RealtimeSession* = ref object
    ## An active realtime session wrapping a WebSocket connection.
    socket*: WebSocket
    connected*: bool
    pendingRecv*: Future[string]

# --- WebSocket connection with custom headers ---

proc connectWebSocket(url: string, extraHeaders: seq[(string, string)]): Future[WebSocket] {.async.} =
  ## Open a WebSocket connection with custom headers for authentication.
  var ws = WebSocket()
  ws.masked = true

  var parsedUri = parseUri(url)
  var port = Port(443)
  case parsedUri.scheme
  of "wss":
    parsedUri.scheme = "https"
    port = Port(443)
  of "ws":
    parsedUri.scheme = "http"
    port = Port(80)
  else:
    raise newException(WebSocketError, &"Scheme {parsedUri.scheme} not supported")
  if parsedUri.port.len > 0:
    port = Port(parseInt(parsedUri.port))

  var client = newAsyncHttpClient()

  var secStr = newString(16)
  for i in 0 ..< secStr.len:
    secStr[i] = char rand(255)
  let secKey = base64.encode(secStr)

  client.headers = newHttpHeaders({
    "Connection": "Upgrade",
    "Upgrade": "websocket",
    "Sec-WebSocket-Version": "13",
    "Sec-WebSocket-Key": secKey,
  })
  for (key, value) in extraHeaders:
    client.headers[key] = value

  var res = await client.get($parsedUri)
  let hasUpgrade = res.headers.getOrDefault("Upgrade")
  if hasUpgrade.toLowerAscii() != "websocket":
    raise newException(WebSocketFailedUpgradeError,
      "Failed to upgrade to WebSocket")
  ws.tcpSocket = client.getSocket()
  ws.readyState = Open
  return ws

# --- Connection ---

proc connectRealtime*(api: OpenAiApi, model: string): RealtimeSession =
  ## Connect to the OpenAI Realtime API via WebSocket.
  ## Returns a RealtimeSession for sending and receiving events.
  ## The first event received will be session.created.
  var wsUrl = api.baseUrl
  if wsUrl.startsWith("https://"):
    wsUrl = "wss://" & wsUrl[8..^1]
  elif wsUrl.startsWith("http://"):
    wsUrl = "ws://" & wsUrl[7..^1]
  wsUrl = wsUrl & "/realtime?model=" & model

  var apiKey: string
  api.lock.sync:
    apiKey = api.apiKey

  let headers = @[
    ("Authorization", "Bearer " & apiKey),
    ("OpenAI-Beta", "realtime=v1"),
  ]

  let socket = waitFor connectWebSocket(wsUrl, headers)
  result = RealtimeSession(socket: socket, connected: true)

# --- Sending events ---

proc sendEvent*(session: RealtimeSession, event: RealtimeClientEvent) =
  ## Send a client event to the realtime API.
  let jsonStr = toJson(event)
  waitFor session.socket.send(jsonStr)

# --- Receiving events ---

proc nextEvent*(session: RealtimeSession): Option[RealtimeServerEvent] =
  ## Receive the next server event from the realtime API.
  ## Returns none if the connection is closed.
  ## This call blocks until an event is available.
  while true:
    try:
      let packet = waitFor session.socket.receiveStrPacket()
      if packet.len == 0:
        continue
      let event = fromJson(packet, RealtimeServerEvent)
      return option(event)
    except WebSocketClosedError:
      session.connected = false
      return none(RealtimeServerEvent)

proc nextEventWithTimeout*(session: RealtimeSession, timeoutMs: int): Option[RealtimeServerEvent] =
  ## Receive the next server event, or return none if timeout expires.
  ## Useful when you need to interleave sending and receiving.
  ## Reuses a pending receive future across calls to avoid corrupting the stream.
  if session.pendingRecv.isNil:
    session.pendingRecv = session.socket.receiveStrPacket()
  try:
    # If the future already completed (e.g. during a send), read it immediately.
    if session.pendingRecv.finished:
      let packet = session.pendingRecv.read()
      session.pendingRecv = nil
      if packet.len == 0:
        return none(RealtimeServerEvent)
      return option(fromJson(packet, RealtimeServerEvent))
    # Otherwise wait with a timeout.
    if not waitFor withTimeout(session.pendingRecv, timeoutMs):
      return none(RealtimeServerEvent)
    let packet = session.pendingRecv.read()
    session.pendingRecv = nil
    if packet.len == 0:
      return none(RealtimeServerEvent)
    return option(fromJson(packet, RealtimeServerEvent))
  except WebSocketClosedError:
    session.connected = false
    session.pendingRecv = nil
    return none(RealtimeServerEvent)

# --- Convenience procs ---

proc updateSession*(session: RealtimeSession, config: RealtimeSessionConfig) =
  ## Send a session.update event to configure the session.
  let event = RealtimeClientEvent(
    `type`: "session.update",
    session: option(config),
  )
  session.sendEvent(event)

proc addItem*(session: RealtimeSession, item: RealtimeConversationItem) =
  ## Send a conversation.item.create event to add an item.
  let event = RealtimeClientEvent(
    `type`: "conversation.item.create",
    item: option(item),
  )
  session.sendEvent(event)

proc deleteItem*(session: RealtimeSession, itemId: string) =
  ## Send a conversation.item.delete event to remove an item.
  let event = RealtimeClientEvent(
    `type`: "conversation.item.delete",
    item_id: option(itemId),
  )
  session.sendEvent(event)

proc createResponse*(session: RealtimeSession, config: RealtimeResponseConfig = nil) =
  ## Send a response.create event to trigger model generation.
  var event = RealtimeClientEvent(`type`: "response.create")
  if config != nil:
    event.response = option(config)
  session.sendEvent(event)

proc cancelResponse*(session: RealtimeSession) =
  ## Send a response.cancel event to stop in-progress generation.
  let event = RealtimeClientEvent(`type`: "response.cancel")
  session.sendEvent(event)

proc appendAudio*(session: RealtimeSession, audioBase64: string) =
  ## Send an input_audio_buffer.append event with base64-encoded audio.
  let event = RealtimeClientEvent(
    `type`: "input_audio_buffer.append",
    audio: option(audioBase64),
  )
  session.sendEvent(event)

proc clearAudioBuffer*(session: RealtimeSession) =
  ## Send an input_audio_buffer.clear event.
  let event = RealtimeClientEvent(`type`: "input_audio_buffer.clear")
  session.sendEvent(event)

proc commitAudioBuffer*(session: RealtimeSession) =
  ## Send an input_audio_buffer.commit event.
  let event = RealtimeClientEvent(`type`: "input_audio_buffer.commit")
  session.sendEvent(event)

proc close*(session: RealtimeSession) =
  ## Close the realtime session WebSocket connection.
  session.socket.close()
  session.connected = false

# --- Item builders ---

proc newTextItem*(role: string, text: string): RealtimeConversationItem =
  ## Create a new text conversation item for the given role.
  ## Role should be "user" or "system". Content type is "input_text".
  let contentPart = RealtimeContentPart(
    `type`: "input_text",
    text: option(text),
  )
  result = RealtimeConversationItem(
    `type`: option("message"),
    role: option(role),
    content: option(@[contentPart]),
  )

proc newFunctionCallOutputItem*(callId: string, output: string): RealtimeConversationItem =
  ## Create a function_call_output conversation item.
  ## Used to send tool results back to the model.
  result = RealtimeConversationItem(
    `type`: option("function_call_output"),
    call_id: option(callId),
    output: option(output),
  )

# --- Tool support ---

proc updateSessionWithTools*(session: RealtimeSession, config: RealtimeSessionConfig, tools: ResponseToolsTable) =
  ## Send a session.update event that includes tools from a ResponseToolsTable.
  var toolSeq: seq[ResponseTool] = @[]
  for toolName, (toolFunc, toolImpl) in tools.pairs:
    toolSeq.add(ResponseTool(
      `type`: "function",
      name: toolName,
      description: toolFunc.description,
      parameters: toolFunc.parameters,
    ))
  config.tools = option(toolSeq)
  if config.tool_choice.isNone:
    config.tool_choice = option(%"auto")
  session.updateSession(config)

proc sendToolResult*(session: RealtimeSession, callId: string, output: string) =
  ## Send a function_call_output item and trigger a response continuation.
  session.addItem(newFunctionCallOutputItem(callId, output))
  session.createResponse()

type
  RealtimeToolCallback* = proc(name: string, args: JsonNode, result: string)

proc handleToolCalls*(
  session: RealtimeSession,
  tools: ResponseToolsTable,
  timeoutMs: int = 30000,
  callback: RealtimeToolCallback = nil,
): seq[RealtimeServerEvent] =
  ## Process events from the realtime session, automatically executing tool calls.
  ## Returns all collected events.
  ##
  ## When a function_call item is received, the tool is executed via the
  ## ResponseToolsTable and the result is sent back. After all tool calls in
  ## a response are handled, a new response.create is sent to continue.
  ## The loop exits when a response.done arrives with no tool calls,
  ## or on error/timeout.
  result = @[]
  var pendingToolCalls = 0

  while true:
    let eventOpt = session.nextEventWithTimeout(timeoutMs)
    if eventOpt.isNone:
      break
    let event = eventOpt.get
    result.add(event)

    case event.`type`
    of "response.output_item.done":
      if event.item.isSome and event.item.get.`type`.isSome and
         event.item.get.`type`.get == "function_call":
        let item = event.item.get
        if item.call_id.isSome and item.name.isSome and item.arguments.isSome:
          inc pendingToolCalls
          let callId = item.call_id.get
          let funcName = item.name.get
          let argsStr = item.arguments.get
          let toolResult = if tools.hasKey(funcName):
            let (_, toolImpl) = tools[funcName]
            let parsedArgs = parseJson(argsStr)
            let res = toolImpl(parsedArgs)
            if callback != nil:
              callback(funcName, parsedArgs, res)
            res
          else:
            var available: seq[string] = @[]
            for name in tools.keys:
              available.add(name)
            "Error: Tool '" & funcName & "' not found. Available: " & available.join(", ")
          session.addItem(newFunctionCallOutputItem(callId, toolResult))
    of "response.done":
      if pendingToolCalls > 0:
        session.createResponse()
        pendingToolCalls = 0
      else:
        break
    of "error":
      break
    else:
      discard

proc extractText*(events: seq[RealtimeServerEvent]): string =
  ## Extract all text deltas from a sequence of realtime events.
  result = ""
  for event in events:
    if event.`type` == "response.text.delta" and event.delta.isSome:
      result &= event.delta.get
