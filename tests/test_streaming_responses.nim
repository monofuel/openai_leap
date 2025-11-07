# Test streaming responses with tool calling
import std/[unittest, options, json, os], openai_leap

const
  TestModel = "gpt-4o-mini"
  BaseUrl = "https://api.openai.com/v1"

# Note: Tool implementations are defined in the test but not used since we're only testing streaming structure

suite "streaming responses with tools":
  var openai: OpenAiApi

  setup:
    if BaseUrl == "http://localhost:11434/v1":
      putEnv("OPENAI_API_KEY", "ollama")
    openai = newOpenAiApi(BaseUrl)
  teardown:
    openai.close()

  test "streaming response with tool calls":

    # Define tools for the response
    let tools = @[ResponseTool(
      `type`: "function",
      name: "get_weather",
      description: option("Get the current weather for a location"),
      parameters: option(%*{
        "type": "object",
        "properties": {
          "location": {"type": "string", "description": "City name"}
        },
        "required": ["location"]
      })
    ), ResponseTool(
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

    # Create a request that might trigger tool calls
    let req = CreateResponseReq()
    req.model = TestModel
    req.input = option(@[ResponseInput(
      `type`: "message",
      role: option("user"),
      content: option(@[ResponseInputContent(
        `type`: "input_text",
        text: option("What's the weather like in Paris and what is 2+2?")
      )])
    )])
    req.tools = option(tools)
    req.stream = option(true)

    # Start streaming
    let stream = openai.streamResponse(req)

    echo "Streaming response with tool calls:"

    var chunkCount = 0
    var toolCallsFound = 0
    var contentReceived = ""

    while true:
      let chunkOpt = stream.nextResponseChunk()
      if chunkOpt.isNone:
        break

      let chunk = chunkOpt.get
      chunkCount += 1

      # Check the type of event and extract relevant data
      if chunk.hasKey("type"):
        let eventType = chunk["type"].str
        case eventType:
        of "response.output_item.added":
          if chunk.hasKey("item") and chunk["item"].hasKey("type"):
            let itemType = chunk["item"]["type"].str
            if itemType == "function_call":
              toolCallsFound += 1
              echo "  Tool call initiated: " & chunk["item"]["name"].str
        of "response.output_text.delta":
          if chunk.hasKey("delta"):
            let delta = chunk["delta"].str
            contentReceived &= delta
            write(stdout, delta)
            flushFile(stdout)
        of "response.completed":
          # Final response with complete output
          if chunk.hasKey("response") and chunk["response"].hasKey("output"):
            let output = chunk["response"]["output"]
            if output.kind == JArray:
              for item in output:
                if item.hasKey("type") and item["type"].str == "message":
                  if item.hasKey("content"):
                    for contentPart in item["content"]:
                      if contentPart.hasKey("type") and contentPart["type"].str == "output_text":
                        if contentPart.hasKey("text"):
                          contentReceived = contentPart["text"].str
                          break
        else:
          discard # Other event types

    echo "\nStreaming completed. Chunks: " & $chunkCount & ", Tool calls: " & $toolCallsFound
    # Validate that we received streaming data
    check chunkCount > 10  # Should have multiple chunks for a streaming response
    check toolCallsFound > 0  # Should have found tool calls for this test

  test "streaming response without tools":

    # Simple streaming test without tools
    let req = CreateResponseReq()
    req.model = TestModel
    req.input = option(@[ResponseInput(
      `type`: "message",
      role: option("user"),
      content: option(@[ResponseInputContent(
        `type`: "input_text",
        text: option("Tell me a short joke about programming.")
      )])
    )])
    req.stream = option(true)

    let stream = openai.streamResponse(req)

    echo "Simple streaming response:"

    var contentReceived = ""
    var chunkCount = 0

    while true:
      let chunkOpt = stream.nextResponseChunk()
      if chunkOpt.isNone:
        break

      let chunk = chunkOpt.get
      chunkCount += 1

      # Extract content from the streaming response
      if chunk.hasKey("type"):
        let eventType = chunk["type"].str
        case eventType:
        of "response.output_text.delta":
          if chunk.hasKey("delta"):
            let delta = chunk["delta"].str
            contentReceived &= delta
            write(stdout, delta)
            flushFile(stdout)
        of "response.completed":
          # Final response with complete output
          if chunk.hasKey("response") and chunk["response"].hasKey("output"):
            let output = chunk["response"]["output"]
            if output.kind == JArray:
              for item in output:
                if item.hasKey("type") and item["type"].str == "message":
                  if item.hasKey("content"):
                    for contentPart in item["content"]:
                      if contentPart.hasKey("type") and contentPart["type"].str == "output_text":
                        if contentPart.hasKey("text"):
                          contentReceived = contentPart["text"].str
                          break
        else:
          discard # Other event types

    echo "\nStreaming completed. Chunks: " & $chunkCount & ", Content length: " & $contentReceived.len
    # Validate that we received streaming data
    check chunkCount > 10  # Should have multiple chunks for a streaming response
    check contentReceived.len > 0  # Should have received text content
