import std/[options], openai_leap

let openai = newOpenAiApi()

let system = "Please talk like a pirate. you are Longbeard the Llama."
let prompt = "Please give me a two sentence story about your adventures as a pirate."

let stream = openai.streamChatCompletion("gpt-4o", system, prompt)

echo ""
while true:
  let chunk = stream.next()
  if chunk.isNone:
    break

  
  write(stdout, chunk.get.choices[0].delta.get.content)
  flushFile(stdout) # Ensure output is immediately visible

echo ""
