import
  std/[json, os, osproc, strformat, strutils],
  curly, jsony, webby,
  openai_leap/common

proc dumpHook(s: var string, v: object) =
  ## Jsony skip optional fields that are nil.
  s.add '{'
  var i = 0
  # Normal objects.
  for k, e in v.fieldPairs:
    when compiles(e.isSome):
      if e.isSome:
        if i > 0:
          s.add ','
        s.dumpHook(k)
        s.add ':'
        s.dumpHook(e)
        inc i
    else:
      if i > 0:
        s.add ','
      s.dumpHook(k)
      s.add ':'
      s.dumpHook(e)
      inc i
  s.add '}'

proc postMultipart(
  api: OpenAiApi,
  path: string,
  entries: seq[MultipartEntry]
): Response =
  ## Make a POST request to the OpenAI API.
  var headers: curly.HttpHeaders
  api.lock.sync:
    headers["Authorization"] = "Bearer " & api.apiKey
  if api.organization != "":
    headers["Organization"] = api.organization
  let (contentType, body) = encodeMultipart(entries)
  headers["Content-Type"] = contentType
  let resp = api.curly.post(
    api.baseUrl & path,
    headers,
    body,
    api.curlTimeout
  )
  if resp.code != 200:
    raise newException(
      OpenAiError,
      &"API call {path} failed: {resp.code} {resp.body}\nRequest body: {toJson(body)}"
    )
  result = resp

proc createFineTuneDataset*(api: OpenAiApi, filepath: string): OpenAIFile =
  ## OpenAI fine tuning format is a jsonl file.
  ## At least 10 examples are required. 50 to 100 recommended.
  ## For a training file with 100,000 tokens trained over 3 epochs,
  ## the expected cost would be ~$2.40 USD.
  ## File will take time to process while uploading.
  ## Maximum file size is 512MB, but not files that big are not recommended.
  ## There is a 100gb limit across an organization.
  ## See: https://platform.openai.com/docs/api-reference/files/create

  # This API call is special and uses a form for file upload
  # HACK using execCmd to call curl directly instead of use curly

  if not fileExists(filepath):
    raise newException(OpenAiError, "File does not exist: " & filepath)
  var authToken: string
  api.lock.sync:
    authToken = "Bearer " & api.apiKey
  var orgLine = ""
  if api.organization != "":
    orgLine = "-H \"Organization: " & api.organization & "\""
  let curlUploadCmd = &"""
curl -s https://api.openai.com/v1/files \
  -H "Authorization: {authToken}" \
  {orgLine} \
  -F purpose="fine-tune" \
  -F file="@{filepath}"
"""
  let (output, res) = execCmdEx(curlUploadCmd)
  if res != 0:
    raise newException(
      OpenAiError,
      "Failed to upload file, curl returned " & $res
    )
  result = fromJson(output, OpenAIFile)

proc listFiles*(api: OpenAiApi): OpenAIListFiles =
  ## List all the files.
  let resp = api.get("/files")
  result = fromJson(resp.body, OpenAIListFiles)

proc getFileDetails*(api: OpenAiApi, fileId: string): OpenAIFile =
  ## Get the details of a file.
  let resp = api.get("/files/" & fileId)
  result = fromJson(resp.body, OpenAIFile)

proc deleteFile*(api: OpenAiApi, fileId: string) =
  ## Delete a file.
  discard api.delete("/files/" & fileId)

# TODO retrieve file content

proc createFineTuneJob*(
  api: OpenAiApi, req: OpenAIFinetuneRequest
): OpenAIFinetuneJob =
  ## Create a fine tune job.
  let reqStr = toJson(req)
  echo reqStr
  let resp = api.post("/fine_tuning/jobs", reqStr)
  result = fromJson(resp.body, OpenAIFinetuneJob)

proc getFineTuneModel*(api: OpenAiApi, modelId: string) =
  ## Get the status of the model.
  raiseAssert("Unimplemented proc")

proc listFineTuneJobs*(api: OpenAiApi): OpenAIFinetuneList =
  ## List all the fine tune jobs.
  let resp = api.get("/fine_tuning/jobs")
  echo resp.body
  result = fromJson(resp.body, OpenAIFinetuneList)

proc listFineTuneModelEvents*(api: OpenAiApi, modelId: string) =
  ## List all the events for the fine tune model.
  raiseAssert("Unimplemented proc")

proc listFineTuneCheckpoints*(api: OpenAiApi, modelId: string) =
  ## List all the checkpoints for the fine tune model.
  ## See: https://platform.openai.com/docs/api-reference/fine-tuning/list-checkpoints
  raiseAssert("Unimplemented proc")

proc cancelFineTuneModel*(api: OpenAiApi, modelId: string) =
  ## Cancel the fine tune model.
  raiseAssert("Unimplemented proc")

proc deleteFineTuneModel*(api: OpenAiApi, modelId: string) =
  ## Delete the fine tune model.
  raiseAssert("Unimplemented proc")

proc audioTranscriptions*(
  api: OpenAiApi,
  model: string,
  audioData: string
): AudioTranscription =
  ## Transcribe audio data.
  let entries = @[
    MultipartEntry(
      name: "file",
      fileName: "input.wav",
      contentType: "audio/wav",
      payload: audioData
    ),
    MultipartEntry(
      name: "model",
      payload: model
    )
  ]
  let response = postMultipart(
    api,
    "/audio/transcriptions",
    entries
  )
  return response.body.fromJson(AudioTranscription)

proc pullModel*(api: OpenAiApi, model: string, timeout: int = 0) =
  ## Ask Ollama to pull a model.
  ## Only for ollama! not for other providers!
  var pullTimeout = timeout
  if pullTimeout == 0:
    pullTimeout = api.curlTimeout

  var baseUrl = api.baseUrl
  baseUrl.removeSuffix("/v1")
  let url = baseUrl & "/api/pull"
  let req = %*{
    "model": model,
    "stream": false
  }
  var headers: curly.HttpHeaders
  headers["Content-Type"] = "application/json"
  let resp = api.curly.post(url, headers, toJson(req), pullTimeout)
  if resp.code != 200:
    raise newException(OpenAiError, "Failed to pull model: " & resp.body)
