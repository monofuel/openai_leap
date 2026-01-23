# Test the OpenAI Responses API
import openai_leap, std/[unittest, json, options, os, strutils]

const
  TestModel = "gpt-4o-mini"
  BaseUrl = "https://api.openai.com/v1"
  #BaseUrl = "http://localhost:11434/v1"  # For Ollama testing

proc responseOutputTexts(resp: OpenAiResponse): seq[string] =
  result = @[]
  for output in resp.output:
    if output.`type` == "message" and output.content.isSome:
      for content in output.content.get:
        if content.`type` == "output_text" and content.text.isSome:
          result.add(content.text.get)

proc responseToolCalls(resp: OpenAiResponse): seq[ResponseToolCall] =
  result = @[]
  for output in resp.output:
    if output.`type` == "function_call" and output.call_id.isSome and output.name.isSome and output.arguments.isSome:
      result.add(ResponseToolCall(
        `type`: output.`type`,
        call_id: output.call_id.get,
        name: output.name.get,
        arguments: output.arguments.get
      ))

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
      # TODO should not be using 'f32', avoid annotating floats unless required.
      req.temperature = option(0.0'f32)
      req.input = option(@[ResponseInput(
        `type`: "message",
        role: option("user"),
        content: option(@[ResponseInputContent(
          `type`: "input_text",
          text: option("What's the weather like in Paris?")
        )])
      )])
      req.tools = option(tools)
      req.tool_choice = option(%*{"type": "function", "name": "get_weather"})

      let resp = openai.createResponse(req)

      check resp.`object` == "response"
      let toolCalls = responseToolCalls(resp)
      check toolCalls.len == 1
      check toolCalls[0].name == "get_weather"
      let args = parseJson(toolCalls[0].arguments)
      check "paris" in args["location"].getStr.toLowerAscii()

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

  suite "response content types":
    test "text content":
      let resp = openai.createResponse(TestModel, "Say hello")

      let texts = responseOutputTexts(resp)
      check texts.len > 0
      check texts.join(" ").toLowerAscii().contains("hello")

    test "tool call content":
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
      req.temperature = option(0.0'f32)
      req.input = option(inputList)
      req.tools = option(tools)
      req.tool_choice = option(%*{"type": "function", "name": "calculate"})

      let resp = openai.createResponse(req)

      # Check that response structure is valid
      check resp.`object` == "response"
      let toolCalls = responseToolCalls(resp)
      check toolCalls.len == 1
      check toolCalls[0].name == "calculate"
      let args = parseJson(toolCalls[0].arguments)
      check "15" in args["expression"].getStr
      check "27" in args["expression"].getStr

    test "reasoning summary parsing":
      let req = CreateResponseReq()
      req.model = "o4-mini"
      req.reasoning = option(%*{"summary": "detailed"})
      req.input = option(@[ResponseInput(
        `type`: "message",
        role: option("user"),
        content: option(@[ResponseInputContent(
          `type`: "input_text",
          text: option("Answer 1+1 in one sentence.")
        )])
      )])

      let resp = openai.createResponse(req)
      check resp.model.startsWith("o4-mini")
      var reasoningSummary = ""
      var hasReasoningOutput = false
      for output in resp.output:
        if output.`type` == "reasoning":
          hasReasoningOutput = true
          if output.summary.isSome:
            for part in output.summary.get:
              if part.`type` == "summary_text":
                reasoningSummary = part.text

      if reasoningSummary.len > 0:
        let markdown = resp.toMarkdown()
        check markdown.contains(reasoningSummary)
      else:
        check resp.reasoning.isSome
        check resp.reasoning.get.kind != JNull

  test "get response":
    # First create a response to get its ID
    let createReq = CreateResponseReq()
    createReq.model = TestModel
    createReq.store = option(true)
    createReq.input = option(@[ResponseInput(
      `type`: "message",
      role: option("user"),
      content: option(@[ResponseInputContent(
        `type`: "input_text",
        text: option("Hello, world!")
      )])
    )])

    let createdResponse = openai.createResponse(createReq)
    let responseId = createdResponse.id

    # Now retrieve the response by ID
    let retrievedResponse = openai.getResponse(responseId)

    # Validate the retrieved response
    check retrievedResponse.id == responseId
    check retrievedResponse.`object` == "response"
    check retrievedResponse.model.startsWith(TestModel)
    check retrievedResponse.status == "completed"

  test "delete response":
    # First create a response to delete
    let createReq = CreateResponseReq()
    createReq.model = TestModel
    createReq.store = option(true)  # Ensure response is stored
    createReq.input = option(@[ResponseInput(
      `type`: "message",
      role: option("user"),
      content: option(@[ResponseInputContent(
        `type`: "input_text",
        text: option("Delete me!")
      )])
    )])

    let createdResponse = openai.createResponse(createReq)
    let responseId = createdResponse.id

    # Now delete the response
    let deleteResult = openai.deleteResponse(responseId)

    # Validate the delete response
    check deleteResult.id == responseId
    check deleteResult.`object` == "response.deleted"  # API returns this specific object type
    check deleteResult.deleted == true

  suite "response tools":

    # Tool implementations for testing
    proc addNumbersTool(args: JsonNode): string =
      let a = args["a"].getInt()
      let b = args["b"].getInt()
      return $(a + b)

    proc getWeatherTool(args: JsonNode): string =
      let location = args["location"].getStr()
      case location.toLowerAscii():
      of "paris": return "sunny, 22°C"
      of "london": return "rainy, 15°C"
      of "tokyo": return "cloudy, 20°C"
      else: return "weather unavailable"

    proc multiplyNumbersTool(args: JsonNode): string =
      let a = args["a"].getInt()
      let b = args["b"].getInt()
      return $(a * b)

    test "createResponseWithTools basic functionality":
      # Setup tools table
      var basicTools = newResponseToolsTable()
      basicTools.register("add_numbers",
        ToolFunction(
          name: "add_numbers",
          description: option("Add two numbers together"),
          parameters: option(%*{
            "type": "object",
            "properties": {
              "a": {"type": "integer", "description": "First number"},
              "b": {"type": "integer", "description": "Second number"}
            },
            "required": ["a", "b"]
          })
        ),
        addNumbersTool
      )

      # Create request
      let req = CreateResponseReq()
      req.model = TestModel
      req.temperature = option(0.0'f32)
      req.tool_choice = option(%*{"type": "function", "name": "add_numbers"})
      req.input = option(@[ResponseInput(
        `type`: "message",
        role: option("user"),
        content: option(@[ResponseInputContent(
          `type`: "input_text",
          text: option("What is 15 + 27?")
        )])
      )])

      var toolCalls: seq[ResponseToolCall] = @[]
      # Execute with automated tool handling
      let resp = openai.createResponseWithTools(req, basicTools, proc(req: CreateResponseReq, resp: OpenAiResponse) =
        for toolCall in responseToolCalls(resp):
          toolCalls.add(toolCall)
      )

      # Verify response structure
      check resp.`object` == "response"
      check resp.status == "completed"
      check resp.output.len > 0

      # Verify the tool was called and returned the correct result
      check toolCalls.len >= 1
      check toolCalls[0].name == "add_numbers"
      let callArgs = parseJson(toolCalls[0].arguments)
      check callArgs["a"].getInt() == 15
      check callArgs["b"].getInt() == 27

      let outputTexts = responseOutputTexts(resp)
      check outputTexts.len > 0
      let finalText = outputTexts.join(" ").toLowerAscii()
      check "42" in finalText or "forty" in finalText

      # Setup tools table with multiple functions
      var multiTools = newResponseToolsTable()
      multiTools.register("add_numbers",
        ToolFunction(
          name: "add_numbers",
          description: option("Add two numbers together"),
          parameters: option(%*{
            "type": "object",
            "properties": {
              "a": {"type": "integer", "description": "First number"},
              "b": {"type": "integer", "description": "Second number"}
            },
            "required": ["a", "b"]
          })
        ),
        addNumbersTool
      )

      multiTools.register("get_weather",
        ToolFunction(
          name: "get_weather",
          description: option("Get weather for a location"),
          parameters: option(%*{
            "type": "object",
            "properties": {
              "location": {"type": "string", "description": "City name"}
            },
            "required": ["location"]
          })
        ),
        getWeatherTool
      )

      # Create request asking for both operations
      let multiReq = CreateResponseReq()
      multiReq.model = TestModel
      multiReq.temperature = option(0.0'f32)
      multiReq.input = option(@[ResponseInput(
        `type`: "message",
        role: option("user"),
        content: option(@[ResponseInputContent(
          `type`: "input_text",
          text: option("Use add_numbers to compute 10 + 5, then use get_weather for Paris. Reply with both results.")
        )])
      )])

      # Track conversation progress
      var conversationSteps = 0
      var callbackInvoked = false

      var multiToolCalls: seq[ResponseToolCall] = @[]
      let multiResp = openai.createResponseWithTools(multiReq, multiTools, proc(req: CreateResponseReq, resp: OpenAiResponse) =
        inc conversationSteps
        callbackInvoked = true
        for toolCall in responseToolCalls(resp):
          multiToolCalls.add(toolCall)
      )

      # Verify response structure
      check multiResp.`object` == "response"
      check multiResp.status == "completed"
      check callbackInvoked
      check conversationSteps >= 1

      # Verify both tools were used and results are in the response
      var addCalled = false
      var weatherCalled = false
      for call in multiToolCalls:
        if call.name == "add_numbers": addCalled = true
        if call.name == "get_weather": weatherCalled = true
      check addCalled
      check weatherCalled

      let multiTexts = responseOutputTexts(multiResp)
      check multiTexts.len > 0
      let multiText = multiTexts.join(" ").toLowerAscii()
      check "15" in multiText or "paris" in multiText or "sunny" in multiText


    test "createResponseWithTools unknown tool error handling":
      # Setup tools table with only one tool
      var errorTools = newResponseToolsTable()
      errorTools.register("multiply_numbers",
        ToolFunction(
          name: "multiply_numbers",
          description: option("Multiply two numbers"),
          parameters: option(%*{
            "type": "object",
            "properties": {
              "a": {"type": "integer", "description": "First number"},
              "b": {"type": "integer", "description": "Second number"}
            },
            "required": ["a", "b"]
          })
        ),
        multiplyNumbersTool
      )

      # TODO this seems like a silly test? why are we doing this?
      # Create request asking for an operation that doesn't match available tools
      let errorReq = CreateResponseReq()
      errorReq.model = TestModel
      errorReq.temperature = option(0.0'f32)
      errorReq.input = option(@[ResponseInput(
        `type`: "message",
        role: option("user"),
        content: option(@[ResponseInputContent(
          `type`: "input_text",
          text: option("Please use the divide_numbers tool to divide 20 by 4")
        )])
      )])

      # This should still work - the model might not call any tools or handle gracefully
      let resp = openai.createResponseWithTools(errorReq, errorTools)

      # Verify response structure is still valid
      check resp.`object` == "response"
      check resp.status == "completed"
      check resp.output.len > 0

    test "createResponseWithTools sequential tool calls":
      # Setup tools that work in sequence
      var seqTools = newResponseToolsTable()

      seqTools.register("add_numbers",
        ToolFunction(
          name: "add_numbers",
          description: option("Add two numbers together"),
          parameters: option(%*{
            "type": "object",
            "properties": {
              "a": {"type": "integer", "description": "First number"},
              "b": {"type": "integer", "description": "Second number"}
            },
            "required": ["a", "b"]
          })
        ),
        addNumbersTool
      )

      seqTools.register("multiply_result",
        ToolFunction(
          name: "multiply_result",
          description: option("Multiply a number by 2"),
          parameters: option(%*{
            "type": "object",
            "properties": {
              "number": {"type": "integer", "description": "Number to multiply by 2"}
            },
            "required": ["number"]
          })
        ),
        proc(args: JsonNode): string =
          let num = args["number"].getInt()
          return $(num * 2)
      )

      # Create request that requires sequential operations
      let seqReq = CreateResponseReq()
      seqReq.model = TestModel
      seqReq.temperature = option(0.0'f32)
      seqReq.parallel_tool_calls = option(false)
      seqReq.tool_choice = option(% "auto")
      seqReq.input = option(@[ResponseInput(
        `type`: "message",
        role: option("user"),
        content: option(@[ResponseInputContent(
          `type`: "input_text",
          text: option("Call add_numbers first for 3 + 4, then call multiply_result with the sum. Finish with the final number.")
        )])
      )])

      # Track tool call sequence
      var toolCallSequence: seq[string] = @[]

      var addArgsSeen = false
      var multiplyArgsSeen = false
      let resp = openai.createResponseWithTools(seqReq, seqTools, proc(req: CreateResponseReq, resp: OpenAiResponse) =
        # Extract tool calls from this response
        for toolCall in responseToolCalls(resp):
          toolCallSequence.add(toolCall.name)
          let args = parseJson(toolCall.arguments)
          if toolCall.name == "add_numbers":
            check args["a"].getInt() == 3
            check args["b"].getInt() == 4
            addArgsSeen = true
          elif toolCall.name == "multiply_result":
            check args["number"].getInt() == 7
            multiplyArgsSeen = true
      )

      # Verify response structure
      check resp.`object` == "response"
      check resp.status == "completed"

      # Verify tool calls occurred in sequence
      let addIdx = toolCallSequence.find("add_numbers")
      let multiplyIdx = toolCallSequence.find("multiply_result")
      check addIdx >= 0
      check multiplyIdx >= 0
      check addIdx < multiplyIdx
      check addArgsSeen
      check multiplyArgsSeen

      let seqTexts = responseOutputTexts(resp)
      check seqTexts.len > 0
      check "14" in seqTexts.join(" ")


    test "createResponseWithTools callback functionality":
      # Setup simple tool
      var callbackTools = newResponseToolsTable()
      callbackTools.register("add_numbers",
        ToolFunction(
          name: "add_numbers",
          description: option("Add two numbers together"),
          parameters: option(%*{
            "type": "object",
            "properties": {
              "a": {"type": "integer", "description": "First number"},
              "b": {"type": "integer", "description": "Second number"}
            },
            "required": ["a", "b"]
          })
        ),
        addNumbersTool
      )

      let callbackReq = CreateResponseReq()
      callbackReq.model = TestModel
      callbackReq.temperature = option(0.0'f32)
      callbackReq.tool_choice = option(%*{"type": "function", "name": "add_numbers"})
      callbackReq.input = option(@[ResponseInput(
        `type`: "message",
        role: option("user"),
        content: option(@[ResponseInputContent(
          `type`: "input_text",
          text: option("Calculate 7 + 8")
        )])
      )])

      # Test callback functionality
      var callbackCount = 0
      var lastResponseId = ""
      var callbackWorked = false

      let resp = openai.createResponseWithTools(callbackReq, callbackTools, proc(req: CreateResponseReq, resp: OpenAiResponse) =
        inc callbackCount
        lastResponseId = resp.id
        callbackWorked = true
      )

      # Verify callback was invoked
      check callbackWorked
      check callbackCount >= 1  # At least initial response
      check lastResponseId == resp.id

      # Verify final response
      check resp.`object` == "response"
      check resp.status == "completed"