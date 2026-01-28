# Test the Responses API with llama.cpp (previous_response_id disabled)
# expets llama.cpp running on localhost port 8990 with qwen3-4b-instruct-2507
# NB. llama.cpp needs to be executed with --jinja to get the correct chat template for tool usage.
#
# This tests the conversation history accumulation logic for servers that
# don't support previous_response_id.

import
  std/[unittest, json, options, strutils],
  openai_leap

const
  TestModel = "qwen3-4b-instruct-2507"
  LlamaCppUrl = "http://localhost:8990/v1"

# Global flag to track tool usage
var toolWasCalled = false

# Simple tool for testing
proc echoTool(args: JsonNode): string =
  toolWasCalled = true
  if args.hasKey("message"):
    result = "Echo: " & args["message"].getStr()
  else:
    result = "Echo: (no message)"

suite "responses llama.cpp":
  var llama: OpenAiApi

  setup:
    llama = newOpenAiApi(baseUrl = LlamaCppUrl, apiKey = "")

  teardown:
    llama.close()

  suite "basic chat":
    test "simple text response":
      let input = @[ResponseInput(
        `type`: "message",
        role: option("user"),
        content: option(@[ResponseInputContent(
          `type`: "input_text",
          text: option("Hello! Please respond with a short greeting.")
        )])
      )]

      let req = CreateResponseReq()
      req.model = TestModel
      req.input = option(input)

      let resp = llama.createResponse(req)

      # Verify basic response structure
      check resp.`object` == "response"
      check resp.status == "completed"
      check resp.output.len > 0

      # Check for text output
      var hasText = false
      for output in resp.output:
        if output.`type` == "message" and output.content.isSome:
          for content in output.content.get:
            if content.`type` == "output_text" and content.text.isSome:
              hasText = true
              check content.text.get.len > 0
              break
      check hasText

  suite "tool usage with conversation history":
    test "qwen3 uses tools correctly":
      # Test that qwen3 actually calls tools when appropriate
      # This is critical for the tool calling functionality to work

      # Reset tool call flag
      toolWasCalled = false

      # Setup tools
      var tools = newResponseToolsTable()
      tools.register("get_weather",
        ToolFunction(
          name: "get_weather",
          description: option("Get the current weather for a location"),
          parameters: option(%*{
            "type": "object",
            "properties": {
              "location": {"type": "string", "description": "City name"}
            },
            "required": ["location"]
          })
        ),
        proc(args: JsonNode): string =
          toolWasCalled = true
          let location = args["location"].getStr()
          "Weather in " & location & ": Sunny, 72°F"
      )

      let input = @[ResponseInput(
        `type`: "message",
        role: option("user"),
        content: option(@[ResponseInputContent(
          `type`: "input_text",
          text: option("What is the current weather in Tokyo? Please use the available tools to get accurate information.")
        )])
      )]

      var req = CreateResponseReq()
      req.model = TestModel
      req.input = option(input)

      # Use previous_response_id = false to test conversation history accumulation
      let resp = llama.createResponseWithTools(req, tools, usePreviousResponseId = false)

      # Verify response structure
      check resp.`object` == "response"
      check resp.status == "completed"
      check resp.output.len > 0

      # Verify the tool was actually called
      check toolWasCalled == true

      # For llama.cpp (usePreviousResponseId = false), verify the request now contains
      # the accumulated conversation history including tool outputs
      check req.input.isSome
      let conversationHistory = req.input.get

      # Verify tool outputs are in the conversation history
      var foundToolOutput = false
      for message in conversationHistory:
        if message.`type` == "function_call_output" and message.output.isSome:
          let output = message.output.get
          if "Weather in Tokyo: Sunny, 72°F" in output:
            foundToolOutput = true
            break

      check foundToolOutput == true

      # Also verify the final response incorporates the tool result
      var responseText = ""
      for output in resp.output:
        if output.`type` == "message" and output.content.isSome:
          for content in output.content.get:
            if content.`type` == "output_text" and content.text.isSome:
              responseText = content.text.get

      # Verify the response incorporates the tool result ("Weather in Tokyo: Sunny, 72°F")
      check "72°F" in responseText or "Sunny" in responseText

      echo "✓ Tool calling works correctly - conversation history includes tool outputs and results are incorporated"

    test "conversation history accumulation works":
      # Test that multiple independent requests work (simulating conversation history accumulation)
      # Each request should work independently without previous_response_id

      # Reset tool call flag
      toolWasCalled = false

      # Setup tools
      var tools = newResponseToolsTable()
      tools.register("echo_tool",
        ToolFunction(
          name: "echo_tool",
          description: option("Echo back a message"),
          parameters: option(%*{
            "type": "object",
            "properties": {
              "message": {"type": "string", "description": "Message to echo"}
            },
            "required": ["message"]
          })
        ),
        echoTool
      )

      # First request
      let input1 = @[ResponseInput(
        `type`: "message",
        role: option("user"),
        content: option(@[ResponseInputContent(
          `type`: "input_text",
          text: option("Say 'test one' using the echo_tool")
        )])
      )]

      var req1 = CreateResponseReq()
      req1.model = TestModel
      req1.input = option(input1)

      let resp1 = llama.createResponseWithTools(req1, tools, usePreviousResponseId = false)

      # Verify first request works
      check resp1.`object` == "response"
      check resp1.status == "completed"

      # Second independent request
      let input2 = @[ResponseInput(
        `type`: "message",
        role: option("user"),
        content: option(@[ResponseInputContent(
          `type`: "input_text",
          text: option("Say 'test two' using the echo_tool")
        )])
      )]

      var req2 = CreateResponseReq()
      req2.model = TestModel
      req2.input = option(input2)

      let resp2 = llama.createResponseWithTools(req2, tools, usePreviousResponseId = false)

      # Verify second request also works independently
      check resp2.`object` == "response"
      check resp2.status == "completed"
      check resp1.id != resp2.id  # Different responses
