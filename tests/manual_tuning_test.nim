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
    var dataset: OpenAIFile

    test "upload dataset":
      dataset = openai.createFineTuneDataset("tests/test-dataset.jsonl")
      assert dataset.id != ""
      assert dataset.purpose == "fine-tune"
    test "list datasets":
      let datasets = openai.listFiles()
      # echo toJson(datasets)
      assert datasets.data.len > 0

    test "create job":
      let req = OpenAIFinetuneRequest(
        trainingFile: dataset.id,
        model: TestModel,
      )
      let job = openai.createFineTuneJob(req)
      echo "JOB CREATED"
      echo toJson(job)

    test "list jobs":
      let jobs = openai.listFineTuneJobs()
      echo "JOBS"
      echo toJson(jobs)
      assert jobs.data.len > 0

    # TODO should poll for job completion and the model to be ready
    # test "fine tuned model":
    #   let system = "You are a helpful assistant"
    #   let prompt = "How are you today?"
    #   let resp = openai.createChatCompletion(TunedModel, system, prompt)
    #   echo resp

    test "cleanup":
      let datasets = openai.listFiles()
      for dataset in datasets.data:
        if dataset.filename == "test-dataset.jsonl":
          openai.deleteFile(dataset.id)

      # TODO cleanup fine-tune models
