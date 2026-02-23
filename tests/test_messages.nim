# Test the Anthropic Messages API
import openai_leap, std/[unittest, json, options, os, strutils]

const
  TestModel = "claude-haiku-4-5"
  BaseUrl = "https://api.anthropic.com/v1"

suite "anthropic messages api":
  var api: OpenAiApi

  setup:
    let anthropicKey = getEnv("ANTHROPIC_API_KEY", "")
    api = newOpenAiApi(BaseUrl, apiKey = anthropicKey)
  teardown:
    api.close()

  test "simple text message":
    let resp = api.createMessage(TestModel, 1024, "Say hello in one word")
    check resp.`type` == "message"
    check resp.role == "assistant"
    check resp.stop_reason.isSome
    check resp.stop_reason.get == "end_turn"
    check messageText(resp).len > 0

  test "full request with system prompt":
    let req = CreateMessageReq()
    req.model = TestModel
    req.max_tokens = 1024
    req.messages = @[
      AnthropicMessage(
        role: "user",
        content: % "What is 2+2?"
      )
    ]
    req.system = option(% "You are a helpful math tutor. Answer concisely.")
    let resp = api.createMessage(req)
    check resp.`type` == "message"
    check resp.usage.input_tokens > 0
    check resp.usage.output_tokens > 0
    check messageText(resp).len > 0

  test "tool use":
    var tools = newResponseToolsTable()
    let weatherFunc = ToolFunction(
      name: "get_weather",
      description: option("Get the current weather for a location"),
      parameters: option(%* {
        "type": "object",
        "properties": {
          "location": {
            "type": "string",
            "description": "The city and state, e.g. San Francisco, CA"
          }
        },
        "required": ["location"]
      })
    )
    tools.register("get_weather", weatherFunc, proc(args: JsonNode): string =
      let location = args["location"].getStr
      return "The weather in " & location & " is 72°F and sunny."
    )

    var req = CreateMessageReq()
    req.model = TestModel
    req.max_tokens = 1024
    req.messages = @[
      AnthropicMessage(
        role: "user",
        content: % "What is the weather in San Francisco?"
      )
    ]
    let resp = api.createMessageWithTools(req, tools)
    check resp.stop_reason.isSome
    check resp.stop_reason.get == "end_turn"
    check messageText(resp).len > 0

  test "streaming":
    let req = CreateMessageReq()
    req.model = TestModel
    req.max_tokens = 1024
    req.messages = @[
      AnthropicMessage(
        role: "user",
        content: % "Say hello in one word"
      )
    ]
    let stream = api.streamMessage(req)
    var events = 0
    while true:
      let ev = stream.nextMessageEvent()
      if ev.isNone: break
      inc events
    check events > 0

  test "multi-turn conversation":
    let req = CreateMessageReq()
    req.model = TestModel
    req.max_tokens = 1024
    req.messages = @[
      AnthropicMessage(role: "user", content: % "My name is Alice."),
      AnthropicMessage(role: "assistant", content: % "Hello Alice! Nice to meet you."),
      AnthropicMessage(role: "user", content: % "What is my name?")
    ]
    let resp = api.createMessage(req)
    check resp.`type` == "message"
    check "Alice" in messageText(resp)
