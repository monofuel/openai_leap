# Test the OpenAI Realtime API (WebSocket)
import openai_leap, std/[json, tables, unittest, options, strutils]

proc getFlightTimes(departure: string, arrival: string): string =
  var flights = initTable[string, JsonNode]()
  flights["JFK-LAX"] = %* {"departure": "08:00 AM", "arrival": "11:30 AM", "duration": "5h 30m"}
  flights["LAX-JFK"] = %* {"departure": "02:00 PM", "arrival": "10:30 PM", "duration": "5h 30m"}
  flights["LHR-JFK"] = %* {"departure": "10:00 AM", "arrival": "01:00 PM", "duration": "8h 00m"}
  flights["JFK-LHR"] = %* {"departure": "09:00 PM", "arrival": "09:00 AM", "duration": "7h 00m"}
  flights["CDG-DXB"] = %* {"departure": "11:00 AM", "arrival": "08:00 PM", "duration": "6h 00m"}
  flights["DXB-CDG"] = %* {"departure": "03:00 AM", "arrival": "07:30 AM", "duration": "7h 30m"}
  let key = (departure & "-" & arrival).toUpperAscii()
  if flights.contains(key):
    return $flights[key]
  else:
    return "No flight found for " & key

const
  TestModel = "gpt-4o-mini-realtime-preview"

suite "realtime":
  var openai: OpenAiApi

  setup:
    openai = newOpenAiApi()
  teardown:
    openai.close()

  test "connect and receive session.created":
    let session = openai.connectRealtime(TestModel)
    let event = session.nextEvent()
    check event.isSome
    check event.get.`type` == "session.created"
    check event.get.session.isSome
    session.close()

  test "update session config":
    let session = openai.connectRealtime(TestModel)
    discard session.nextEvent() # session.created

    let config = RealtimeSessionConfig()
    config.modalities = option(@["text"])
    config.instructions = option("You are a helpful assistant. Keep responses brief.")
    session.updateSession(config)

    let event = session.nextEvent()
    check event.isSome
    check event.get.`type` == "session.updated"
    session.close()

  test "text conversation round trip":
    let session = openai.connectRealtime(TestModel)
    discard session.nextEvent() # session.created

    let config = RealtimeSessionConfig()
    config.modalities = option(@["text"])
    session.updateSession(config)
    discard session.nextEvent() # session.updated

    session.addItem(newTextItem("user", "Say hello in exactly one word."))
    session.createResponse()

    var gotTextDelta = false
    var gotResponseDone = false
    var fullText = ""
    while not gotResponseDone:
      let event = session.nextEvent()
      if event.isNone:
        break
      case event.get.`type`
      of "response.text.delta":
        gotTextDelta = true
        if event.get.delta.isSome:
          fullText &= event.get.delta.get
      of "response.done":
        gotResponseDone = true
      else:
        discard

    check gotTextDelta
    check gotResponseDone
    check fullText.len > 0
    session.close()

  test "configure audio session with server VAD":
    let session = openai.connectRealtime(TestModel)
    discard session.nextEvent() # session.created

    let config = RealtimeSessionConfig()
    config.modalities = option(@["text", "audio"])
    config.voice = option("alloy")
    config.input_audio_format = option("pcm16")
    config.output_audio_format = option("pcm16")
    config.input_audio_transcription = option(RealtimeTranscriptionConfig(
      model: option("whisper-1"),
    ))
    config.turn_detection = option(%*{
      "type": "server_vad",
      "threshold": 0.5,
      "silence_duration_ms": 500,
    })
    session.updateSession(config)

    let event = session.nextEvent()
    check event.isSome
    check event.get.`type` == "session.updated"
    session.close()

  test "tool calling with automated handling":
    let session = openai.connectRealtime(TestModel)
    discard session.nextEvent() # session.created

    let config = RealtimeSessionConfig()
    config.modalities = option(@["text"])

    var tools = newResponseToolsTable()
    tools.register("get_flight_times",
      ToolFunction(
        name: "get_flight_times",
        description: option("Get flight times between two cities"),
        parameters: option(%*{
          "type": "object",
          "properties": {
            "departure": {"type": "string", "description": "Departure airport code"},
            "arrival": {"type": "string", "description": "Arrival airport code"}
          },
          "required": ["departure", "arrival"]
        })
      ),
      proc(args: JsonNode): string =
        return getFlightTimes(args["departure"].getStr(), args["arrival"].getStr())
    )

    session.updateSessionWithTools(config, tools)
    discard session.nextEvent() # session.updated

    session.addItem(newTextItem("user", "What is the flight time from JFK to LAX?"))
    session.createResponse()

    var toolWasCalled = false
    let events = session.handleToolCalls(tools, timeoutMs = 30000,
      callback = proc(name: string, args: JsonNode, result: string) =
        toolWasCalled = true
        check name == "get_flight_times"
    )

    check toolWasCalled
    let text = extractText(events)
    check text.len > 0
    check "5h 30m" in text or "5 hours" in text.toLowerAscii() or "30" in text
    session.close()

  test "manual tool call flow":
    let session = openai.connectRealtime(TestModel)
    discard session.nextEvent() # session.created

    let config = RealtimeSessionConfig()
    config.modalities = option(@["text"])
    config.tools = option(@[ResponseTool(
      `type`: "function",
      name: "get_greeting",
      description: option("Get a greeting for a person by name"),
      parameters: option(%*{
        "type": "object",
        "properties": {
          "name": {"type": "string", "description": "The person's name"}
        },
        "required": ["name"]
      })
    )])
    config.tool_choice = option(%"auto")
    session.updateSession(config)
    discard session.nextEvent() # session.updated

    session.addItem(newTextItem("user", "Greet Alice using the get_greeting tool."))
    session.createResponse()

    var functionCallItem: RealtimeConversationItem
    var gotFunctionCall = false
    while true:
      let event = session.nextEventWithTimeout(15000)
      if event.isNone:
        break
      if event.get.`type` == "response.output_item.done":
        if event.get.item.isSome and event.get.item.get.`type`.isSome and
           event.get.item.get.`type`.get == "function_call":
          functionCallItem = event.get.item.get
          gotFunctionCall = true
      if event.get.`type` == "response.done":
        break

    check gotFunctionCall
    check functionCallItem.call_id.isSome
    check functionCallItem.name.isSome
    check functionCallItem.name.get == "get_greeting"
    check functionCallItem.arguments.isSome
    check "Alice" in functionCallItem.arguments.get

    session.sendToolResult(functionCallItem.call_id.get, "Hello, Alice! Welcome!")

    var gotFinalText = false
    while true:
      let event = session.nextEventWithTimeout(15000)
      if event.isNone:
        break
      if event.get.`type` == "response.text.delta":
        gotFinalText = true
      if event.get.`type` == "response.done":
        break

    check gotFinalText
    session.close()
