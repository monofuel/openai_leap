# embeddinggemma supports many types of embedding tasks
# similarity, document / query, classification, and more
import std/[unittest, math], openai_leap

const
  BaseUrl = "http://127.0.0.1:1234/v1"  # LM Studio API

proc checkEmbeddingSanity(resp: CreateEmbeddingResp, testName: string = "") =
  ## Helper function to perform sanity checks on embedding vectors
  check resp.data.len > 0
  let embedding = resp.data[0].embedding
  check embedding.len > 0

  # Check that values are reasonable (not all zeros, not infinite, not NaN)
  var hasNonZero = false
  var allFinite = true
  var minVal = float32.high
  var maxVal = float32.low

  for val in embedding:
    if val != 0.0:
      hasNonZero = true
    if not (val == val) or val == float32(Inf) or val == float32(NegInf):  # Check for NaN, Inf
      allFinite = false
    minVal = min(minVal, val)
    maxVal = max(maxVal, val)

  check hasNonZero
  check allFinite

  # Check that values are within reasonable ranges (typical for normalized embeddings)
  check minVal >= -1.0
  check maxVal <= 1.0

  # Check vector dimensionality (EmbeddingGemma provides 768 dimensions)
  check embedding.len == 768

  let testDesc = if testName != "": " [" & testName & "]" else: ""
  echo "✓ Embedding vector sanity checks passed" & testDesc & ": " & $embedding.len & " dimensions, range [" & $minVal & ", " & $maxVal & "]"

suite "embeddinggemma task-specific embeddings":
  var api: OpenAiApi

  setup:
    api = newOpenAiApi(BaseUrl)

  teardown:
    api.close()

  test "retrieval query embedding":
    let resp = api.generateEmbeddingWithTask(
      model = "text-embedding-embeddinggemma-300m",
      input = "How do I use prompts with this model?",
      task = RetrievalQuery
    )
    checkEmbeddingSanity(resp, "retrieval query")

  test "retrieval document embedding":
    let resp = api.generateEmbeddingWithTask(
      model = "text-embedding-embeddinggemma-300m",
      input = "The document text about using prompts...",
      task = RetrievalDocument,
      title = "Using Prompts in RAG"
    )
    checkEmbeddingSanity(resp, "retrieval document")

  test "question answering embedding":
    let resp = api.generateEmbeddingWithTask(
      model = "text-embedding-embeddinggemma-300m",
      input = "What is the capital of France?",
      task = QuestionAnswering
    )
    checkEmbeddingSanity(resp, "question answering")

  test "fact verification embedding":
    let resp = api.generateEmbeddingWithTask(
      model = "text-embedding-embeddinggemma-300m",
      input = "The Earth is round.",
      task = FactVerification
    )
    checkEmbeddingSanity(resp, "fact verification")

  test "classification embedding":
    let resp = api.generateEmbeddingWithTask(
      model = "text-embedding-embeddinggemma-300m",
      input = "I need help with my account billing.",
      task = Classification
    )
    checkEmbeddingSanity(resp, "classification")

  test "clustering embedding":
    let resp = api.generateEmbeddingWithTask(
      model = "text-embedding-embeddinggemma-300m",
      input = "Machine learning algorithms for text analysis.",
      task = Clustering
    )
    checkEmbeddingSanity(resp, "clustering")

  test "semantic similarity embedding":
    let resp = api.generateEmbeddingWithTask(
      model = "text-embedding-embeddinggemma-300m",
      input = "The chef prepared a delicious meal for the guests.",
      task = SemanticSimilarity
    )
    checkEmbeddingSanity(resp, "semantic similarity")

  test "code retrieval embedding":
    let resp = api.generateEmbeddingWithTask(
      model = "text-embedding-embeddinggemma-300m",
      input = "sort an array in Python",
      task = CodeRetrieval
    )
    checkEmbeddingSanity(resp, "code retrieval")

  test "unsupported model error":
    expect OpenAiError:
      discard api.generateEmbeddingWithTask(
        model = "gpt-4",
        input = "test",
        task = RetrievalQuery
      )

  test "flexible model name support":
    # Test that any model with 'embeddinggemma' in the name works
    let resp1 = api.generateEmbeddingWithTask(
      model = "text-embedding-embeddinggemma-300m",
      input = "Test input",
      task = RetrievalQuery
    )
    check resp1.`object` == "list"

    # Test with different casing
    let resp2 = api.generateEmbeddingWithTask(
      model = "EMBEDDINGGEMMA-test",
      input = "Test input",
      task = RetrievalQuery
    )
    check resp2.`object` == "list"

    # Test with partial match
    let resp3 = api.generateEmbeddingWithTask(
      model = "my-embeddinggemma-model",
      input = "Test input",
      task = RetrievalQuery
    )
    check resp3.`object` == "list"

  test "embedding vector sanity checks":
    # Test that EmbeddingGemma returns reasonable embedding vectors
    let resp = api.generateEmbeddingWithTask(
      model = "text-embedding-embeddinggemma-300m",
      input = "Hello world, this is a test input for embedding validation",
      task = RetrievalQuery
    )

    checkEmbeddingSanity(resp, "comprehensive sanity check")