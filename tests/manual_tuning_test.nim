import openai_leap, jsony, std/[unittest, os]

const
  TestModel = "gpt-3.5-turbo-0125"

# https://platform.openai.com/docs/guides/fine-tuning

# Fine-tuning is currently available for the following models:
# gpt-3.5-turbo-0125 (recommended), gpt-3.5-turbo-1106, gpt-3.5-turbo-0613, babbage-002, davinci-002,
# and gpt-4-0613 (experimental).


suite "OpenAI finetuning":
  var openai: OpenAIAPI

  setup:
    openai = newOpenAIAPI()
  teardown:
    openai.close()

  suite "finetune":
    test "upload dataset":
      let model = openai.createFineTuneDataset("tests/test-dataset.jsonl")
      assert model.id != ""
      assert model.purpose == "fine-tune"
      
