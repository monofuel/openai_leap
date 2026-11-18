import
  std/[json, options, os, strutils, uri],
  openai_leap

type VoiceSettings* = object
  baseUrl*, model*, voice*, instructions*, inputDevice*: string
  transcriptionModel*, inputWav*, outputPcm*: string
  inputRate*, outputRate*, chunkMs*, timeoutMs*: int
  toolsEnabled*, lfm*: bool
  outputModalities*: seq[string]

const VoiceHelp* = """
Interactive Realtime voice test (Slappy microphone and playback).
Default: GPT Realtime with continuous microphone capture, server VAD and interruptions.
--lfm: LFM3 voice-chat defaults and explicit turns; requires OPENAI_BASE_URL.
With --lfm: Enter starts recording, Enter sends, q quits.
Enter during a reply cancels generation and clears queued playback in LFM3 mode.

Environment:
  OPENAI_BASE_URL                API base including /v1 (default https://api.openai.com/v1)
  OPENAI_API_KEY                 API key; use a dummy value for an unauthenticated local server
  REALTIME_MODEL                default gpt-realtime-2; --lfm: lfm3-audio-2b
  REALTIME_VOICE                default alloy; --lfm: female (also accepts male)
  REALTIME_INPUT_RATE           mono PCM16 capture rate (default 24000; --lfm: 16000)
  REALTIME_OUTPUT_RATE          mono PCM16 playback rate (default 24000)
  REALTIME_OUTPUT_MODALITIES    default audio; --lfm: text,audio
  REALTIME_CHUNK_MS             capture chunk duration (default 200)
  REALTIME_INPUT_DEVICE         OpenAL capture device name (default system microphone)
  REALTIME_INSTRUCTIONS         optional; --lfm: Respond with interleaved text and audio.
  REALTIME_TOOLS                enable the example flight tools (default true; --lfm: false)
  REALTIME_TRANSCRIPTION_MODEL  default whisper-1; --lfm: disabled (empty)
  REALTIME_TIMEOUT_SECONDS      connection/session/file-response wait (default 600)
  REALTIME_INPUT_WAV            optional mono PCM16 file instead of interactive audio devices (--lfm only)
  REALTIME_OUTPUT_PCM           file-mode reply destination (default temporary openai-leap-response.pcm)

Run with --help to display these options without connecting or opening audio devices.
"""

proc envInt(name: string, fallback, minimum, maximum: int): int =
  ## Read and validate a numeric environment setting.
  result = parseInt(getEnv(name, $fallback))
  if result < minimum or result > maximum:
    raise newException(ValueError, name & " must be between " & $minimum & " and " & $maximum)

proc loadVoiceSettings*(args: seq[string] = @[]): VoiceSettings =
  ## Read environment overrides; only --lfm enables LFM3 defaults and explicit turn handling.
  for arg in args:
    if arg != "--lfm":
      raise newException(ValueError, "Unknown argument: " & arg & "; use --help for usage")
    result.lfm = true
  if result.lfm and getEnv("OPENAI_BASE_URL").strip().len == 0:
    raise newException(ValueError, "--lfm requires OPENAI_BASE_URL pointing to the LFM3 API including /v1")
  result.baseUrl = getEnv("OPENAI_BASE_URL", "https://api.openai.com/v1").strip()
  while result.baseUrl.endsWith("/"):
    result.baseUrl.setLen(result.baseUrl.len - 1)
  let address = parseUri(result.baseUrl)
  if address.scheme notin ["http", "https"] or address.hostname.len == 0:
    raise newException(ValueError, "OPENAI_BASE_URL must be an HTTP(S) API base URL including its API path")
  result.model = getEnv("REALTIME_MODEL", if result.lfm: "lfm3-audio-2b" else: "gpt-realtime-2")
  result.voice = getEnv("REALTIME_VOICE", if result.lfm: "female" else: "alloy")
  result.inputRate = envInt("REALTIME_INPUT_RATE", if result.lfm: 16000 else: 24000, 8000, 192000)
  result.outputRate = envInt("REALTIME_OUTPUT_RATE", 24000, 8000, 192000)
  result.outputModalities = getEnv("REALTIME_OUTPUT_MODALITIES", if result.lfm: "text,audio" else: "audio").split(',')
  if result.outputModalities notin [@["audio"], @["text", "audio"]]:
    raise newException(ValueError, "REALTIME_OUTPUT_MODALITIES must be audio or text,audio")
  result.chunkMs = envInt("REALTIME_CHUNK_MS", 200, 1, 1000)
  result.timeoutMs = envInt("REALTIME_TIMEOUT_SECONDS", 600, 1, 86400) * 1000
  result.inputDevice = getEnv("REALTIME_INPUT_DEVICE")
  result.instructions = getEnv("REALTIME_INSTRUCTIONS", if result.lfm: "Respond with interleaved text and audio." else: "")
  result.toolsEnabled = parseBool(getEnv("REALTIME_TOOLS", if result.lfm: "false" else: "true"))
  result.transcriptionModel = getEnv("REALTIME_TRANSCRIPTION_MODEL",
    if result.lfm: "" else: "whisper-1")
  result.inputWav = getEnv("REALTIME_INPUT_WAV")
  result.outputPcm = getEnv("REALTIME_OUTPUT_PCM", getTempDir() / "openai-leap-response.pcm")
  if result.model.len == 0 or result.voice.len == 0:
    raise newException(ValueError, "REALTIME_MODEL and REALTIME_VOICE must not be empty")
  if result.inputWav.len > 0 and not result.lfm:
    raise newException(ValueError, "REALTIME_INPUT_WAV requires --lfm")

proc sessionConfig*(settings: VoiceSettings): RealtimeSessionConfig =
  ## Build the voice session with server VAD by default and explicit turns only for --lfm.
  let input = RealtimeAudioInputConfig(
    format: option(%*{"type": "audio/pcm", "rate": settings.inputRate}),
    turn_detection: option(if settings.lfm: newJNull() else:
      %*{"type": "server_vad", "threshold": 0.3, "silence_duration_ms": 500, "prefix_padding_ms": 300}))
  if settings.transcriptionModel.len > 0:
    input.transcription = option(RealtimeTranscriptionConfig(model: option(settings.transcriptionModel)))
  result = RealtimeSessionConfig(
    output_modalities: option(settings.outputModalities),
    audio: option(RealtimeAudioConfig(input: option(input), output: option(RealtimeAudioOutputConfig(
      format: option(%*{"type": "audio/pcm", "rate": settings.outputRate}),
      voice: option(settings.voice))))))
  if settings.instructions.len > 0:
    result.instructions = option(settings.instructions)

proc verifySession*(settings: VoiceSettings, config: RealtimeSessionConfig) =
  ## Reject unsupported turn detection or negotiated sample rates before opening audio devices.
  if config.isNil or config.audio.isNone:
    return
  let audio = config.audio.get
  if audio.input.isSome:
    let input = audio.input.get
    if input.format.isSome and input.format.get.kind == JObject and input.format.get.hasKey("rate"):
      if input.format.get["rate"].getInt != settings.inputRate:
        raise newException(ValueError, "Server input rate differs from REALTIME_INPUT_RATE")
    let detection = input.turn_detection
    if not settings.lfm and (detection.isNone or detection.get.kind == JNull):
      raise newException(ValueError, "Server does not enable server VAD; use --lfm for the LFM3 server")
    if settings.lfm and detection.isSome and detection.get.kind != JNull:
      raise newException(ValueError, "Server kept turn detection enabled for a manual session")
  if audio.output.isSome:
    let format = audio.output.get.format
    if format.isSome and format.get.kind == JObject and format.get.hasKey("rate"):
      if format.get["rate"].getInt != settings.outputRate:
        raise newException(ValueError, "Server output rate differs from REALTIME_OUTPUT_RATE")
