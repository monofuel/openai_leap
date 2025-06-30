import
  std/[unittest, options, json, tables, strutils, strformat, os, parseopt],
  openai_leap, jsony

# Parse command line arguments
var updateGold = false
var p = initOptParser()
while true:
  p.next()
  case p.kind
  of cmdEnd: break
  of cmdShortOption, cmdLongOption:
    if p.key == "u" or p.key == "update-gold":
      updateGold = true
  of cmdArgument:
    discard

var output = "---\n"

# Create test data with fixed values for deterministic output
let
  testUsage = Usage(
    prompt_tokens: 150,
    total_tokens: 200
  )

  testToolCall = ToolResp(
    id: "call_123456789",
    `type`: "function",
    function: ToolFunctionResp(
      name: "get_weather",
      arguments: """{"location": "San Francisco", "unit": "celsius"}"""
    )
  )

  testMessage = RespMessage(
    content: "The weather in San Francisco is 18°C with partly cloudy skies.",
    role: "assistant",
    name: none(string),
    tool_calls: none(seq[ToolResp]),
    refusal: none(string)
  )

  testMessageWithToolCalls = RespMessage(
    content: "I'll check the weather for you.",
    role: "assistant", 
    name: none(string),
    tool_calls: option(@[testToolCall]),
    refusal: none(string)
  )

  testMessageWithRefusal = RespMessage(
    content: "",
    role: "assistant",
    name: none(string),
    tool_calls: none(seq[ToolResp]),
    refusal: option("I cannot provide information about that topic.")
  )

  testChoice = CreateChatMessage(
    finish_reason: "stop",
    index: 0,
    message: option(testMessage),
    delta: none(RespMessage),
    log_probs: none(JsonNode)
  )

  testChoiceWithToolCalls = CreateChatMessage(
    finish_reason: "tool_calls",
    index: 0,
    message: option(testMessageWithToolCalls),
    delta: none(RespMessage),
    log_probs: none(JsonNode)
  )

  testChoiceWithRefusal = CreateChatMessage(
    finish_reason: "stop",
    index: 1,
    message: option(testMessageWithRefusal),
    delta: none(RespMessage),
    log_probs: none(JsonNode)
  )

  testDeltaMessage = RespMessage(
    content: " with",
    role: "assistant",
    name: none(string),
    tool_calls: none(seq[ToolResp]),
    refusal: none(string)
  )

  testStreamingChoice = CreateChatMessage(
    finish_reason: "",
    index: 0,
    message: none(RespMessage),
    delta: option(testDeltaMessage),
    log_probs: none(JsonNode)
  )

# Test basic response
output.add "# Test: Basic CreateChatCompletionResp\n\n"
let basicResp = CreateChatCompletionResp(
  id: "chatcmpl-123456789",
  choices: @[testChoice],
  created: 1699564800,
  model: "gpt-4",
  system_fingerprint: "fp_12345678",
  `object`: "chat.completion",
  usage: testUsage
)
output.add basicResp.toMarkdown() & "\n\n"

# Test response with tool calls
output.add "# Test: CreateChatCompletionResp with Tool Calls\n\n"
let toolCallsResp = CreateChatCompletionResp(
  id: "chatcmpl-987654321", 
  choices: @[testChoiceWithToolCalls],
  created: 1699564900,
  model: "gpt-4",
  system_fingerprint: "fp_87654321",
  `object`: "chat.completion",
  usage: testUsage
)
output.add toolCallsResp.toMarkdown() & "\n\n"

# Test response with refusal
output.add "# Test: CreateChatCompletionResp with Refusal\n\n"
let refusalResp = CreateChatCompletionResp(
  id: "chatcmpl-111222333",
  choices: @[testChoiceWithRefusal],
  created: 1699565000,
  model: "gpt-4",
  system_fingerprint: "fp_11122233",
  `object`: "chat.completion",
  usage: testUsage
)
output.add refusalResp.toMarkdown() & "\n\n"

# Test streaming response 
output.add "# Test: CreateChatCompletionResp with Streaming Delta\n\n"
let streamingResp = CreateChatCompletionResp(
  id: "chatcmpl-444555666",
  choices: @[testStreamingChoice],
  created: 1699565100,
  model: "gpt-4",
  system_fingerprint: "fp_44455566",
  `object`: "chat.completion.chunk",
  usage: nil
)
output.add streamingResp.toMarkdown() & "\n\n"

# Test response with multiple choices
output.add "# Test: CreateChatCompletionResp with Multiple Choices\n\n"
let multiChoiceResp = CreateChatCompletionResp(
  id: "chatcmpl-777888999",
  choices: @[testChoice, testChoiceWithToolCalls, testChoiceWithRefusal],
  created: 1699565200,
  model: "gpt-4",
  system_fingerprint: "fp_77788899",
  `object`: "chat.completion", 
  usage: testUsage
)
output.add multiChoiceResp.toMarkdown() & "\n\n"

# Test response with empty content
output.add "# Test: CreateChatCompletionResp with Empty Content\n\n"
let emptyMessage = RespMessage(
  content: "",
  role: "assistant",
  name: none(string),
  tool_calls: none(seq[ToolResp]),
  refusal: none(string)
)
let emptyChoice = CreateChatMessage(
  finish_reason: "stop",
  index: 0,
  message: option(emptyMessage),
  delta: none(RespMessage),
  log_probs: none(JsonNode)
)
let emptyResp = CreateChatCompletionResp(
  id: "chatcmpl-000111222",
  choices: @[emptyChoice],
  created: 1699565300,
  model: "gpt-3.5-turbo",
  system_fingerprint: "fp_00011122",
  `object`: "chat.completion",
  usage: testUsage
)
output.add emptyResp.toMarkdown() & "\n\n"

# Test round-trip parsing - serialize then parse back and compare JSON
output.add "# Test: Round-trip Parsing\n\n"

# Test basic response round-trip
output.add "## Basic Response Round-trip\n\n"
let basicMarkdown = basicResp.toMarkdown()
let parsedBasic = toCreateChatCompletionResp(basicMarkdown)
let originalJson = basicResp.toJson()
let parsedJson = parsedBasic.toJson()
output.add "**Original JSON:**\n```json\n" & originalJson & "\n```\n\n"
output.add "**Parsed JSON:**\n```json\n" & parsedJson & "\n```\n\n"
output.add "**Match:** " & $(originalJson == parsedJson) & "\n\n"

# Test tool calls response round-trip  
output.add "## Tool Calls Response Round-trip\n\n"
let toolCallsMarkdown = toolCallsResp.toMarkdown()
let parsedToolCalls = toCreateChatCompletionResp(toolCallsMarkdown)
let toolCallsOriginalJson = toolCallsResp.toJson()
let toolCallsParsedJson = parsedToolCalls.toJson()
output.add "**Original JSON:**\n```json\n" & toolCallsOriginalJson & "\n```\n\n"
output.add "**Parsed JSON:**\n```json\n" & toolCallsParsedJson & "\n```\n\n"
output.add "**Match:** " & $(toolCallsOriginalJson == toolCallsParsedJson) & "\n\n"

# Test empty content response round-trip
output.add "## Empty Content Response Round-trip\n\n"
let emptyMarkdown = emptyResp.toMarkdown()
let parsedEmpty = toCreateChatCompletionResp(emptyMarkdown)
let emptyOriginalJson = emptyResp.toJson()
let emptyParsedJson = parsedEmpty.toJson()
output.add "**Original JSON:**\n```json\n" & emptyOriginalJson & "\n```\n\n"
output.add "**Parsed JSON:**\n```json\n" & emptyParsedJson & "\n```\n\n"
output.add "**Match:** " & $(emptyOriginalJson == emptyParsedJson) & "\n\n"

# Test request serialization
output.add "# Test: CreateChatCompletionReq Serialization\n\n"

# Create test request data
let
  testTool = Tool(
    `type`: "function",
    function: ToolFunction(
      name: "get_weather",
      description: option("Get current weather for a location"),
      parameters: option(parseJson("""{"type": "object", "properties": {"location": {"type": "string"}}}"""))
    )
  )

  testResponseFormat = ResponseFormatObj(
    `type`: "json_schema",
    json_schema: option(parseJson("""{"type": "object", "properties": {"weather": {"type": "string"}}}"""))
  )

# Test basic request
output.add "## Basic CreateChatCompletionReq\n\n"
let basicReq = CreateChatCompletionReq(
  messages: @[
    Message(
      role: "system",
      content: option(@[
        MessageContentPart(`type`: "text", text: option("You are a helpful assistant."))
      ])
    ),
    Message(
      role: "user", 
      content: option(@[
        MessageContentPart(`type`: "text", text: option("What's the weather like?"))
      ])
    )
  ],
  model: "gpt-4",
  temperature: option(0.7f),
  max_tokens: option(150)
)
output.add basicReq.toMarkdown() & "\n\n"

# Test request with tools
output.add "## CreateChatCompletionReq with Tools\n\n"
let toolsReq = CreateChatCompletionReq(
  messages: @[
    Message(
      role: "user",
      content: option(@[
        MessageContentPart(`type`: "text", text: option("What's the weather in San Francisco?"))
      ])
    )
  ],
  model: "gpt-4",
  temperature: option(0.5f),
  tools: option(@[testTool]),
  tool_choice: option(% "auto")
)
output.add toolsReq.toMarkdown() & "\n\n"

# Test request with response format
output.add "## CreateChatCompletionReq with Response Format\n\n"
let formatReq = CreateChatCompletionReq(
  messages: @[
    Message(
      role: "user",
      content: option(@[
        MessageContentPart(`type`: "text", text: option("Give me weather data as JSON"))
      ])
    )
  ],
  model: "gpt-4",
  response_format: option(testResponseFormat),
  seed: option(12345)
)
output.add formatReq.toMarkdown() & "\n\n"

# Test request with image content
output.add "## CreateChatCompletionReq with Image Content\n\n"
let imageReq = CreateChatCompletionReq(
  messages: @[
    Message(
      role: "user",
      content: option(@[
        MessageContentPart(`type`: "text", text: option("What do you see in this image?")),
        MessageContentPart(
          `type`: "image_url", 
          image_url: option(ImageUrlPart(url: "https://example.com/image.jpg", detail: option("high")))
        )
      ])
    )
  ],
  model: "gpt-4-vision-preview"
)
output.add imageReq.toMarkdown() & "\n\n"

# Test request with all optional parameters
output.add "## CreateChatCompletionReq with All Parameters\n\n"
let fullReq = CreateChatCompletionReq(
  messages: @[
    Message(
      role: "system",
      content: option(@[
        MessageContentPart(`type`: "text", text: option("You are a helpful assistant."))
      ])
    ),
    Message(
      role: "user",
      name: option("alice"),
      content: option(@[
        MessageContentPart(`type`: "text", text: option("Hello!"))
      ])
    )
  ],
  model: "gpt-4",
  frequency_penalty: option(0.1f),
  logit_bias: option({"50256": 1.0f}.toTable),
  logprobs: option(true),
  top_logprobs: option(5),
  max_tokens: option(200),
  n: option(2),
  presence_penalty: option(0.2f),
  temperature: option(0.8f),
  seed: option(42),
  stop: option("END"),
  top_p: option(0.9f),
  user: option("user123")
)
output.add fullReq.toMarkdown() & "\n\n"

# Write out to tests/tmp/test_markdown.txt
const 
  tmpFile = "tests/tmp/test_markdown.txt"
  goldFile = "tests/gold/test_markdown.txt"

# Create tmp directory if it doesn't exist
createDir(tmpFile.parentDir)
writeFile(tmpFile, output)

# Update gold file if flag is set
if updateGold:
  createDir(goldFile.parentDir)
  writeFile(goldFile, output)
  echo "✅ Updated gold file: ", goldFile
  quit(0)

# Now compare with gold file
if not fileExists(goldFile):
  echo "Gold file doesn't exist: ", goldFile
  echo "Run with -u or --update-gold to create it"
  quit(1)

let
  tmpContent = readFile(tmpFile)
  goldContent = readFile(goldFile)

if tmpContent == goldContent:
  echo "✅ Test passed: Output matches gold file"
else:
  echo "❌ Test failed: Output differs from gold file"
  echo "--- Diff ---"
  
  # Create a simple diff
  let
    tmpLines = tmpContent.splitLines()
    goldLines = goldContent.splitLines()
    maxLines = max(tmpLines.len, goldLines.len)
  
  for i in 0..<maxLines:
    if i >= tmpLines.len:
      echo &"Line {i+1}: [missing] | {goldLines[i]}"
    elif i >= goldLines.len:
      echo &"Line {i+1}: {tmpLines[i]} | [missing]"
    elif tmpLines[i] != goldLines[i]:
      echo &"Line {i+1}: {tmpLines[i]} | {goldLines[i]}"
  
  echo "\nRun with -u or --update-gold to update the gold file"