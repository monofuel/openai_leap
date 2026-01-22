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

  flights["JFK-LAX"] = %* {"departure": "08:00 AM", "arrival": "11:30 AM", "duration": "5h 30m"}
  flights["LAX-JFK"] = %* {"departure": "02:00 PM", "arrival": "10:30 PM", "duration": "5h 30m"}
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
  var openai: OpenAiApi

  setup:
    openai = newOpenAiApi(BaseUrl)
  teardown:
    openai.close()

  suite "models":
    test "get":
      let model = openAI.getModel(TestModel)
      echo toJson(model)

  suite "flight times":
    test "getFlightTimes":
      echo getFlightTimes("JFK", "LAX")

    test "tool call queries":
      var messages = @[
        Message(
          role: "user",
          content:
            option(@[MessageContentPart(`type`: "text", text: option(
             "What is the flight time from New York (JFK) to Los Angeles (LAX)?"
            ))])
        )
      ]

      let firstRequest = CreateChatCompletionReq(
        model: TestModel,
        messages: messages,
        tools: option(@[
          Tool(
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

      let toolMsg = toolResp.choices[0].message.get

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
      assert toolFuncArgs["departure"].getStr == "JFK"
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

      let req = CreateChatCompletionReq(
          model: TestModel,
          messages: messages,
        )
      let finalResponse = openai.createChatCompletion(req)
      echo finalResponse.choices[0].message.get.content

    test "automated tool calls with ToolsTable":
      # Tool implementations
      proc addNumbers(args: JsonNode): string =
        let a = args["a"].getInt()
        let b = args["b"].getInt()
        return $(a + b)

      proc getFlightTimesTool(args: JsonNode): string =
        let departure = args["departure"].getStr()
        let arrival = args["arrival"].getStr()
        return getFlightTimes(departure, arrival)

      # Setup tools
      var tools = newToolsTable()
      tools.register("add_numbers",
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
        addNumbers
      )
      tools.register("get_flight_times",
        ToolFunction(
          name: "get_flight_times",
          description: option("Get flight times between two cities"),
          parameters: option(%*{
            "type": "object",
            "properties": {
              "departure": {"type": "string", "description": "Departure city code"},
              "arrival": {"type": "string", "description": "Arrival city code"}
            },
            "required": ["departure", "arrival"]
          })
        ),
        getFlightTimesTool
      )
      
      # Create request asking for both math and flight info
      let req = CreateChatCompletionReq(
        model: TestModel,
        messages: @[
          Message(
            role: "user",
            content: option(@[
              MessageContentPart(`type`: "text", text: option(
                "What's 15 + 27, and what's the flight time from JFK to LAX?"
              ))
            ])
          )
        ]
      )
      
      # Track conversation progress
      var conversationHistory: seq[(CreateChatCompletionReq, CreateChatCompletionResp)] = @[]
      
      # Execute with automated tool handling
      let resp = openai.createChatCompletionWithTools(req, tools, proc(req: CreateChatCompletionReq, resp: CreateChatCompletionResp) =
        conversationHistory.add((req, resp))
        echo "Conversation step ", conversationHistory.len, " - Messages: ", req.messages.len
      )
      
      # Verify conversation was extended with tool calls
      echo "Conversation expanded from 1 to ", conversationHistory[^1][0].messages.len, " messages"
      check conversationHistory[^1][0].messages.len > 1
      
      # Verify expected tools were called with correct arguments
      var addNumbersCalled = false
      var flightTimesCalled = false
      var toolResponseCount = 0
      
      for msg in conversationHistory[^1][0].messages:
        case msg.role:
        of "assistant":
          if msg.tool_calls.isSome:
            for call in msg.tool_calls.get:
              case call.function.name:
              of "add_numbers":
                addNumbersCalled = true
                let args = parseJson(call.function.arguments)
                check args["a"].getInt == 15
                check args["b"].getInt == 27
              of "get_flight_times":
                flightTimesCalled = true
                let args = parseJson(call.function.arguments)
                check args["departure"].getStr == "JFK"
                check args["arrival"].getStr == "LAX"
        of "tool":
          inc toolResponseCount
        else:
          discard
      
      # Assert all expected tools were used
      check addNumbersCalled
      check flightTimesCalled  
      check toolResponseCount >= 2
      
      # Verify final response content
      let finalContent = resp.choices[0].message.get.content
      check finalContent.len > 0
      check "42" in finalContent  # 15 + 27 = 42
      
      echo "Final response: ", finalContent

    test "sequential tool calls with dependencies":
      # Tool implementations that depend on each other
      proc getPersonLocation(args: JsonNode): string =
        let person = args["person"].getStr()
        case person.toLowerAscii():
        of "alice": return "San Francisco, CA"
        of "bob": return "New York, NY" 
        of "charlie": return "Miami, FL"
        of "diana": return "Seattle, WA"
        else: return "Unknown location"
      
      proc getWeatherForLocation(args: JsonNode): string =
        let location = args["location"].getStr()
        case location.toLowerAscii():
        of "san francisco, ca": return "foggy, 60°F"
        of "new york, ny": return "sunny, 75°F"
        of "miami, fl": return "hot and humid, 85°F"
        of "seattle, wa": return "rainy, 55°F" 
        else: return "weather unavailable"
      
      proc recommendActivity(args: JsonNode): string =
        let weather = args["weather"].getStr()
        case weather.toLowerAscii():
        of "foggy, 60°f": return "Visit a museum or enjoy indoor activities"
        of "sunny, 75°f": return "Perfect for a walk in Central Park"
        of "hot and humid, 85°f": return "Go to the beach or stay in AC"
        of "rainy, 55°f": return "Great day for coffee shops and bookstores"
        else: return "Enjoy your day!"

      proc toolOutputForCall(name: string, args: JsonNode): string =
        case name
        of "get_person_location":
          return getPersonLocation(args)
        of "get_weather_for_location":
          return getWeatherForLocation(args)
        of "recommend_activity":
          return recommendActivity(args)
        else:
          return ""

      # Setup sequential tools
      var tools = newToolsTable()
      tools.register("get_person_location",
        ToolFunction(
          name: "get_person_location",
          description: option("Get the current location of a person"),
          parameters: option(%*{
            "type": "object",
            "properties": {
              "person": {"type": "string", "description": "Name of the person"}
            },
            "required": ["person"]
          })
        ),
        getPersonLocation
      )
      
      tools.register("get_weather_for_location", 
        ToolFunction(
          name: "get_weather_for_location",
          description: option("Get current weather for a specific location"),
          parameters: option(%*{
            "type": "object", 
            "properties": {
              "location": {"type": "string", "description": "City and state/country"}
            },
            "required": ["location"]
          })
        ),
        getWeatherForLocation
      )
      
      tools.register("recommend_activity",
        ToolFunction(
          name: "recommend_activity", 
          description: option("Recommend an activity based on weather conditions"),
          parameters: option(%*{
            "type": "object",
            "properties": {
              "weather": {"type": "string", "description": "Current weather description"}
            },
            "required": ["weather"]
          })
        ),
        recommendActivity
      )
      
      # Create request that requires sequential tool usage
      let req = CreateChatCompletionReq(
        model: TestModel,
        temperature: option(0.0'f32),
        messages: @[
          Message(
            role: "system",
            content: option(@[
              MessageContentPart(`type`: "text", text: option(
                "You are a helpful assistant. Use tools in this exact order: get_person_location, then get_weather_for_location, then recommend_activity. Do not answer until all tool calls complete. After that, summarize the tool outputs."
              ))
            ])
          ),
          Message(
            role: "user",
            content: option(@[
              MessageContentPart(`type`: "text", text: option(
                "I want to know what Alice should do today. Can you find out where she is, check the weather there, and recommend an activity?"
              ))
            ])
          )
        ]
      )
      
      # Track conversation to verify sequential execution
      var conversationHistory: seq[(CreateChatCompletionReq, CreateChatCompletionResp)] = @[]
      
      # Execute with automated tool handling
      let resp = openai.createChatCompletionWithTools(req, tools, proc(req: CreateChatCompletionReq, resp: CreateChatCompletionResp) =
        conversationHistory.add((req, resp))
        echo "Sequential step ", conversationHistory.len, " - Messages: ", req.messages.len
        
        # Log tool calls for debugging
        let lastMsg = req.messages[^1]
        if lastMsg.role == "assistant" and lastMsg.tool_calls.isSome:
          for call in lastMsg.tool_calls.get:
            echo "  Tool called: ", call.function.name, " with args: ", call.function.arguments
      )
      
      # Verify all three tools were called in sequence
      var locationCalled = false
      var weatherCalled = false  
      var activityCalled = false
      var toolCallOrder: seq[string] = @[]
      
      for (stepReq, stepResp) in conversationHistory:
        for msg in stepReq.messages:
          if msg.role == "assistant" and msg.tool_calls.isSome:
            for call in msg.tool_calls.get:
              toolCallOrder.add(call.function.name)
              case call.function.name:
              of "get_person_location":
                locationCalled = true
                let args = parseJson(call.function.arguments) 
                check args["person"].getStr.toLowerAscii() == "alice"
              of "get_weather_for_location":
                weatherCalled = true
                let args = parseJson(call.function.arguments)
                check "san francisco" in args["location"].getStr.toLowerAscii()
              of "recommend_activity":
                activityCalled = true
                let args = parseJson(call.function.arguments)
                check "foggy" in args["weather"].getStr.toLowerAscii()
      
      # Verify sequential execution occurred
      check locationCalled
      check weatherCalled
      check activityCalled
      check toolCallOrder.len >= 3
      
      # Verify logical order: location → weather → activity
      let locationIdx = toolCallOrder.find("get_person_location")
      let weatherIdx = toolCallOrder.find("get_weather_for_location") 
      let activityIdx = toolCallOrder.find("recommend_activity")
      
      check locationIdx >= 0
      check weatherIdx >= 0
      check activityIdx >= 0
      check locationIdx < weatherIdx  # location called before weather
      check weatherIdx < activityIdx  # weather called before activity

      # Verify tool outputs are threaded into the next request as tool messages
      for i in 0..<conversationHistory.len:
        let (_, stepResp) = conversationHistory[i]
        if stepResp.choices.len == 0 or stepResp.choices[0].message.isNone:
          continue
        let msg = stepResp.choices[0].message.get
        if msg.tool_calls.isNone:
          continue
        if i + 1 >= conversationHistory.len:
          continue
        let nextReq = conversationHistory[i + 1][0]
        for call in msg.tool_calls.get:
          let args = parseJson(call.function.arguments)
          let expectedOutput = toolOutputForCall(call.function.name, args)
          var foundToolMessage = false
          for toolMsg in nextReq.messages:
            if toolMsg.role == "tool" and toolMsg.tool_call_id.isSome and toolMsg.tool_call_id.get == call.id:
              foundToolMessage = true
              check toolMsg.content.isSome
              let parts = toolMsg.content.get
              check parts.len > 0
              check parts[0].text.isSome
              check parts[0].text.get == expectedOutput
          check foundToolMessage

      let finalContent = resp.choices[0].message.get.content
      check finalContent.len > 0

      echo "Sequential tool chain completed successfully"
      echo "Tool call order: ", toolCallOrder
      echo "Final response: ", finalContent
