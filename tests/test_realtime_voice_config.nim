import
  std/[json, options, os, tables, unittest],
  ./realtime_voice_config

const EnvNames = ["OPENAI_BASE_URL", "REALTIME_MODEL", "REALTIME_VOICE",
  "REALTIME_TURN_MODE", "REALTIME_INPUT_RATE", "REALTIME_OUTPUT_RATE",
  "REALTIME_CHUNK_MS", "REALTIME_TIMEOUT_SECONDS", "REALTIME_INPUT_DEVICE",
  "REALTIME_INSTRUCTIONS", "REALTIME_TOOLS", "REALTIME_TRANSCRIPTION_MODEL",
  "REALTIME_INPUT_WAV", "REALTIME_OUTPUT_PCM", "REALTIME_OUTPUT_MODALITIES"]

suite "Realtime voice configuration":
  var saved: Table[string, Option[string]]
  setup:
    for name in EnvNames:
      saved[name] = if existsEnv(name): some(getEnv(name)) else: none(string)
      delEnv(name)
  teardown:
    for name in EnvNames:
      if saved[name].isSome: putEnv(name, saved[name].get)
      else: delEnv(name)

  test "preserve OpenAI voice defaults":
    let settings = loadVoiceSettings()
    check settings.baseUrl == "https://api.openai.com/v1"
    check settings.model == "gpt-realtime-2"
    check settings.voice == "alloy"
    check settings.inputRate == 24000 and settings.outputRate == 24000
    check settings.toolsEnabled
    check not settings.lfm
    check settings.sessionConfig().output_modalities.get == @["audio"]
    check settings.sessionConfig().audio.get.input.get.turn_detection.get["type"].getStr == "server_vad"

  test "LFM3 flag selects the working local voice configuration":
    putEnv("OPENAI_BASE_URL", "http://10.11.2.16:8001/v1/")
    let
      settings = loadVoiceSettings(@["--lfm"])
      config = settings.sessionConfig()
    check settings.baseUrl == "http://10.11.2.16:8001/v1"
    check settings.model == "lfm3-audio-2b"
    check settings.lfm
    check not settings.toolsEnabled
    check config.output_modalities.get == @["text", "audio"]
    check config.audio.get.input.get.format.get["rate"].getInt == 16000
    check config.audio.get.input.get.turn_detection.get.kind == JNull
    check config.audio.get.input.get.transcription.isNone
    check config.audio.get.output.get.voice.get == "female"
    check config.max_output_tokens.isNone
    check config.instructions.get == "Respond with interleaved text and audio."

  test "environment cannot enable manual turns without the flag":
    putEnv("REALTIME_TURN_MODE", "manual")
    let settings = loadVoiceSettings()
    check not settings.lfm
    check settings.sessionConfig().audio.get.input.get.turn_detection.get["type"].getStr == "server_vad"

  test "a local URL alone preserves realtime turn detection":
    putEnv("OPENAI_BASE_URL", "http://localhost:8080/v1")
    let settings = loadVoiceSettings()
    check not settings.lfm
    check settings.model == "gpt-realtime-2"
    check settings.sessionConfig().audio.get.input.get.turn_detection.get["type"].getStr == "server_vad"

  test "LFM3 flag requires an explicit endpoint":
    expect ValueError: discard loadVoiceSettings(@["--lfm"])

  test "unknown flags fail before connection":
    expect ValueError: discard loadVoiceSettings(@["--lfrm"])

  test "LFM3 environment overrides are preserved":
    putEnv("OPENAI_BASE_URL", "http://localhost:8080/v1")
    putEnv("REALTIME_VOICE", "male")
    putEnv("REALTIME_INPUT_RATE", "24000")
    putEnv("REALTIME_INSTRUCTIONS", "Respond with interleaved text and audio. Be brief.")
    let settings = loadVoiceSettings(@["--lfm"])
    check settings.voice == "male"
    check settings.inputRate == 24000
    check settings.instructions == "Respond with interleaved text and audio. Be brief."

  test "invalid output modalities fail before connection":
    putEnv("REALTIME_OUTPUT_MODALITIES", "video")
    expect ValueError: discard loadVoiceSettings()

  test "server VAD cannot silently become an uncommitted stream":
    let
      settings = loadVoiceSettings()
      configured = settings.sessionConfig()
    configured.audio.get.input.get.turn_detection = some(newJNull())
    expect ValueError: settings.verifySession(configured)

  test "reject playback rate mismatch":
    let
      settings = loadVoiceSettings()
      configured = settings.sessionConfig()
    configured.audio.get.output.get.format = some(%*{"type": "audio/pcm", "rate": 16000})
    expect ValueError: settings.verifySession(configured)

  test "invalid capture rate fails before connection":
    putEnv("REALTIME_INPUT_RATE", "0")
    expect ValueError: discard loadVoiceSettings()

  test "recorded input requires LFM3 mode":
    putEnv("REALTIME_INPUT_WAV", "fixture.wav")
    expect ValueError: discard loadVoiceSettings()
