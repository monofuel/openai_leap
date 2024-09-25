import std/[options], openai_leap

let openai = newOpenAiApi()

let system = "Please talk like a pirate. you are Longbeard the Llama."
let prompt = "Please give me a two sentence story about your adventures as a pirate."
proc callback(response: ChatCompletionChunk) =
  write(stdout, response.choices[0].delta.get.content)
  flushFile(stdout) # flush stdout so we can see the response while it is being streamed, not only on newlines

echo ""
openai.streamChatCompletion("gpt-4o", system, prompt, callback)
echo ""

openai.close()
