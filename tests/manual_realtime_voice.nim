# Manual interactive voice test for the OpenAI Realtime API.
# Requires OpenAL audio device (via slappy).
# Run with: nix develop -c nim r tests/manual_realtime_voice.nim

import
  std/[base64, json, monotimes, options, os, posix, strutils, tables, times],
  openai_leap,
  slappy,
  slappy/wav,
  ./realtime_voice_config

const
  Channels = 1
  Bits = 16

var running {.volatile.} = true

proc stopRunning() {.noconv.} =
  ## Request shutdown without doing audio or network work in the signal handler.
  running = false

proc requireEvent(session: RealtimeSession, kind: string, timeoutMs: int): RealtimeServerEvent =
  ## Wait for a required setup event and surface server errors before opening audio devices.
  let event = session.nextEventWithTimeout(timeoutMs)
  if event.isNone:
    raise newException(IOError, "Timed out or disconnected waiting for " & kind)
  if event.get.`type` == "error":
    raise newException(IOError, event.get.error.get.message)
  if event.get.`type` != kind:
    raise newException(IOError, "Expected " & kind & ", received " & event.get.`type`)
  result = event.get

proc pollCommand(): Option[string] =
  ## Read an Enter-terminated console command without blocking audio or WebSocket processing.
  var descriptor = TPollfd(fd: cint(getFileHandle(stdin)), events: POLLIN)
  if posix.poll(addr descriptor, 1, 0) > 0:
    var line: string
    if stdin.readLine(line):
      return option(line.strip().toLowerAscii())
    return option("q")

proc runFileTurn(session: RealtimeSession, settings: VoiceSettings) =
  ## Exercise the same explicit audio-turn protocol without opening microphone or playback devices.
  let audio = loadWav(settings.inputWav)
  if audio.channels != 1 or audio.bits != 16 or audio.freq != settings.inputRate:
    raise newException(ValueError, "Input WAV must be mono PCM16 at REALTIME_INPUT_RATE")
  let chunkBytes = settings.inputRate * settings.chunkMs div 1000 * 2
  var offset = 0
  while offset < audio.data.len:
    let stop = min(offset + chunkBytes, audio.data.len)
    session.appendAudio(base64.encode(audio.data[offset ..< stop]))
    offset = stop
  session.commitAudioBuffer()
  session.createResponse()
  var pcm = ""
  let started = getMonoTime()
  while running:
    let elapsed = (getMonoTime() - started).inMilliseconds
    if elapsed >= settings.timeoutMs:
      raise newException(IOError, "Timed out waiting for the recorded voice reply")
    let event = session.nextEventWithTimeout(min(100, settings.timeoutMs - elapsed.int))
    if event.isNone:
      if not session.connected:
        raise newException(IOError, "Connection closed during the recorded voice reply")
      continue
    case event.get.`type`
    of "response.output_audio.delta": pcm.add base64.decode(event.get.delta.get)
    of "response.output_audio_transcript.delta", "response.output_text.delta":
      stdout.write event.get.delta.get
    of "error": raise newException(IOError, event.get.error.get.message)
    of "response.done":
      if event.get.response.isNone or event.get.response.get.status.get("") != "completed" or pcm.len == 0:
        raise newException(IOError, "Recorded turn did not complete with speech audio")
      writeFile(settings.outputPcm, pcm)
      echo "\nSaved spoken reply to ", settings.outputPcm, " (mono PCM16, ", settings.outputRate, " Hz)."
      return
    else: discard

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
  if "--help" in commandLineParams():
    echo VoiceHelp
    return
  let settings = loadVoiceSettings(commandLineParams())
  setControlCHook(stopRunning)
  let openai = newOpenAiApi(baseUrl = settings.baseUrl)
  defer: openai.close()
  echo "Connecting to ", settings.baseUrl, " (", settings.model, ", voice ", settings.voice, ")..."
  let session = openai.connectRealtime(settings.model)
  defer: session.close()
  discard requireEvent(session, "session.created", settings.timeoutMs)
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

  let config = settings.sessionConfig()
  if settings.toolsEnabled:
    session.updateSessionWithTools(config, tools)
  else:
    session.updateSession(config)
  let updated = requireEvent(session, "session.updated", settings.timeoutMs)
  if updated.session.isSome:
    settings.verifySession(updated.session.get)
  if settings.inputWav.len > 0:
    runFileTurn(session, settings)
    return
  slappyInit()
  defer: slappyClose()
  let mic = newMicrophone(deviceName = settings.inputDevice, frequency = settings.inputRate,
    channels = Channels, bits = Bits, bufferSize = settings.inputRate * 10)
  var recording = not settings.lfm
  defer:
    if recording: mic.stop()
    mic.close()
  if recording: mic.start()
  let playback = newStreamingSource(frequency = settings.outputRate, channels = Channels, bits = Bits)
  defer: playback.close()
  let chunkSamples = settings.inputRate * settings.chunkMs div 1000
  echo ""
  if settings.lfm:
    echo "Press Enter to start recording, then Enter again to send your turn."
    echo "Press Enter during a reply to interrupt and start a new turn."
  else:
    echo "Speak into your microphone; server VAD detects your turns."
  if settings.toolsEnabled:
    echo "Try asking about flights: JFK-LAX, LAX-JFK, LHR-JFK, JFK-LHR, CDG-DXB, DXB-CDG"
  echo "Use headphones for best interruption support (avoids echo feedback)."
  echo "Type q and Enter, or press Ctrl+C, to exit."
  echo "---"

  var
    pendingUserTranscript = ""
    inAssistantResponse = false
    eventsReceived = 0
    pendingToolCalls = 0
    responseActive = false
    turnBytes = 0

  while running:
    let command = pollCommand()
    if command.isSome:
      if command.get == "q":
        break
      if command.get.len == 0 and settings.lfm:
        if recording:
          mic.stop()
          recording = false
          let remaining = mic.readAll()
          if remaining.len > 0:
            session.appendAudio(base64.encode(remaining))
            turnBytes += remaining.len
          if turnBytes > 0:
            session.commitAudioBuffer()
            session.createResponse()
            responseActive = true
            echo "[processing...]"
          else:
            echo "[no audio recorded; press Enter to try again]"
        else:
          if responseActive: session.cancelResponse()
          playback.flush()
          if inAssistantResponse:
            echo ""
            inAssistantResponse = false
          discard mic.readAll()
          turnBytes = 0
          mic.start()
          recording = true
          echo "[recording; press Enter to send]"
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
      of "response.output_audio.delta":
        if event.get.delta.isSome and not (settings.lfm and recording):
          let decoded = base64.decode(event.get.delta.get)
          if decoded.len > 0:
            var pcmBytes = newSeq[uint8](decoded.len)
            copyMem(addr pcmBytes[0], unsafeAddr decoded[0], decoded.len)
            playback.queueData(pcmBytes)
      of "response.output_audio.done":
        discard
      of "response.output_audio_transcript.delta", "response.output_text.delta":
        if event.get.delta.isSome and not (settings.lfm and recording):
          if not inAssistantResponse:
            stdout.write "Assistant: "
            inAssistantResponse = true
          stdout.write(event.get.delta.get)
          stdout.flushFile()
      of "response.output_audio_transcript.done", "response.output_text.done":
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
        responseActive = false
        if pendingToolCalls > 0:
          session.createResponse()
          responseActive = true
          pendingToolCalls = 0
        if pendingUserTranscript.len > 0:
          echo "You: " & pendingUserTranscript
          pendingUserTranscript = ""
      of "error":
        if event.get.error.isSome:
          raise newException(IOError, event.get.error.get.message)
      of "response.created":
        responseActive = true
      of "input_audio_buffer.committed",
         "conversation.item.created",
         "conversation.item.added",
         "conversation.item.done",
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
    if recording:
      while mic.samplesAvailable() >= chunkSamples:
        let data = mic.read(chunkSamples)
        session.appendAudio(base64.encode(data))
        turnBytes += data.len

    # Reclaim processed audio buffers.
    playback.pump()

  echo "Bye."

when isMainModule:
  main()
