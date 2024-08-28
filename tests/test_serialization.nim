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
