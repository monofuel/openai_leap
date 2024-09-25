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
      proc callback(response: ChatCompletionChunk) =
        write(stdout, response.choices[0].delta.get.content)
        flushFile(stdout) # flush stdout so we can see the response while it is being streamed, not only on newlines

      echo ""
      openai.streamChatCompletion(TestModel, system, prompt, callback)
      echo ""
    
