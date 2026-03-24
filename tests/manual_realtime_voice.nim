# Manual interactive voice test for the OpenAI Realtime API.
# Requires ALSA audio device (Linux).
# Run with: nix develop -c nim r -d:ssl --threads:on --path:../../nim-alsa/src tests/manual_realtime_voice.nim

# TODO this runs really, really poorly.
# interruptions are not working at all right now
# sometimes AI responses just drop out randomly?
# the realtime model is shockingly bad? why are we using gpt-4o-mini it's awful.
# the assitant reponse gets printed before the user's message gets printed?  the logs are confusing we log the user's message after assistant response.
# I think the assistant response lands before the user's initial message is asyncronously sent.


import
  std/[base64, json, options, osproc, strutils],
  openai_leap,
  alsa

const
  Model = "gpt-4o-mini-realtime-preview"
  SampleRate = 24000'u32
  Channels = 1'u32
  ChunkFrames = 4800'u64
  KernelBuffer = 19200'u64
  AlsaDevice = "default"

type
  CaptureArgs = object
    chan: ptr Channel[string]

var running = true

proc getDefaultAudioDevice(kind: string): string =
  ## Get the human-readable name of the default PulseAudio/PipeWire device.
  ## kind should be "source" (input) or "sink" (output).
  let (defaultName, rc) = execCmdEx("pactl get-default-" & kind)
  if rc != 0:
    return "unknown"
  let name = defaultName.strip()
  let (listing, rc2) = execCmdEx("pactl list " & kind & "s")
  if rc2 != 0:
    return name
  var inTarget = false
  for line in listing.splitLines():
    let stripped = line.strip()
    if stripped.startsWith("Name: ") and stripped.endsWith(name):
      inTarget = true
    elif stripped.startsWith("Name: "):
      inTarget = false
    elif inTarget and stripped.startsWith("Description: "):
      return stripped[len("Description: ")..^1]
  return name

proc openAlsaDevice(stream: streamModes): snd_pcm_ref =
  ## Open and configure an ALSA PCM device for 24kHz 16-bit mono.
  var
    handle: snd_pcm_ref
    hwParams: snd_pcm_hw_params_ref
  if snd_pcm_open_nim(addr handle, AlsaDevice, stream, BLOCKING_MODE) < 0:
    raise newException(IOError, "Failed to open ALSA device: " & AlsaDevice)
  if snd_pcm_hw_params_malloc_nim(addr hwParams) < 0:
    raise newException(IOError, "Failed to allocate hw params")
  discard snd_pcm_hw_params_any_nim(handle, hwParams)
  discard snd_pcm_hw_params_set_access_nim(handle, hwParams, SND_PCM_ACCESS_RW_INTERLEAVED)
  discard snd_pcm_hw_params_set_format_nim(handle, hwParams, SND_PCM_FORMAT_S16_LE)
  discard snd_pcm_hw_params_set_channels_nim(handle, hwParams, Channels)
  discard snd_pcm_hw_params_set_rate_nim(handle, hwParams, SampleRate, 0)
  discard snd_pcm_hw_params_set_buffer_size_nim(handle, hwParams, KernelBuffer)
  if snd_pcm_hw_params_nim(handle, hwParams) < 0:
    raise newException(IOError, "Failed to set ALSA hw params")
  snd_pcm_hw_params_free_nim(hwParams)
  return handle

proc captureThread(args: CaptureArgs) {.thread.} =
  ## Continuously capture audio from microphone and send to channel.
  let capture = openAlsaDevice(SND_PCM_STREAM_CAPTURE)
  var buf: array[ChunkFrames, int16]
  while running:
    let frames = snd_pcm_readi_nim(capture, addr buf[0], ChunkFrames)
    if frames < 0:
      discard snd_pcm_prepare_nim(capture)
      continue
    if frames > 0:
      let byteLen = frames * sizeof(int16)
      let raw = cast[ptr UncheckedArray[byte]](addr buf[0])
      var str = newString(byteLen)
      copyMem(addr str[0], raw, byteLen)
      let encoded = base64.encode(str)
      args.chan[].send(encoded)
  discard snd_pcm_close_nim(capture)

proc main() =
  ## Run an interactive voice chat over the Realtime API.
  let openai = newOpenAiApi()
  echo "Connecting to Realtime API..."
  let session = openai.connectRealtime(Model)

  let created = session.nextEvent()
  if created.isNone or created.get.`type` != "session.created":
    echo "ERROR: did not receive session.created"
    session.close()
    openai.close()
    return
  echo "Session created."

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
  session.updateSession(config)

  let updated = session.nextEvent()
  if updated.isSome and updated.get.`type` == "session.updated":
    echo "Session configured for voice (PCM16 24kHz mono, server VAD)."
  echo ""
  echo "Speak into your microphone. The assistant will respond with audio."
  echo "Use headphones for best interruption support (avoids echo feedback)."
  echo "Press Ctrl+C to exit."
  echo "---"

  let playback = openAlsaDevice(SND_PCM_STREAM_PLAYBACK)
  echo "Audio input: " & getDefaultAudioDevice("source")
  echo "Audio output: " & getDefaultAudioDevice("sink")

  # Channel for passing audio data from capture thread to main thread.
  var audioChan: Channel[string]
  audioChan.open()

  var capThread: Thread[CaptureArgs]
  createThread(capThread, captureThread, CaptureArgs(chan: addr audioChan))

  var
    pendingUserTranscript = ""
    inAssistantResponse = false
    audioEventsReceived = 0
    eventsReceived = 0

  while running:
    # Drain any queued audio chunks and send them over the WebSocket.
    while true:
      let tried = audioChan.tryRecv()
      if not tried.dataAvailable:
        break
      session.appendAudio(tried.msg)

    # Receive the next event with a short timeout so we can loop back to send audio.
    let event = session.nextEventWithTimeout(50)
    if event.isNone:
      if not session.connected:
        echo "\n[connection closed]"
        break
      continue
    inc eventsReceived
    case event.get.`type`
    of "input_audio_buffer.speech_started":
      if inAssistantResponse:
        echo ""
        inAssistantResponse = false
      # Stop any audio still playing from a previous response.
      discard snd_pcm_drop_nim(playback)
      discard snd_pcm_prepare_nim(playback)
      echo "[listening...]"
    of "input_audio_buffer.speech_stopped":
      echo "[processing...]"
    of "response.audio.delta":
      if event.get.delta.isSome:
        let decoded = base64.decode(event.get.delta.get)
        let frames = decoded.len div sizeof(int16)
        if frames > 0:
          let written = snd_pcm_writei_nim(playback, unsafeAddr decoded[0], frames.culong)
          if written < 0:
            discard snd_pcm_prepare_nim(playback)
            discard snd_pcm_writei_nim(playback, unsafeAddr decoded[0], frames.culong)
          inc audioEventsReceived
    of "response.audio.done":
      stderr.writeLine "[debug] audio playback events: " & $audioEventsReceived
      audioEventsReceived = 0
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
      # Don't print yet — wait until after the assistant response finishes.
    of "response.done":
      # Print the buffered user transcript before the response summary.
      if pendingUserTranscript.len > 0:
        echo "You: " & pendingUserTranscript
        pendingUserTranscript = ""
      stderr.writeLine "[debug] response complete (total events received: " & $eventsReceived & ")"
    of "error":
      if event.get.error.isSome:
        echo "[error] " & event.get.error.get.message
    of "input_audio_buffer.committed",
       "conversation.item.created",
       "response.created",
       "response.output_item.added",
       "response.output_item.done",
       "response.content_part.added",
       "response.content_part.done",
       "rate_limits.updated":
      discard
    else:
      stderr.writeLine "[debug] unhandled event: " & event.get.`type`

  running = false
  joinThread(capThread)
  audioChan.close()
  discard snd_pcm_close_nim(playback)
  session.close()
  openai.close()
  echo "Bye."

main()
