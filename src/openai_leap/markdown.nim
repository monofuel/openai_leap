import
  std/[json, options, strformat, strutils, tables],
  openai_leap/common

proc toMarkdown*(req: CreateChatCompletionReq): string =
  ## Serialize a create chat completion request into markdown.
  result = "# Chat Completion Request\n\n"

  # Basic settings
  result &= "## Request Settings\n\n"
  result &= &"- **Model**: {req.model}\n"

  if req.temperature.isSome:
    result &= &"- **Temperature**: {req.temperature.get}\n"
  if req.max_tokens.isSome:
    result &= &"- **Max Tokens**: {req.max_tokens.get}\n"
  if req.top_p.isSome:
    result &= &"- **Top P**: {req.top_p.get}\n"
  if req.frequency_penalty.isSome:
    result &= &"- **Frequency Penalty**: {req.frequency_penalty.get}\n"
  if req.presence_penalty.isSome:
    result &= &"- **Presence Penalty**: {req.presence_penalty.get}\n"
  if req.n.isSome:
    result &= &"- **N (Choices)**: {req.n.get}\n"
  if req.seed.isSome:
    result &= &"- **Seed**: {req.seed.get}\n"
  if req.stop.isSome:
    result &= &"- **Stop**: {req.stop.get}\n"
  if req.stream.isSome:
    result &= &"- **Stream**: {req.stream.get}\n"
  if req.user.isSome:
    result &= &"- **User**: {req.user.get}\n"

  # Response format
  if req.response_format.isSome:
    result &= &"- **Response Format**: {req.response_format.get.`type`}\n"
    if req.response_format.get.json_schema.isSome:
      result &= "- **JSON Schema**: Available\n"

  # Advanced settings
  if req.logprobs.isSome:
    result &= &"- **Log Probs**: {req.logprobs.get}\n"
  if req.top_logprobs.isSome:
    result &= &"- **Top Log Probs**: {req.top_logprobs.get}\n"
  if req.logit_bias.isSome and req.logit_bias.get.len > 0:
    result &= &"- **Logit Bias**: {req.logit_bias.get.len} entries\n"

  result &= "\n"

  # Messages
  result &= "## Messages\n\n"
  for i, msg in req.messages:
    result &= &"### Message {i + 1} ({msg.role})\n\n"

    if msg.name.isSome:
      result &= &"- **Name**: {msg.name.get}\n"

    if msg.tool_call_id.isSome:
      result &= &"- **Tool Call ID**: {msg.tool_call_id.get}\n"

    if msg.content.isSome:
      result &= "- **Content**:\n\n"
      for part in msg.content.get:
        case part.`type`:
        of "text":
          if part.text.isSome:
            result &= "```\n" & part.text.get & "\n```\n\n"
        of "image_url":
          if part.image_url.isSome:
            result &= &"**Image URL**: {part.image_url.get.url}\n"
            if part.image_url.get.detail.isSome:
              result &= &"**Detail Level**: {part.image_url.get.detail.get}\n"
            result &= "\n"
        else:
          result &= &"**Unknown content type**: {part.`type`}\n\n"

    if msg.tool_calls.isSome:
      result &= "- **Tool Calls**:\n"
      for tool_call in msg.tool_calls.get:
        result &= &"  - **ID**: {tool_call.id}\n"
        result &= &"  - **Type**: {tool_call.`type`}\n"
        result &= &"  - **Function**: {tool_call.function.name}\n"
        result &= &"  - **Arguments**: `{tool_call.function.arguments}`\n"

    result &= "\n"

  # Tools
  if req.tools.isSome and req.tools.get.len > 0:
    result &= "## Available Tools\n\n"
    for i, tool in req.tools.get:
      result &= &"### Tool {i + 1}: {tool.function.name}\n\n"
      result &= &"- **Type**: {tool.`type`}\n"
      if tool.function.description.isSome:
        result &= &"- **Description**: {tool.function.description.get}\n"
      if tool.function.parameters.isSome:
        result &= "- **Parameters**:\n```json\n" & $tool.function.parameters.get & "\n```\n"
      result &= "\n"

    # Tool choice
    if req.tool_choice.isSome:
      result &= "## Tool Choice\n\n"
      result &= "```json\n" & $req.tool_choice.get & "\n```\n\n"

proc toMarkdown*(resp: CreateChatCompletionResp): string =
  ## Serialize a create chat completion response into markdown.
  result = "# Chat Completion Response\n\n"

  # Basic metadata
  result &= "## Response Details\n\n"
  result &= &"- **ID**: {resp.id}\n"
  result &= &"- **Model**: {resp.model}\n"
  result &= &"- **Created**: {resp.created}\n"
  result &= &"- **Object**: {resp.`object`}\n"
  result &= &"- **System Fingerprint**: {resp.system_fingerprint}\n\n"

  # Choices/Messages
  result &= "## Response Choices\n\n"
  for i, choice in resp.choices:
    result &= &"### Choice {choice.index}\n\n"
    result &= &"- **Finish Reason**: {choice.finish_reason}\n"

    if choice.message.isSome:
      let msg = choice.message.get
      result &= &"- **Role**: {msg.role}\n"
      if msg.content != "":
        result &= "- **Content**:\n\n"
        result &= &"```\n{msg.content}\n```\n\n"

      if msg.name.isSome:
        result &= &"- **Name**: {msg.name.get}\n"

      if msg.refusal.isSome:
        result &= &"- **Refusal**: {msg.refusal.get}\n"

      if msg.tool_calls.isSome and msg.tool_calls.get.len > 0:
        result &= "- **Tool Calls**:\n"
        for tool_call in msg.tool_calls.get:
          result &= &"  - **ID**: {tool_call.id}\n"
          result &= &"  - **Type**: {tool_call.`type`}\n"
          result &= &"  - **Function**: {tool_call.function.name}\n"
          result &= &"  - **Arguments**: `{tool_call.function.arguments}`\n"

    if choice.delta.isSome:
      let delta = choice.delta.get
      result &= "- **Delta**:\n"
      result &= &"  - **Role**: {delta.role}\n"
      if delta.content != "":
        result &= &"  - **Content**: {delta.content}\n"

    if choice.log_probs.isSome:
      result &= "- **Log Probs**: Available\n"

    result &= "\n"

  # Usage statistics
  if resp.usage != nil:
    result &= "## Usage Statistics\n\n"
    result &= &"- **Prompt Tokens**: {resp.usage.prompt_tokens}\n"
    result &= &"- **Total Tokens**: {resp.usage.total_tokens}\n"
    if resp.usage.total_tokens > 0 and resp.usage.prompt_tokens > 0:
      let completion_tokens = resp.usage.total_tokens - resp.usage.prompt_tokens
      result &= &"- **Completion Tokens**: {completion_tokens}\n"

proc toMarkdown*(req: CreateChatCompletionReq, resp: CreateChatCompletionResp): string =
  ## Serialize both a create chat completion request and response into markdown.
  result = "# Chat Completion Exchange\n\n"

  # Add request section
  result &= "## Request\n\n"
  let reqMarkdown = req.toMarkdown()
  # Remove the main title from request markdown since we have our own
  var reqLines = reqMarkdown.splitLines()
  if reqLines.len > 0 and reqLines[0].startsWith("# "):
    reqLines = reqLines[1..^1]
    # Also remove empty line after title if present
    if reqLines.len > 0 and reqLines[0].strip() == "":
      reqLines = reqLines[1..^1]
  result &= reqLines.join("\n")

  result &= "\n\n---\n\n"

  # Add response section
  result &= "## Response\n\n"
  let respMarkdown = resp.toMarkdown()
  # Remove the main title from response markdown since we have our own
  var respLines = respMarkdown.splitLines()
  if respLines.len > 0 and respLines[0].startsWith("# "):
    respLines = respLines[1..^1]
    # Also remove empty line after title if present
    if respLines.len > 0 and respLines[0].strip() == "":
      respLines = respLines[1..^1]
  result &= respLines.join("\n")

proc toCreateChatCompletionReq*(markdown: string): CreateChatCompletionReq =
  ## Deserialize a create chat completion request from markdown.
  result = CreateChatCompletionReq()

  let lines = markdown.splitLines()
  var i = 0

  # Helper proc to find next section
  proc findNextSection(startIdx: int, sectionName: string): int =
    for j in startIdx..<lines.len:
      if lines[j].startsWith("## " & sectionName):
        return j
    return -1

  # Helper proc to extract value from bullet point
  proc extractValue(line: string, key: string): string =
    let prefix = "- **" & key & "**: "
    if line.startsWith(prefix):
      return line[prefix.len..^1]
    return ""

  # Helper proc to parse float from line
  proc extractFloat(line: string, key: string): float32 =
    let val = extractValue(line, key)
    if val != "":
      try:
        return parseFloat(val).float32
      except:
        return 0.0f
    return 0.0f

  # Helper proc to parse int from line
  proc extractInt(line: string, key: string): int =
    let val = extractValue(line, key)
    if val != "":
      try:
        return parseInt(val)
      except:
        return 0
    return 0

  # Helper proc to parse bool from line
  proc extractBool(line: string, key: string): bool =
    let val = extractValue(line, key)
    return val == "true"

  # Parse Request Settings section
  let settingsIdx = findNextSection(0, "Request Settings")
  if settingsIdx >= 0:
    i = settingsIdx + 1
    while i < lines.len and not lines[i].startsWith("## "):
      let line = lines[i].strip()
      if line.startsWith("- **"):
        let model = extractValue(line, "Model")
        if model != "": result.model = model

        let temp = extractFloat(line, "Temperature")
        if temp > 0.0f: result.temperature = option(temp)

        let maxTokens = extractInt(line, "Max Tokens")
        if maxTokens > 0: result.max_tokens = option(maxTokens)

        let topP = extractFloat(line, "Top P")
        if topP > 0.0f: result.top_p = option(topP)

        let freqPenalty = extractFloat(line, "Frequency Penalty")
        if freqPenalty != 0.0f: result.frequency_penalty = option(freqPenalty)

        let presPenalty = extractFloat(line, "Presence Penalty")
        if presPenalty != 0.0f: result.presence_penalty = option(presPenalty)

        let n = extractInt(line, "N (Choices)")
        if n > 0: result.n = option(n)

        let seed = extractInt(line, "Seed")
        if seed > 0: result.seed = option(seed)

        let stop = extractValue(line, "Stop")
        if stop != "": result.stop = option(stop)

        let stream = extractBool(line, "Stream")
        if line.contains("Stream"): result.stream = option(stream)

        let user = extractValue(line, "User")
        if user != "": result.user = option(user)

        let responseFormat = extractValue(line, "Response Format")
        if responseFormat != "":
          var respFmt = ResponseFormatObj()
          respFmt.`type` = responseFormat
          result.response_format = option(respFmt)

        let logprobs = extractBool(line, "Log Probs")
        if line.contains("Log Probs"): result.logprobs = option(logprobs)

        let topLogprobs = extractInt(line, "Top Log Probs")
        if topLogprobs > 0: result.top_logprobs = option(topLogprobs)

      inc i

  # Parse Messages - scan entire document for Message headers
  result.messages = @[]
  i = 0

  while i < lines.len:
    let line = lines[i].strip()

    # Look for message sections
    if line.startsWith("### Message ") and line.contains("(") and line.contains(")"):
      var message = Message()

      # Extract role from "### Message N (role)"
      let roleStart = line.find("(") + 1
      let roleEnd = line.find(")")
      if roleStart > 0 and roleEnd > roleStart:
        message.role = line[roleStart..<roleEnd]

      inc i
      var content = ""
      var inContentBlock = false
      var contentParts: seq[MessageContentPart] = @[]

      # Parse message details
      while i < lines.len:
        let msgLine = lines[i].strip()

        if inContentBlock:
          if msgLine == "```":
            inContentBlock = false
            # Add text content part
            contentParts.add(MessageContentPart(
              `type`: "text",
              text: option(content)
            ))
            content = ""
          else:
            if content != "": content &= "\n"
            content &= lines[i] # preserve original indentation
        # Only exit on section headers when NOT in a content block
        elif not inContentBlock and (lines[i].startsWith("### ") or lines[i].startsWith("## ")):
          break
        elif msgLine.startsWith("- **"):
          let name = extractValue(msgLine, "Name")
          if name != "": message.name = option(name)

          let toolCallId = extractValue(msgLine, "Tool Call ID")
          if toolCallId != "": message.tool_call_id = option(toolCallId)

          if msgLine.startsWith("- **Content**:"):
            # Content follows on next lines in a code block
            inc i
            # Skip empty lines until we find the opening ```
            while i < lines.len and lines[i].strip() == "":
              inc i
            if i < lines.len and lines[i].strip() == "```":
              inContentBlock = true
              content = ""
            else:
              dec i # Back up if we didn't find code block
          elif msgLine.startsWith("- **Tool Calls**:"):
            # Parse tool calls that follow
            inc i
            var toolCalls: seq[ToolResp] = @[]
            while i < lines.len and not lines[i].startsWith("- **") and not lines[i].startsWith("### ") and not lines[i].startsWith("## "):
              let toolLine = lines[i]
              if toolLine.startsWith("  - **ID**: "):
                var toolCall = ToolResp()
                toolCall.id = toolLine[12..^1]

                # Parse the rest of this tool call
                inc i
                if i < lines.len and lines[i].startsWith("  - **Type**: "):
                  toolCall.`type` = lines[i][14..^1]
                inc i
                if i < lines.len and lines[i].startsWith("  - **Function**: "):
                  var funcResp = ToolFunctionResp()
                  funcResp.name = lines[i][18..^1]
                  inc i
                  if i < lines.len and lines[i].startsWith("  - **Arguments**: `") and lines[i].endsWith("`"):
                    let argsLine = lines[i]
                    funcResp.arguments = argsLine[20..^2]
                  toolCall.function = funcResp

                toolCalls.add(toolCall)
              else:
                inc i

            if toolCalls.len > 0:
              message.tool_calls = option(toolCalls)
            dec i # Back up since outer loop will increment
        elif msgLine.startsWith("**Image URL**: "):
          # Parse image content
          let imageUrl = msgLine[15..^1]
          var imagePart = MessageContentPart(`type`: "image_url")
          var imageUrlPart = ImageUrlPart(url: imageUrl)

          # Check next line for detail level
          if i + 1 < lines.len and lines[i + 1].strip().startsWith("**Detail Level**: "):
            inc i
            let detail = lines[i].strip()[18..^1]
            imageUrlPart.detail = option(detail)

          imagePart.image_url = option(imageUrlPart)
          contentParts.add(imagePart)
        elif msgLine == "```" and not inContentBlock:
          inContentBlock = true
          content = ""

        inc i

      # Set message content if we have parts
      if contentParts.len > 0:
        message.content = option(contentParts)

      result.messages.add(message)
      dec i # Back up one since the outer loop will increment

    inc i

  # Parse Available Tools section
  let toolsIdx = findNextSection(0, "Available Tools")
  if toolsIdx >= 0:
    i = toolsIdx + 1
    var tools: seq[Tool] = @[]

    while i < lines.len and not lines[i].startsWith("## "):
      let line = lines[i].strip()

      # Look for tool sections
      if line.startsWith("### Tool ") and line.contains(": "):
        var tool = Tool()
        var toolFunc = ToolFunction()

        # Extract tool name from "### Tool N: name"
        let nameStart = line.find(": ") + 2
        toolFunc.name = line[nameStart..^1]

        inc i
        var inParamsBlock = false
        var paramsJson = ""

        # Parse tool details
        while i < lines.len and not lines[i].startsWith("### ") and not lines[i].startsWith("## "):
          let toolLine = lines[i].strip()

          if inParamsBlock:
            if toolLine == "```":
              inParamsBlock = false
              # Parse the JSON
              try:
                toolFunc.parameters = option(parseJson(paramsJson))
              except:
                discard # ignore JSON parse errors
              paramsJson = ""
            else:
              paramsJson &= lines[i] & "\n"
          elif toolLine.startsWith("- **"):
            let toolType = extractValue(toolLine, "Type")
            if toolType != "": tool.`type` = toolType

            let description = extractValue(toolLine, "Description")
            if description != "": toolFunc.description = option(description)

            if toolLine.startsWith("- **Parameters**:"):
              # Parameters follow in a JSON code block
              inc i
              # Skip empty lines until we find the opening ```
              while i < lines.len and lines[i].strip() == "":
                inc i
              if i < lines.len and lines[i].strip().startsWith("```"):
                inParamsBlock = true
                paramsJson = ""
              else:
                dec i # Back up if we didn't find code block
          elif toolLine.startsWith("```") and toolLine.len > 3:
            # Handle single-line JSON blocks
            let jsonStr = toolLine[3..^3] # Remove ``` from both ends
            try:
              toolFunc.parameters = option(parseJson(jsonStr))
            except:
              discard

          inc i

        tool.function = toolFunc
        tools.add(tool)
        dec i # Back up one since the outer loop will increment

      inc i

    if tools.len > 0:
      result.tools = option(tools)

  # Parse Tool Choice section
  let toolChoiceIdx = findNextSection(0, "Tool Choice")
  if toolChoiceIdx >= 0:
    i = toolChoiceIdx + 1
    var inJsonBlock = false
    var jsonStr = ""

    while i < lines.len and not lines[i].startsWith("## "):
      let line = lines[i].strip()

      if inJsonBlock:
        if line == "```":
          inJsonBlock = false
          # Parse the JSON
          try:
            result.tool_choice = option(parseJson(jsonStr))
          except:
            discard # ignore JSON parse errors
          jsonStr = ""
        else:
          jsonStr &= lines[i] & "\n"
      elif line == "```json":
        inJsonBlock = true
        jsonStr = ""

      inc i

proc toCreateChatCompletionResp*(markdown: string): CreateChatCompletionResp =
  ## Deserialize a create chat completion response from markdown.
  result = CreateChatCompletionResp()

  let lines = markdown.splitLines()
  var i = 0

  # Helper proc to find next section
  proc findNextSection(startIdx: int, sectionName: string): int =
    for j in startIdx..<lines.len:
      if lines[j].startsWith("## " & sectionName):
        return j
    return -1

  # Helper proc to extract value from bullet point
  proc extractValue(line: string, key: string): string =
    let prefix = "- **" & key & "**: "
    if line.startsWith(prefix):
      return line[prefix.len..^1]
    return ""

  # Helper proc to parse integer from line
  proc extractInt(line: string, key: string): int =
    let val = extractValue(line, key)
    if val != "":
      try:
        return parseInt(val)
      except:
        return 0
    return 0

  # Parse Response Details section
  let detailsIdx = findNextSection(0, "Response Details")
  if detailsIdx >= 0:
    i = detailsIdx + 1
    while i < lines.len and not lines[i].startsWith("## "):
      let line = lines[i].strip()
      if line.startsWith("- **"):
        let id = extractValue(line, "ID")
        if id != "": result.id = id

        let model = extractValue(line, "Model")
        if model != "": result.model = model

        let created = extractInt(line, "Created")
        if created > 0: result.created = created

        let obj = extractValue(line, "Object")
        if obj != "": result.`object` = obj

        let fingerprint = extractValue(line, "System Fingerprint")
        if fingerprint != "": result.system_fingerprint = fingerprint

      inc i

  # Parse Response Choices section
  result.choices = @[]
  let choicesIdx = findNextSection(0, "Response Choices")
  if choicesIdx >= 0:
    i = choicesIdx + 1

    while i < lines.len and not lines[i].startsWith("## "):
      let line = lines[i].strip()

      # Look for choice sections
      if line.startsWith("### Choice "):
        var choice = CreateChatMessage()
        let choiceNumStr = line[11..^1] # "### Choice " is 11 chars
        try:
          choice.index = parseInt(choiceNumStr)
        except:
          choice.index = 0

        inc i
        var content = ""
        var inContentBlock = false
        var toolCalls: seq[ToolResp] = @[]
        var message = RespMessage()
        message.role = "assistant" # Default role
        message.content = ""

        # Parse choice details
        while i < lines.len and not lines[i].startsWith("### ") and not lines[i].startsWith("## "):
          let choiceLine = lines[i].strip()

          if inContentBlock:
            if choiceLine == "```":
              inContentBlock = false
              message.content = content
            else:
              if content != "": content &= "\n"
              content &= lines[i] # preserve original indentation in content
          elif choiceLine.startsWith("- **"):
            let finishReason = extractValue(choiceLine, "Finish Reason")
            if finishReason != "": choice.finish_reason = finishReason

            let role = extractValue(choiceLine, "Role")
            if role != "": message.role = role

            let name = extractValue(choiceLine, "Name")
            if name != "": message.name = option(name)

            let refusal = extractValue(choiceLine, "Refusal")
            if refusal != "": message.refusal = option(refusal)

            if choiceLine.startsWith("- **Content**:"):
              # Content follows on next lines in a code block
              inc i
              # Skip empty lines until we find the opening ```
              while i < lines.len and lines[i].strip() == "":
                inc i
              if i < lines.len and lines[i].strip() == "```":
                inContentBlock = true
                content = ""
              else:
                dec i # Back up if we didn't find code block
            elif choiceLine.startsWith("- **Tool Calls**:"):
              # Parse tool calls that follow
              inc i
              toolCalls = @[]
              while i < lines.len and not lines[i].startsWith("- **") and not lines[i].startsWith("### ") and not lines[i].startsWith("## "):
                let toolLine = lines[i] # Don't strip - need indentation to detect structure
                if toolLine.startsWith("  - **ID**: "):
                  var toolCall = ToolResp()
                  toolCall.id = toolLine[12..^1]

                  # Parse the rest of this tool call
                  inc i
                  if i < lines.len and lines[i].startsWith("  - **Type**: "):
                    toolCall.`type` = lines[i][14..^1]
                  inc i
                  if i < lines.len and lines[i].startsWith("  - **Function**: "):
                    var funcResp = ToolFunctionResp()
                    funcResp.name = lines[i][18..^1]
                    inc i
                    if i < lines.len and lines[i].startsWith("  - **Arguments**: `") and lines[i].endsWith("`"):
                      let argsLine = lines[i]
                      funcResp.arguments = argsLine[20..^2] # Remove "  - **Arguments**: `" and trailing "`"
                    toolCall.function = funcResp

                  toolCalls.add(toolCall)
                else:
                  inc i

              if toolCalls.len > 0:
                message.tool_calls = option(toolCalls)
              dec i # Back up since outer loop will increment
          elif choiceLine == "```" and not inContentBlock:
            inContentBlock = true
            content = ""

          inc i

        # Set up the choice - always add the message since we have defaults
        choice.message = option(message)

        result.choices.add(choice)
        dec i # Back up one since the outer loop will increment

      inc i

  # Parse Usage Statistics section
  let usageIdx = findNextSection(0, "Usage Statistics")
  if usageIdx >= 0:
    i = usageIdx + 1
    result.usage = Usage()

    while i < lines.len and not lines[i].startsWith("## "):
      let line = lines[i].strip()
      if line.startsWith("- **"):
        let promptTokens = extractInt(line, "Prompt Tokens")
        if promptTokens > 0: result.usage.prompt_tokens = promptTokens

        let totalTokens = extractInt(line, "Total Tokens")
        if totalTokens > 0: result.usage.total_tokens = totalTokens

      inc i

proc toCreateChatCompletionReqAndResp*(markdown: string): (CreateChatCompletionReq, CreateChatCompletionResp) =
  ## Deserialize a create chat completion request and response from markdown.
  let lines = markdown.splitLines()

  # Find the Request and Response sections
  var requestStartIdx = -1
  var responseStartIdx = -1

  for i, line in lines:
    if line.strip() == "## Request":
      requestStartIdx = i
    elif line.strip() == "## Response":
      responseStartIdx = i

  if requestStartIdx == -1 or responseStartIdx == -1:
    # If we can't find the sections, return empty objects
    return (CreateChatCompletionReq(), CreateChatCompletionResp())

  # Extract request section
  var requestLines: seq[string] = @[]
  var i = requestStartIdx + 1
  while i < responseStartIdx and i < lines.len:
    # Skip the separator line "---"
    if lines[i].strip() != "---":
      requestLines.add(lines[i])
    inc i

  # Extract response section
  var responseLines: seq[string] = @[]
  i = responseStartIdx + 1
  while i < lines.len:
    responseLines.add(lines[i])
    inc i

  # Add back the main titles that our individual parsers expect
  let requestMarkdown = "# Chat Completion Request\n\n" & requestLines.join("\n")
  let responseMarkdown = "# Chat Completion Response\n\n" & responseLines.join("\n")

  # Parse each section
  let req = toCreateChatCompletionReq(requestMarkdown)
  let resp = toCreateChatCompletionResp(responseMarkdown)

  return (req, resp)

proc toMarkdown*(req: CreateResponseReq): string =
  ## Serialize a Responses API request into markdown.
  result = "# Response Request\n\n"

  # Basic settings
  result &= "## Request Settings\n\n"
  result &= &"- **Model**: {req.model}\n"

  if req.instructions.isSome:
    result &= &"- **Instructions**: {req.instructions.get}\n"
  if req.temperature.isSome:
    result &= &"- **Temperature**: {req.temperature.get}\n"
  if req.max_output_tokens.isSome:
    result &= &"- **Max Output Tokens**: {req.max_output_tokens.get}\n"
  if req.top_p.isSome:
    result &= &"- **Top P**: {req.top_p.get}\n"
  if req.stream.isSome:
    result &= &"- **Stream**: {req.stream.get}\n"
  if req.user.isSome:
    result &= &"- **User**: {req.user.get}\n"
  if req.store.isSome:
    result &= &"- **Store**: {req.store.get}\n"
  if req.previous_response_id.isSome:
    result &= &"- **Previous Response ID**: {req.previous_response_id.get}\n"
  if req.max_tool_calls.isSome:
    result &= &"- **Max Tool Calls**: {req.max_tool_calls.get}\n"
  if req.parallel_tool_calls.isSome:
    result &= &"- **Parallel Tool Calls**: {req.parallel_tool_calls.get}\n"
  result &= "\n"

  # Inputs
  if req.input.isSome and req.input.get.len > 0:
    result &= "## Inputs\n\n"
    for i, input in req.input.get:
      result &= &"### Input {i + 1} ({input.`type`})\n\n"
      result &= &"- **Type**: {input.`type`}\n"
      if input.role.isSome:
        result &= &"- **Role**: {input.role.get}\n"
      if input.call_id.isSome:
        result &= &"- **Call ID**: {input.call_id.get}\n"
      if input.output.isSome:
        result &= "- **Output**:\n\n"
        result &= "```\n" & input.output.get & "\n```\n\n"
      if input.content.isSome:
        result &= "- **Content**:\n\n"
        for content in input.content.get:
          case content.`type`
          of "input_text":
            if content.text.isSome:
              result &= "```\n" & content.text.get & "\n```\n\n"
          of "input_image":
            if content.image_url.isSome:
              result &= &"**Image URL**: {content.image_url.get.url}\n"
              if content.image_url.get.detail.isSome:
                result &= &"**Detail Level**: {content.image_url.get.detail.get}\n"
              result &= "\n"
          else:
            result &= &"**Unknown content type**: {content.`type`}\n\n"
      result &= "\n"

  # Tools
  if req.tools.isSome and req.tools.get.len > 0:
    result &= "## Available Tools\n\n"
    for i, tool in req.tools.get:
      result &= &"### Tool {i + 1}: {tool.name}\n\n"
      result &= &"- **Type**: {tool.`type`}\n"
      if tool.description.isSome:
        result &= &"- **Description**: {tool.description.get}\n"
      if tool.parameters.isSome:
        result &= "- **Parameters**:\n```json\n" & $tool.parameters.get & "\n```\n"
      result &= "\n"

  # Tool choice
  if req.tool_choice.isSome:
    result &= "## Tool Choice\n\n"
    result &= "```json\n" & $req.tool_choice.get & "\n```\n\n"

proc toMarkdown*(resp: OpenAiResponse): string =
  ## Serialize a Responses API response into markdown.
  result = "# Response\n\n"

  # Basic metadata
  result &= "## Response Details\n\n"
  result &= &"- **ID**: {resp.id}\n"
  result &= &"- **Model**: {resp.model}\n"
  result &= &"- **Created**: {resp.created_at}\n"
  result &= &"- **Status**: {resp.status}\n"
  result &= &"- **Object**: {resp.`object`}\n"
  if resp.previous_response_id.isSome:
    result &= &"- **Previous Response ID**: {resp.previous_response_id.get}\n"
  result &= "\n"

  # Outputs
  result &= "## Outputs\n\n"
  for i, output in resp.output:
    result &= &"### Output {i + 1} ({output.`type`})\n\n"
    result &= &"- **Type**: {output.`type`}\n"
    if output.role.isSome:
      result &= &"- **Role**: {output.role.get}\n"
    if output.status.isSome:
      result &= &"- **Status**: {output.status.get}\n"
    if output.call_id.isSome:
      result &= &"- **Call ID**: {output.call_id.get}\n"
    if output.name.isSome:
      result &= &"- **Name**: {output.name.get}\n"
    if output.arguments.isSome:
      result &= &"- **Arguments**: `{output.arguments.get}`\n"

    if output.content.isSome:
      result &= "- **Content**:\n\n"
      for content in output.content.get:
        case content.`type`
        of "output_text":
          if content.text.isSome:
            result &= "```\n" & content.text.get & "\n```\n\n"
        of "tool_call":
          if content.tool_call.isSome:
            let toolCall = content.tool_call.get
            result &= "**Tool Call**:\n"
            result &= &"- **ID**: {toolCall.id}\n"
            result &= &"- **Type**: {toolCall.`type`}\n"
            if toolCall.function.isSome:
              let functionInfo = toolCall.function.get
              result &= &"- **Function**: {functionInfo.name}\n"
              result &= &"- **Arguments**: `{functionInfo.arguments}`\n"
            result &= "\n"
        else:
          result &= &"**Unknown content type**: {content.`type`}\n\n"
    result &= "\n"

  # Usage statistics
  if resp.usage.isSome:
    result &= "## Usage Statistics\n\n"
    result &= &"- **Input Tokens**: {resp.usage.get.input_tokens}\n"
    result &= &"- **Output Tokens**: {resp.usage.get.output_tokens}\n"
    result &= &"- **Total Tokens**: {resp.usage.get.total_tokens}\n"

proc toMarkdown*(req: CreateResponseReq, resp: OpenAiResponse): string =
  ## Serialize both a Responses API request and response into markdown.
  result = "# Response Exchange\n\n"

  # Add request section
  result &= "## Request\n\n"
  let reqMarkdown = req.toMarkdown()
  var reqLines = reqMarkdown.splitLines()
  if reqLines.len > 0 and reqLines[0].startsWith("# "):
    reqLines = reqLines[1..^1]
    if reqLines.len > 0 and reqLines[0].strip() == "":
      reqLines = reqLines[1..^1]
  result &= reqLines.join("\n")

  result &= "\n\n---\n\n"

  # Add response section
  result &= "## Response\n\n"
  let respMarkdown = resp.toMarkdown()
  var respLines = respMarkdown.splitLines()
  if respLines.len > 0 and respLines[0].startsWith("# "):
    respLines = respLines[1..^1]
    if respLines.len > 0 and respLines[0].strip() == "":
      respLines = respLines[1..^1]
  result &= respLines.join("\n")

proc toCreateResponseReq*(markdown: string): CreateResponseReq =
  ## Deserialize a Responses API request from markdown.
  result = CreateResponseReq()

  let lines = markdown.splitLines()
  var i = 0

  proc findNextSection(startIdx: int, sectionName: string): int =
    for j in startIdx..<lines.len:
      if lines[j].startsWith("## " & sectionName):
        return j
    return -1

  proc extractValue(line: string, key: string): string =
    let prefix = "- **" & key & "**: "
    if line.startsWith(prefix):
      return line[prefix.len..^1]
    return ""

  proc extractFloat(line: string, key: string): float32 =
    let val = extractValue(line, key)
    if val != "":
      try:
        return parseFloat(val).float32
      except:
        return 0.0f
    return 0.0f

  proc extractInt(line: string, key: string): int =
    let val = extractValue(line, key)
    if val != "":
      try:
        return parseInt(val)
      except:
        return 0
    return 0

  proc extractBool(line: string, key: string): bool =
    let val = extractValue(line, key)
    return val == "true"

  # Parse Request Settings section
  let settingsIdx = findNextSection(0, "Request Settings")
  if settingsIdx >= 0:
    i = settingsIdx + 1
    while i < lines.len and not lines[i].startsWith("## "):
      let line = lines[i].strip()
      if line.startsWith("- **"):
        let model = extractValue(line, "Model")
        if model != "": result.model = model

        let instructions = extractValue(line, "Instructions")
        if instructions != "": result.instructions = option(instructions)

        let temperature = extractFloat(line, "Temperature")
        if temperature != 0.0f: result.temperature = option(temperature)

        let maxOutput = extractInt(line, "Max Output Tokens")
        if maxOutput > 0: result.max_output_tokens = option(maxOutput)

        let topP = extractFloat(line, "Top P")
        if topP != 0.0f: result.top_p = option(topP)

        if extractValue(line, "Stream") != "":
          result.stream = option(extractBool(line, "Stream"))

        let user = extractValue(line, "User")
        if user != "": result.user = option(user)

        if extractValue(line, "Store") != "":
          result.store = option(extractBool(line, "Store"))

        let previousResponseId = extractValue(line, "Previous Response ID")
        if previousResponseId != "":
          result.previous_response_id = option(previousResponseId)

        let maxToolCalls = extractInt(line, "Max Tool Calls")
        if maxToolCalls > 0: result.max_tool_calls = option(maxToolCalls)

        if extractValue(line, "Parallel Tool Calls") != "":
          result.parallel_tool_calls = option(extractBool(line, "Parallel Tool Calls"))

      inc i

  # Parse Inputs section
  var inputs: seq[ResponseInput] = @[]
  let inputsIdx = findNextSection(0, "Inputs")
  if inputsIdx >= 0:
    i = inputsIdx + 1
    while i < lines.len and not lines[i].startsWith("## "):
      let line = lines[i].strip()

      if line.startsWith("### Input "):
        var input = ResponseInput()
        var contents: seq[ResponseInputContent] = @[]
        var inTextBlock = false
        var inOutputBlock = false
        var textBuffer = ""
        var outputBuffer = ""

        inc i
        while i < lines.len and not lines[i].startsWith("### ") and not lines[i].startsWith("## "):
          let inputLine = lines[i].strip()

          if inTextBlock:
            if inputLine == "```":
              inTextBlock = false
              contents.add(ResponseInputContent(`type`: "input_text", text: option(textBuffer)))
              textBuffer = ""
            else:
              if textBuffer != "": textBuffer &= "\n"
              textBuffer &= lines[i]
          elif inOutputBlock:
            if inputLine == "```":
              inOutputBlock = false
              input.output = option(outputBuffer)
              outputBuffer = ""
            else:
              if outputBuffer != "": outputBuffer &= "\n"
              outputBuffer &= lines[i]
          elif inputLine.startsWith("- **Type**: "):
            input.`type` = extractValue(inputLine, "Type")
          elif inputLine.startsWith("- **Role**: "):
            let role = extractValue(inputLine, "Role")
            if role != "": input.role = option(role)
          elif inputLine.startsWith("- **Call ID**: "):
            let callId = extractValue(inputLine, "Call ID")
            if callId != "": input.call_id = option(callId)
          elif inputLine.startsWith("- **Output**:"):
            inc i
            while i < lines.len and lines[i].strip() == "":
              inc i
            if i < lines.len and lines[i].strip() == "```":
              inOutputBlock = true
              outputBuffer = ""
            else:
              dec i
          elif inputLine.startsWith("- **Content**:"):
            inc i
            while i < lines.len and lines[i].strip() == "":
              inc i
            if i < lines.len and lines[i].strip() == "```":
              inTextBlock = true
              textBuffer = ""
            else:
              dec i
          elif inputLine.startsWith("**Image URL**: "):
            let url = inputLine["**Image URL**: ".len..^1]
            var img = ResponseInputImage(url: url)
            let detailLineIdx = i + 1
            if detailLineIdx < lines.len and lines[detailLineIdx].strip().startsWith("**Detail Level**: "):
              let detail = lines[detailLineIdx].strip()["**Detail Level**: ".len..^1]
              img.detail = option(detail)
              inc i
            contents.add(ResponseInputContent(`type`: "input_image", image_url: option(img)))

          inc i

        if contents.len > 0:
          input.content = option(contents)
        inputs.add(input)
        dec i

      inc i

  if inputs.len > 0:
    result.input = option(inputs)

  # Parse Tool Choice section
  let toolChoiceIdx = findNextSection(0, "Tool Choice")
  if toolChoiceIdx >= 0:
    i = toolChoiceIdx + 1
    var inJsonBlock = false
    var jsonStr = ""

    while i < lines.len and not lines[i].startsWith("## "):
      let line = lines[i].strip()
      if inJsonBlock:
        if line == "```":
          inJsonBlock = false
          try:
            result.tool_choice = option(parseJson(jsonStr))
          except:
            discard
          jsonStr = ""
        else:
          jsonStr &= lines[i] & "\n"
      elif line == "```json":
        inJsonBlock = true
        jsonStr = ""
      inc i

proc toOpenAiResponse*(markdown: string): OpenAiResponse =
  ## Deserialize a Responses API response from markdown.
  result = OpenAiResponse()
  result.output = @[]

  let lines = markdown.splitLines()
  var i = 0

  proc findNextSection(startIdx: int, sectionName: string): int =
    for j in startIdx..<lines.len:
      if lines[j].startsWith("## " & sectionName):
        return j
    return -1

  proc extractValue(line: string, key: string): string =
    let prefix = "- **" & key & "**: "
    if line.startsWith(prefix):
      return line[prefix.len..^1]
    return ""

  proc extractInt(line: string, key: string): int =
    let val = extractValue(line, key)
    if val != "":
      try:
        return parseInt(val)
      except:
        return 0
    return 0

  # Parse Response Details section
  let detailsIdx = findNextSection(0, "Response Details")
  if detailsIdx >= 0:
    i = detailsIdx + 1
    while i < lines.len and not lines[i].startsWith("## "):
      let line = lines[i].strip()
      if line.startsWith("- **"):
        let id = extractValue(line, "ID")
        if id != "": result.id = id

        let model = extractValue(line, "Model")
        if model != "": result.model = model

        let created = extractInt(line, "Created")
        if created > 0: result.created_at = created

        let status = extractValue(line, "Status")
        if status != "": result.status = status

        let obj = extractValue(line, "Object")
        if obj != "": result.`object` = obj

        let previousResponseId = extractValue(line, "Previous Response ID")
        if previousResponseId != "": result.previous_response_id = option(previousResponseId)

      inc i

  # Parse Outputs section
  let outputsIdx = findNextSection(0, "Outputs")
  if outputsIdx >= 0:
    i = outputsIdx + 1
    while i < lines.len and not lines[i].startsWith("## "):
      let line = lines[i].strip()

      if line.startsWith("### Output "):
        var output = ResponseOutput()
        if line.contains("(") and line.endsWith(")"):
          let startIdx = line.find("(")
          output.`type` = line[startIdx + 1..^2]

        var contents: seq[ResponseOutputContent] = @[]
        var inTextBlock = false
        var textBuffer = ""
        var inToolCall = false
        var toolCallId = ""
        var toolCallType = ""
        var toolCallFuncName = ""
        var toolCallFuncArgs = ""

        inc i
        while i < lines.len and not lines[i].startsWith("### ") and not lines[i].startsWith("## "):
          let outputLine = lines[i].strip()

          if inTextBlock:
            if outputLine == "```":
              inTextBlock = false
              contents.add(ResponseOutputContent(`type`: "output_text", text: option(textBuffer)))
              textBuffer = ""
            else:
              if textBuffer != "": textBuffer &= "\n"
              textBuffer &= lines[i]
          elif outputLine.startsWith("- **Type**: "):
            output.`type` = extractValue(outputLine, "Type")
          elif outputLine.startsWith("- **Role**: "):
            let role = extractValue(outputLine, "Role")
            if role != "": output.role = option(role)
          elif outputLine.startsWith("- **Status**: "):
            let status = extractValue(outputLine, "Status")
            if status != "": output.status = option(status)
          elif outputLine.startsWith("- **Call ID**: "):
            let callId = extractValue(outputLine, "Call ID")
            if callId != "": output.call_id = option(callId)
          elif outputLine.startsWith("- **Name**: "):
            let name = extractValue(outputLine, "Name")
            if name != "": output.name = option(name)
          elif outputLine.startsWith("- **Arguments**: "):
            let args = extractValue(outputLine, "Arguments").strip(chars = {'`'})
            if args != "": output.arguments = option(args)
          elif outputLine.startsWith("- **Content**:"):
            inc i
            while i < lines.len and lines[i].strip() == "":
              inc i
            if i < lines.len and lines[i].strip() == "```":
              inTextBlock = true
              textBuffer = ""
            else:
              dec i
          elif outputLine.startsWith("**Tool Call**:"):
            inToolCall = true
            toolCallId = ""
            toolCallType = ""
            toolCallFuncName = ""
            toolCallFuncArgs = ""
          elif inToolCall and outputLine.startsWith("- **ID**: "):
            toolCallId = extractValue(outputLine, "ID")
          elif inToolCall and outputLine.startsWith("- **Type**: "):
            toolCallType = extractValue(outputLine, "Type")
          elif inToolCall and outputLine.startsWith("- **Function**: "):
            toolCallFuncName = extractValue(outputLine, "Function")
          elif inToolCall and outputLine.startsWith("- **Arguments**: "):
            toolCallFuncArgs = extractValue(outputLine, "Arguments").strip(chars = {'`'})
          elif inToolCall and outputLine == "":
            var toolCall = ResponseOutputToolCall(id: toolCallId, `type`: toolCallType)
            if toolCallFuncName != "":
              var functionInfo = ToolFunctionResp()
              functionInfo.name = toolCallFuncName
              functionInfo.arguments = toolCallFuncArgs
              toolCall.function = option(functionInfo)
            contents.add(ResponseOutputContent(`type`: "tool_call", tool_call: option(toolCall)))
            inToolCall = false

          inc i

        if inToolCall:
          var toolCall = ResponseOutputToolCall(id: toolCallId, `type`: toolCallType)
          if toolCallFuncName != "":
            var functionInfo = ToolFunctionResp()
            functionInfo.name = toolCallFuncName
            functionInfo.arguments = toolCallFuncArgs
            toolCall.function = option(functionInfo)
          contents.add(ResponseOutputContent(`type`: "tool_call", tool_call: option(toolCall)))

        if contents.len > 0:
          output.content = option(contents)
        result.output.add(output)
        dec i

      inc i

  # Parse Usage Statistics section
  let usageIdx = findNextSection(0, "Usage Statistics")
  if usageIdx >= 0:
    i = usageIdx + 1
    result.usage = option(ResponseUsage())
    while i < lines.len and not lines[i].startsWith("## "):
      let line = lines[i].strip()
      if line.startsWith("- **"):
        let inputTokens = extractInt(line, "Input Tokens")
        if inputTokens > 0: result.usage.get.input_tokens = inputTokens

        let outputTokens = extractInt(line, "Output Tokens")
        if outputTokens > 0: result.usage.get.output_tokens = outputTokens

        let totalTokens = extractInt(line, "Total Tokens")
        if totalTokens > 0: result.usage.get.total_tokens = totalTokens

      inc i

proc toCreateResponseReqAndResp*(markdown: string): (CreateResponseReq, OpenAiResponse) =
  ## Deserialize a Responses API request and response from markdown.
  let lines = markdown.splitLines()

  var requestStartIdx = -1
  var responseStartIdx = -1

  for i, line in lines:
    if line.strip() == "## Request":
      requestStartIdx = i
    elif line.strip() == "## Response":
      responseStartIdx = i

  if requestStartIdx == -1 or responseStartIdx == -1:
    return (CreateResponseReq(), OpenAiResponse())

  var requestLines: seq[string] = @[]
  var i = requestStartIdx + 1
  while i < responseStartIdx and i < lines.len:
    if lines[i].strip() != "---":
      requestLines.add(lines[i])
    inc i

  var responseLines: seq[string] = @[]
  i = responseStartIdx + 1
  while i < lines.len:
    responseLines.add(lines[i])
    inc i

  let requestMarkdown = "# Response Request\n\n" & requestLines.join("\n")
  let responseMarkdown = "# Response\n\n" & responseLines.join("\n")

  let req = toCreateResponseReq(requestMarkdown)
  let resp = toOpenAiResponse(responseMarkdown)

  return (req, resp)
