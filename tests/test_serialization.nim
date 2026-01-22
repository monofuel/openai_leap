import openai_leap, jsony, std/[unittest, options, json]

# Test serialization / deserialization of requests according to the API

proc validateJsonStrings*(json1: string, json2: string) =
  ## Compare two json strings for equivelancy
  ## hunt down those pesky nulls or other differences
  let
    parsed1 = fromJson(json1)
    parsed2 = fromJson(json2)
  
  if parsed1 != parsed2:
    echo "json1: \n", parsed1.pretty
    echo ""
    echo "json2: \n", parsed2.pretty
    echo ""
    assert false



suite "serialization":
  suite "requests":
    test "user1":
      let str = """
{
  "model": "chatgpt-4",
  "messages": [
    {
      "role": "system",
      "content": [
        {
          "type": "text",
          "text": "You are a helpful assistant."
        }
      ]
    },
    {
      "role": "user",
      "content": [
        {
          "type": "text",
          "text": "Hello!"
        }
      ]
    }
  ]
}
"""
      let req = fromJson(str, CreateChatCompletionReq)
      assert req.model == "chatgpt-4"
      assert req.messages.len == 2
      let jsonStr = toJson(req)
      echo jsonStr
      validateJsonStrings(str, jsonStr)

    test "optional fields omitted":
      let req = CreateChatCompletionReq(
        model: "gpt-4o-mini",
        messages: @[
          Message(
            role: "user",
            content: option(@[
              MessageContentPart(`type`: "text", text: option("Hello!"))
            ])
          )
        ]
      )

      let jsonNode = parseJson(toJson(req))
      let messageNode = jsonNode["messages"][0]
      let contentNode = messageNode["content"][0]

      check not jsonNode.hasKey("temperature")
      check not jsonNode.hasKey("stream")
      check not jsonNode.hasKey("tools")
      check not jsonNode.hasKey("tool_choice")
      check not messageNode.hasKey("name")
      check not messageNode.hasKey("tool_calls")
      check not messageNode.hasKey("tool_call_id")
      check not contentNode.hasKey("image_url")

    test "optional fields present when set":
      let req = CreateChatCompletionReq(
        model: "gpt-4o-mini",
        messages: @[
          Message(
            role: "user",
            content: option(@[
              MessageContentPart(`type`: "text", text: option("Hello!"))
            ])
          )
        ],
        temperature: option(0.5'f32),
        stream: option(false),
        user: option("test-user")
      )

      let jsonNode = parseJson(toJson(req))
      check jsonNode.hasKey("temperature")
      check jsonNode.hasKey("stream")
      check jsonNode.hasKey("user")

    test "embedding optional fields omitted":
      let req = CreateEmbeddingReq(
        input: "hello",
        model: "text-embedding-3-small"
      )

      let jsonNode = parseJson(toJson(req))
      check not jsonNode.hasKey("encoding_format")
      check not jsonNode.hasKey("dimensions")
      check not jsonNode.hasKey("user")
