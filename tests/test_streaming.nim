# Test the streaming chat completion API
import std/[unittest, options], openai_leap, jsony

const
  TestModel = "gpt-4o"


suite "chatgpt streaming":
  var openai: OpenAiApi

  setup:
    openai = newOpenAiApi()
  teardown:
    openai.close()

  suite "models":
    test "create":
      let system = "Please talk like a pirate. you are Longbeard the Llama."
      let prompt = "Please give me a two sentence story about your adventures as a pirate."

      let stream = openai.streamChatCompletion(TestModel, system, prompt)

      echo ""
      while true:
        let chunks = stream.next()
        if chunks.len == 0:
          break

        for chunk in chunks:
          write(stdout, chunk.choices[0].delta.get.content)
          flushFile(stdout) # Ensure output is immediately visible

      echo ""
    
