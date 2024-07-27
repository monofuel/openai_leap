# test openAI function calling interface
# https://platform.openai.com/docs/guides/function-calling

import
  std/[unittest, options, json, tables, strutils],
  openai_leap, jsony

# Requires a model that supports function calling
const
  TestModel = "gpt-4o"
  BaseUrl = "https://api.openai.com/v1"

proc getFlightTimes(departure: string, arrival: string): string =
  var flights = initTable[string, JsonNode]()

  flights["NYC-LAX"] = %* {"departure": "08:00 AM", "arrival": "11:30 AM", "duration": "5h 30m"}
  flights["LAX-NYC"] = %* {"departure": "02:00 PM", "arrival": "10:30 PM", "duration": "5h 30m"}
  flights["LHR-JFK"] = %* {"departure": "10:00 AM", "arrival": "01:00 PM", "duration": "8h 00m"}
  flights["JFK-LHR"] = %* {"departure": "09:00 PM", "arrival": "09:00 AM", "duration": "7h 00m"}
  flights["CDG-DXB"] = %* {"departure": "11:00 AM", "arrival": "08:00 PM", "duration": "6h 00m"}
  flights["DXB-CDG"] = %* {"departure": "03:00 AM", "arrival": "07:30 AM", "duration": "7h 30m"}

  let key = (departure & "-" & arrival).toUpperAscii()
  if flights.contains(key):
    return $flights[key]
  else:
    raise newException(ValueError, "No flight found for " & key)

suite "openai tools":
  var openai: OpenAIAPI

  setup:
    openai = newOpenAIAPI(BaseUrl)
  teardown:
    openai.close()

  suite "models":
    test "get":
      let model = openAI.getModel(TestModel)
      echo toJson(model)

  suite "flight times":
    test "getFlightTimes":
      echo getFlightTimes("NYC", "LAX")

    test "tool call queries":
      var messages = @[
        Message(
          role: "user",
          content: 
            option(@[MessageContentPart(`type`: "text", text: option(
             "What is the flight time from New York (NYC) to Los Angeles (LAX)?"
            ))])
        )
      ]

      let firstRequest = CreateChatCompletionReq(
        model: TestModel,
        messages: messages,
        tools: option(@[
          ToolCall(
            `type`: "function",
            function: ToolFunction(
              name: "get_flight_times",
              description: option("Get the flight times between two cities"),
              parameters: option(%* {
                "type": "object",
                "properties": {
                    "departure": {
                      "type": "string",
                      "description": "The departure city (airport code)"
                    },
                    "arrival": {
                      "type": "string",
                      "description": "The arrival city (airport code)"
                    }
                  },
                "required": ["departure", "arrival"]
                }
            ))
          )
        ]),
        toolChoice: option(% "auto")
      )

      let toolResp = openai.createChatCompletion(firstRequest)

      let toolMsg = toolResp.choices[0].message

      messages.add(Message(
        role: toolMsg.role,
        content: option(
          @[MessageContentPart(`type`: "text", text: option(
            toolMsg.content
          ))]
        ),
        tool_calls: toolMsg.tool_calls
      ))

      assert toolMsg.role == "assistant"
      assert toolMsg.tool_calls.isSome
      assert toolMsg.tool_calls.get.len == 1
      let toolFunc = toolMsg.tool_calls.get[0].function
      assert toolFunc.name == "get_flight_times"
      let toolFuncArgs = fromJson(toolFunc.arguments)
      assert toolFuncArgs["departure"].getStr == "NYC"
      assert toolFuncArgs["arrival"].getStr == "LAX"

      let toolResult = getFlightTimes(toolFuncArgs["departure"].getStr, toolFuncArgs["arrival"].getStr)
      messages.add(Message(
        role: "tool",
        content: option(
          @[MessageContentPart(`type`: "text", text: option(
            toolResult
          ))]
          ),
        tool_call_id: option(toolMsg.tool_calls.get[0].id)
      ))
      echo toJson(messages)

      let finalResponse = openai.createChatCompletion(
        CreateChatCompletionReq(
          model: TestModel,
          messages: messages,
        )
      )
      echo finalResponse.choices[0].message.content