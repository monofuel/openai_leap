# Test the Anthropic Messages API
import openai_leap, std/[unittest, json, options, os, strutils]

const
  TestModel = "claude-haiku-4-5"
  BaseUrl = "https://api.anthropic.com/v1"

suite "toMessageReq converter":
  test "converts CreateResponseReq to CreateMessageReq":
    let req = CreateResponseReq()
    req.model = "claude-opus-4-6"
    req.instructions = option("You are a helpful assistant.")
    req.temperature = option(0.7'f32)
    req.top_p = option(0.9'f32)
    req.max_output_tokens = option(2048)
    req.input = option(@[
      ResponseInput(
        `type`: "message",
        role: option("user"),
        content: option(@[ResponseInputContent(
          `type`: "input_text",
          text: option("Hello")
        )])
      ),
      ResponseInput(
        `type`: "message",
        role: option("assistant"),
        content: option(@[ResponseInputContent(
          `type`: "output_text",
          text: option("Hi there!")
        )])
      ),
      ResponseInput(
        `type`: "message",
        role: option("user"),
        content: option(@[ResponseInputContent(
          `type`: "input_text",
          text: option("How are you?")
        )])
      )
    ])

    let msgReq = toMessageReq(req)
    check msgReq.model == "claude-opus-4-6"
    check msgReq.max_tokens == 2048
    check msgReq.temperature.isSome
    check msgReq.temperature.get == 0.7'f32
    check msgReq.top_p.isSome
    check msgReq.top_p.get == 0.9'f32
    check msgReq.system.isSome
    check msgReq.system.get.getStr == "You are a helpful assistant."
    check msgReq.messages.len == 3
    check msgReq.messages[0].role == "user"
    check msgReq.messages[0].content.getStr == "Hello"
    check msgReq.messages[1].role == "assistant"
    check msgReq.messages[1].content.getStr == "Hi there!"
    check msgReq.messages[2].role == "user"
    check msgReq.messages[2].content.getStr == "How are you?"

  test "defaults max_tokens to 4096 when not set":
    let req = CreateResponseReq()
    req.model = "claude-haiku-4-5"
    req.input = option(@[
      ResponseInput(
        `type`: "message",
        role: option("user"),
        content: option(@[ResponseInputContent(
          `type`: "input_text",
          text: option("Hi")
        )])
      )
    ])

    let msgReq = toMessageReq(req)
    check msgReq.max_tokens == 4096

  test "maps system and developer roles to user":
    let req = CreateResponseReq()
    req.model = "claude-haiku-4-5"
    req.input = option(@[
      ResponseInput(
        `type`: "message",
        role: option("system"),
        content: option(@[ResponseInputContent(
          `type`: "input_text",
          text: option("System message")
        )])
      ),
      ResponseInput(
        `type`: "message",
        role: option("developer"),
        content: option(@[ResponseInputContent(
          `type`: "input_text",
          text: option("Developer message")
        )])
      )
    ])

    let msgReq = toMessageReq(req)
    check msgReq.messages.len == 2
    check msgReq.messages[0].role == "user"
    check msgReq.messages[1].role == "user"

suite "toOpenAiResponse converter":
  test "converts CreateMessageResp to OpenAiResponse":
    let resp = CreateMessageResp()
    resp.id = "msg_abc123"
    resp.`type` = "message"
    resp.role = "assistant"
    resp.model = "claude-haiku-4-5"
    resp.stop_reason = option("end_turn")
    resp.content = @[
      %* {"type": "text", "text": "Hello, world!"}
    ]
    resp.usage = AnthropicUsage(
      input_tokens: 10,
      output_tokens: 5
    )

    let oaiResp = toOpenAiResponse(resp)
    check oaiResp.id == "msg_abc123"
    check oaiResp.`object` == "response"
    check oaiResp.model == "claude-haiku-4-5"
    check oaiResp.status == "completed"
    check oaiResp.output_text.isSome
    check oaiResp.output_text.get == "Hello, world!"
    check oaiResp.output.len == 1
    check oaiResp.output[0].`type` == "message"
    check oaiResp.output[0].role.isSome
    check oaiResp.output[0].role.get == "assistant"
    check oaiResp.output[0].content.isSome
    check oaiResp.output[0].content.get[0].`type` == "output_text"
    check oaiResp.output[0].content.get[0].text.get == "Hello, world!"
    check oaiResp.usage.isSome
    check oaiResp.usage.get.input_tokens == 10
    check oaiResp.usage.get.output_tokens == 5
    check oaiResp.usage.get.total_tokens == 15

  test "handles empty content":
    let resp = CreateMessageResp()
    resp.id = "msg_empty"
    resp.`type` = "message"
    resp.role = "assistant"
    resp.model = "claude-haiku-4-5"
    resp.content = @[]
    resp.usage = AnthropicUsage(input_tokens: 0, output_tokens: 0)

    let oaiResp = toOpenAiResponse(resp)
    check oaiResp.output_text.isNone
    check oaiResp.usage.isNone

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
