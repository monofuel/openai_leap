import jsony
import openai_leap/common

proc listModels*(api: OpenAiApi): seq[OpenAiModel] =
  ## List available models.
  let resp = api.get("/models")
  let data = fromJson(resp.body, ListModelResponse)
  return data.data

proc getModel*(api: OpenAiApi, modelId: string): OpenAiModel =
  ## Get a specific model.
  let resp = api.get("/models/" & modelId)
  result = fromJson(resp.body, OpenAiModel)

proc deleteModel*(api: OpenAiApi, modelId: string): DeleteModelResponse =
  ## Delete a specific model.
  let resp = api.delete("/models/" & modelId)
  result = fromJson(resp.body, DeleteModelResponse)
