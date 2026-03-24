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
  RealtimeSessionConfig* = ref object
    ## Configuration for a realtime session.
    model*: Option[string]
    instructions*: Option[string]
    modalities*: Option[seq[string]]
    temperature*: Option[float32]
    max_response_output_tokens*: Option[JsonNode]
    # NOT YET IMPLEMENTED: voice, input_audio_format, output_audio_format,
    # input_audio_transcription, turn_detection, tools, tool_choice, speed

  RealtimeContentPart* = ref object
    ## A content part within a realtime conversation item.
    `type`*: string
    text*: Option[string]
    # NOT YET IMPLEMENTED: audio, transcript, image_url

  RealtimeConversationItem* = ref object
    ## A conversation item in the realtime session.
    id*: Option[string]
    `type`*: Option[string]
    `object`*: Option[string]
    status*: Option[string]
    role*: Option[string]
    content*: Option[seq[RealtimeContentPart]]
    # NOT YET IMPLEMENTED: call_id, name, arguments, output (for function_call items)

  RealtimeResponseConfig* = ref object
    ## Configuration for triggering a response.
    modalities*: Option[seq[string]]
    instructions*: Option[string]
    temperature*: Option[float32]
    max_output_tokens*: Option[JsonNode]
    # NOT YET IMPLEMENTED: voice, tools, tool_choice, conversation, input

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
    # NOT YET IMPLEMENTED: input_audio_buffer.append (delta field), input_audio_buffer.clear, input_audio_buffer.commit

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

  RealtimeSession* = ref object
    ## An active realtime session wrapping a WebSocket connection.
    socket*: WebSocket
    connected*: bool

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
  try:
    let packet = waitFor session.socket.receiveStrPacket()
    let event = fromJson(packet, RealtimeServerEvent)
    return option(event)
  except WebSocketClosedError:
    session.connected = false
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
