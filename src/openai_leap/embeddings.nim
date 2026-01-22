import
  std/[options, strformat, strutils],
  jsony,
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

proc generateEmbeddings*(
  api: OpenAiApi,
  model: string,
  input: string,
  dimensions: Option[int] = none(int),
  user: string = ""
): CreateEmbeddingResp =
  ## Generate embeddings for a list of documents.
  let req = CreateEmbeddingReq()
  req.input = sanitizeText(input)
  req.model = model
  req.dimensions = dimensions
  if user != "":
    req.user = option(sanitizeText(user))
  let reqBody = toJson(req)
  let resp = post(api, "/embeddings", reqBody)
  result = fromJson(resp.body, CreateEmbeddingResp)

proc getTaskPrompt(task: EmbeddingTask, title: string = "none"): string =
  ## Get the prompt template for a specific embedding task.
  case task:
  of RetrievalQuery:
    "task: search result | query: "
  of RetrievalDocument:
    &"title: {title} | text: "
  of QuestionAnswering:
    "task: question answering | query: "
  of FactVerification:
    "task: fact checking | query: "
  of Classification:
    "task: classification | query: "
  of Clustering:
    "task: clustering | query: "
  of SemanticSimilarity:
    "task: sentence similarity | query: "
  of CodeRetrieval:
    "task: code retrieval | query: "

proc generateEmbeddingWithTask*(
  api: OpenAiApi,
  model: string,
  input: string,
  task: EmbeddingTask,
  title: string = "none",
  dimensions: Option[int] = none(int),
  user: string = ""
): CreateEmbeddingResp =
  ## Generate embeddings with optional task-specific prompts.
  ## - EmbeddingGemma models: Support all task types with custom prompts
  ## - Other models: Only support SemanticSimilarity (no special prompts)

  let isEmbeddingGemma = model.toLowerAscii().contains("embeddinggemma")

  if isEmbeddingGemma:
    # EmbeddingGemma supports all task types with custom prompts
    let prompt = getTaskPrompt(task, title)
    let promptedInput = prompt & sanitizeText(input)
    result = api.generateEmbeddings(model, promptedInput, dimensions, user)
  else:
    # Non-EmbeddingGemma models only support SemanticSimilarity (no task prompts)
    if task != SemanticSimilarity:
      raise newException(
        OpenAiError,
        &"Model '{model}' only supports SemanticSimilarity task. Use an EmbeddingGemma model for other task types."
      )
    # Use input as-is for non-EmbeddingGemma models
    result = api.generateEmbeddings(model, input, dimensions, user)
