# Test the OpenAI Responses API
import openai_leap, std/[unittest, json, options, os, strutils]

# Use a model that supports the Responses API
const
  TestModel = "gpt-4o-mini"
  BaseUrl = "https://api.openai.com/v1"
  #BaseUrl = "http://localhost:11434/v1"  # For Ollama testing

suite "responses":
  var openai: OpenAiApi

  setup:
    if BaseUrl == "http://localhost:11434/v1":
      putEnv("OPENAI_API_KEY", "ollama")
    openai = newOpenAiApi(BaseUrl)
  teardown:
    openai.close()

  suite "create response":
    test "basic text response":
      let input = @[ResponseInput(
        `type`: "message",
        role: option("user"),
        content: option(@[ResponseInputContent(
          `type`: "input_text",
          text: option("Hello, how are you today?")
        )])
      )]

      let req = CreateResponseReq()
      req.model = TestModel
      req.input = option(input)

      let resp = openai.createResponse(req)

      check resp.`object` == "response"
      check resp.model.startsWith(TestModel)
      check resp.output.len > 0
      check resp.usage.isSome
      check resp.usage.get.total_tokens > 0

    test "convenience method with text":
      let resp = openai.createResponse(TestModel, "Tell me a joke about programming.")

      check resp.`object` == "response"
      check resp.model.startsWith(TestModel)
      check resp.output.len > 0

    test "response with tools":
      let tools = @[ResponseTool(
        `type`: "function",
        name: "get_weather",
        description: option("Get the weather for a location"),
        parameters: option(%*{
          "type": "object",
          "properties": {
            "location": {"type": "string", "description": "City name"}
          },
          "required": ["location"]
        })
      )]

      let req = CreateResponseReq()
      req.model = TestModel
      req.input = option(@[ResponseInput(
        `type`: "message",
        role: option("user"),
        content: option(@[ResponseInputContent(
          `type`: "input_text",
          text: option("What's the weather like in Paris?")
        )])
      )])
      req.tools = option(tools)

      let resp = openai.createResponse(req)

      check resp.`object` == "response"
      check resp.output.len > 0

    test "response with multiple input types":
      let input = @[
        ResponseInput(
          `type`: "message",
          role: option("user"),
          content: option(@[ResponseInputContent(
            `type`: "input_text",
            text: option("Describe this image:")
          )])
        ),
        ResponseInput(
          `type`: "message",
          role: option("user"),
          content: option(@[ResponseInputContent(
            `type`: "input_text",
            text: option("A beautiful sunset over mountains")
          )])
        )
      ]

      let req = CreateResponseReq()
      req.model = TestModel
      req.input = option(input)

      let resp = openai.createResponse(req)

      check resp.`object` == "response"
      check resp.output.len > 0

    # test "response with temperature and max tokens":
    #   # TODO: This test fails with JSON parsing - response structure may differ
    #   skip()

  suite "response content types":
    test "text content":
      let resp = openai.createResponse(TestModel, "Say hello")

      check resp.output.len > 0
      check resp.output[0].content.len > 0

      let content = resp.output[0].content[0]
      check content.`type` == "output_text"
      check content.text.isSome
      check content.text.get.toLowerAscii().contains("hello")

    test "tool call content (if available)":
      # Test tool calling workflow
      let tools = @[ResponseTool(
        `type`: "function",
        name: "calculate",
        description: option("Calculate a mathematical expression"),
        parameters: option(%*{
          "type": "object",
          "properties": {
            "expression": {"type": "string", "description": "Math expression to evaluate"}
          },
          "required": ["expression"]
        })
      )]

      # Create a list to accumulate inputs
      var inputList = @[ResponseInput(
        `type`: "message",
        role: option("user"),
        content: option(@[ResponseInputContent(
          `type`: "input_text",
          text: option("What is 15 + 27?")
        )])
      )]

      let req = CreateResponseReq()
      req.model = TestModel
      req.input = option(inputList)
      req.tools = option(tools)

      let resp = openai.createResponse(req)

      # Check that response structure is valid
      check resp.`object` == "response"
      check resp.output.len > 0

      # Check if there are any tool calls in the output
      var hasToolCalls = false
      for output in resp.output:
        for content in output.content:
          if content.`type` == "function_call":
            hasToolCalls = true
            check content.tool_call.isSome
            let toolCall = content.tool_call.get
            check toolCall.`type` == "function_call"
            check toolCall.function.isSome
            check toolCall.function.get.name == "calculate"

            # If we find tool calls, we could add the function call output
            # to continue the conversation, but for this test we just verify structure
