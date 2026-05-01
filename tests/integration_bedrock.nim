import
  std/[json, options, os, strutils, times, unittest],
  openai_leap

const
  BedrockModel = "us.anthropic.claude-opus-4-6-v1"
  BedrockRegion = "us-east-1"


proc requireAwsProfile(): string =
  result = getEnv("AWS_PROFILE").strip()
  if result.len == 0:
    echo "Skipping: AWS_PROFILE not set."
    quit(0)


proc makeTempDir(prefix: string): string =
  result = getTempDir() / (prefix & "_" & $epochTime().int64)
  createDir(result)


suite "legacy bedrock live messages":
  let profile = requireAwsProfile()
  let config = BedrockConfig(region: BedrockRegion, profile: profile)
  let api = newOpenAiApi(apiKey = "bedrock-sigv4")

  test "claude responds (non-streaming)":
    let req = CreateMessageReq()
    req.model = BedrockModel
    req.max_tokens = 256
    req.messages = @[
      AnthropicMessage(
        role: "user",
        content: % "Reply with exactly: bedrock-live-ok"
      )
    ]
    let resp = createBedrockMessage(api, config, req)
    let text = messageText(resp)

    check resp.model.len > 0
    check text.len > 0
    check "bedrock-live-ok" in text.toLowerAscii()

  test "claude streams":
    let req = CreateMessageReq()
    req.model = BedrockModel
    req.max_tokens = 256
    req.messages = @[
      AnthropicMessage(
        role: "user",
        content: % "Reply with exactly: stream-ok"
      )
    ]
    let stream = streamBedrockMessage(api, config, req)
    var fullText = ""
    var chunkCount = 0

    while true:
      let eventOpt = nextBedrockMessageEvent(stream)
      if eventOpt.isNone:
        break
      let event = eventOpt.get()
      if event.hasKey("type") and event["type"].getStr == "content_block_delta":
        if event.hasKey("delta") and event["delta"].hasKey("text"):
          fullText.add(event["delta"]["text"].getStr)
          chunkCount.inc

    check fullText.len > 0
    check "stream-ok" in fullText.toLowerAscii()
    check chunkCount > 0

  test "claude uses tools":
    let dirPath = makeTempDir("openai_leap_int_bedrock_tools")
    defer: removeDir(dirPath)
    let filePath = dirPath / "secret.txt"
    writeFile(filePath, "answer=bedrock-tool-42\n")

    var tools = newResponseToolsTable()
    let readFileFn = ToolFunction(
      name: "read_file",
      description: option("Read the contents of a file at the given path."),
      parameters: option(%*{
        "type": "object",
        "properties": {
          "path": {"type": "string", "description": "File path to read"}
        },
        "required": ["path"]
      })
    )
    tools.register("read_file", readFileFn, proc(args: JsonNode): string =
      let path = args["path"].getStr
      try:
        result = readFile(path)
      except IOError:
        result = "Error: could not read file at " & path
    )

    var req = CreateMessageReq()
    req.model = BedrockModel
    req.max_tokens = 1024
    req.messages = @[
      AnthropicMessage(
        role: "user",
        content: % ("Use the read_file tool to read the file at '" & filePath &
          "' and tell me the value of 'answer'.")
      )
    ]
    let resp = createBedrockMessageWithTools(api, config, req, tools)
    let text = messageText(resp)

    check "bedrock-tool-42" in text

  api.close()
