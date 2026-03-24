# Test the OpenAI Realtime API (WebSocket)
import openai_leap, std/[unittest, options]

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
