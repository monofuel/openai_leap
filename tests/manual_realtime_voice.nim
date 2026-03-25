# Manual interactive voice test for the OpenAI Realtime API.
# Requires OpenAL audio device (via slappy).
# Run with: nix develop -c nim r -d:ssl --threads:on tests/manual_realtime_voice.nim

import
  std/[base64, json, options, strutils, tables],
  openai_leap,
  slappy

const
  Model = "gpt-realtime"
  SampleRate = 24000
  Channels = 1
  Bits = 16
  ChunkSamples = 4800 # 200ms at 24kHz

var running = true

proc getFlightTimes(departure: string, arrival: string): string =
  ## Look up flight times between two airport codes.
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

proc main() =
  ## Run an interactive voice chat over the Realtime API.
  slappyInit()

  let mic = newMicrophone(frequency = SampleRate, channels = Channels, bits = Bits)
  mic.start()

  let playback = newStreamingSource(frequency = SampleRate, channels = Channels, bits = Bits)

  let openai = newOpenAiApi()
  echo "Connecting to Realtime API..."
  let session = openai.connectRealtime(Model)

  let created = session.nextEvent()
  if created.isNone or created.get.`type` != "session.created":
    echo "ERROR: did not receive session.created"
    mic.stop()
    mic.close()
    playback.close()
    session.close()
    openai.close()
    slappyClose()
    return
  echo "Session created."

  var tools = newResponseToolsTable()
  tools.register("get_flight_times",
    ToolFunction(
      name: "get_flight_times",
      description: option("Get flight times between two cities. Available routes: JFK-LAX, LAX-JFK, LHR-JFK, JFK-LHR, CDG-DXB, DXB-CDG."),
      parameters: option(%*{
        "type": "object",
        "properties": {
          "departure": {"type": "string", "description": "Departure airport code (e.g. JFK, LAX, LHR, CDG, DXB)"},
          "arrival": {"type": "string", "description": "Arrival airport code (e.g. JFK, LAX, LHR, CDG, DXB)"}
        },
        "required": ["departure", "arrival"]
      })
    ),
    proc(args: JsonNode): string =
      return getFlightTimes(args["departure"].getStr(), args["arrival"].getStr())
  )

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
    "threshold": 0.3,
    "silence_duration_ms": 500,
    "prefix_padding_ms": 300,
  })
  session.updateSessionWithTools(config, tools)

  let updated = session.nextEvent()
  if updated.isSome and updated.get.`type` == "session.updated":
    echo "Session configured for voice (PCM16 24kHz mono, server VAD)."
  echo ""
  echo "Speak into your microphone. The assistant will respond with audio."
  echo "Try asking about flights: JFK-LAX, LAX-JFK, LHR-JFK, JFK-LHR, CDG-DXB, DXB-CDG"
  echo "Use headphones for best interruption support (avoids echo feedback)."
  echo "Press Ctrl+C to exit."
  echo "---"

  var
    pendingUserTranscript = ""
    inAssistantResponse = false
    eventsReceived = 0
    pendingToolCalls = 0

  while running:
    # PHASE 1: Process all available WebSocket events.
    var eventsThisRound = 0
    while true:
      let timeoutMs = if eventsThisRound == 0: 10 else: 0
      let event = session.nextEventWithTimeout(timeoutMs)
      if event.isNone:
        if not session.connected:
          echo "\n[connection closed]"
          running = false
        break
      inc eventsThisRound
      inc eventsReceived

      case event.get.`type`
      of "input_audio_buffer.speech_started":
        if inAssistantResponse:
          echo ""
          inAssistantResponse = false
        # Flush queued playback on interruption.
        playback.flush()
        echo "[listening...]"
      of "input_audio_buffer.speech_stopped":
        echo "[processing...]"
      of "response.audio.delta":
        if event.get.delta.isSome:
          let decoded = base64.decode(event.get.delta.get)
          if decoded.len > 0:
            var pcmBytes = newSeq[uint8](decoded.len)
            copyMem(addr pcmBytes[0], unsafeAddr decoded[0], decoded.len)
            playback.queueData(pcmBytes)
      of "response.audio.done":
        discard
      of "response.audio_transcript.delta":
        if event.get.delta.isSome:
          if not inAssistantResponse:
            stdout.write "Assistant: "
            inAssistantResponse = true
          stdout.write(event.get.delta.get)
          stdout.flushFile()
      of "response.audio_transcript.done":
        if inAssistantResponse:
          echo ""
          inAssistantResponse = false
      of "conversation.item.input_audio_transcription.delta":
        if event.get.delta.isSome:
          pendingUserTranscript &= event.get.delta.get
      of "conversation.item.input_audio_transcription.completed":
        if event.get.transcript.isSome:
          pendingUserTranscript = event.get.transcript.get
      of "response.output_item.done":
        if event.get.item.isSome and event.get.item.get.`type`.isSome and
           event.get.item.get.`type`.get == "function_call":
          let item = event.get.item.get
          if item.call_id.isSome and item.name.isSome and item.arguments.isSome:
            let funcName = item.name.get
            let argsStr = item.arguments.get
            let callId = item.call_id.get
            echo "[tool call] " & funcName & "(" & argsStr & ")"
            let toolResult = if tools.hasKey(funcName):
              let (_, toolImpl) = tools[funcName]
              toolImpl(parseJson(argsStr))
            else:
              "Error: Tool '" & funcName & "' not found"
            echo "[tool result] " & toolResult
            session.addItem(newFunctionCallOutputItem(callId, toolResult))
            inc pendingToolCalls
      of "response.done":
        if pendingToolCalls > 0:
          session.createResponse()
          pendingToolCalls = 0
        if pendingUserTranscript.len > 0:
          echo "You: " & pendingUserTranscript
          pendingUserTranscript = ""
      of "error":
        if event.get.error.isSome:
          echo "[error] " & event.get.error.get.message
      of "input_audio_buffer.committed",
         "conversation.item.created",
         "response.created",
         "response.output_item.added",
         "response.function_call_arguments.delta",
         "response.function_call_arguments.done",
         "response.content_part.added",
         "response.content_part.done",
         "rate_limits.updated":
        discard
      else:
        stderr.writeLine "[debug] unhandled event: " & event.get.`type`

    # PHASE 2: Poll microphone and send captured audio.
    let available = mic.samplesAvailable()
    if available >= ChunkSamples:
      let data = mic.read(ChunkSamples)
      let encoded = base64.encode(data)
      session.appendAudio(encoded)

    # Reclaim processed audio buffers.
    playback.pump()

  mic.stop()
  mic.close()
  playback.close()
  session.close()
  openai.close()
  slappyClose()
  echo "Bye."

main()
