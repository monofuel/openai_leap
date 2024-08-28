import openai_leap, jsony, std/[unittest, os]

const
  TestModel = "gpt-3.5-turbo"
  TestEmbedding = "text-embedding-3-small"
  BaseUrl = "https://api.openai.com/v1"
  #BaseUrl = "http://localhost:11434/v1"
  TunedModel = "ft:gpt-3.5-turbo-0125:personal::9GZiiBWl"

# https://github.com/ollama/ollama/blob/main/docs/openai.md

suite "openai_leap":
  var openai: OpenAiApi

  setup:
    if BaseUrl == "http://localhost:11434/v1":
      putEnv("OPENAI_API_KEY", "ollama")
    openai = newOpenAiApi(BaseUrl)
  teardown:
    openai.close()

  suite "models":
    test "list":
      let models = openai.listModels()
      # echo "OpenAI Models:"
      # for m in models:
      #   echo m.id
      echo "Model Count: " & $models.len
    test "get":
      let model = openAI.getModel(TestModel)
      echo toJson(model)
    # test "delete":
    #   echo "TEST NOT IMPLEMENTED"

  suite "embeddings":
    test "create":
      let resp = openai.generateEmbeddings(TestEmbedding, "how are you today?")
      let vec = resp.data[0].embedding
      echo "Embedding Length: " & $vec.len
  suite "completions":
    test "create":
      let system = "Please talk like a pirate. you are Longbeard the Llama."
      let prompt = "How are you today?"
      let resp = openai.createChatCompletion(TestModel, system, prompt)
      echo resp
