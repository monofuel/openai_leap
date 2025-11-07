# embeddinggemma supports many types of embedding tasks
# similarity, document / query, classification, and more
import std/[unittest, math], openai_leap

# this test uses a local lm-studio so I'm not running it on CI currently.

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

proc cosineSimilarity(a, b: seq[float32]): float32 =
  ## Calculate cosine similarity between two embedding vectors
  assert a.len == b.len, "Vectors must have same length"
  var dotProduct: float32 = 0.0
  var normA: float32 = 0.0
  var normB: float32 = 0.0

  for i in 0..<a.len:
    dotProduct += a[i] * b[i]
    normA += a[i] * a[i]
    normB += b[i] * b[i]

  normA = sqrt(normA)
  normB = sqrt(normB)

  if normA == 0.0 or normB == 0.0:
    return 0.0

  result = dotProduct / (normA * normB)

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

suite "embeddinggemma semantic similarity":
  var api: OpenAiApi

  setup:
    api = newOpenAiApi(BaseUrl)

  teardown:
    api.close()

  test "retrieval query vs document similarity":
    # Test that retrieval queries match relevant documents better than other queries

    # Create embeddings for queries and documents
    let query1Resp = api.generateEmbeddingWithTask(
      model = "text-embedding-embeddinggemma-300m",
      input = "How do I implement a neural network in Python?",
      task = RetrievalQuery
    )
    let query2Resp = api.generateEmbeddingWithTask(
      model = "text-embedding-embeddinggemma-300m",
      input = "What's the weather like today?",
      task = RetrievalQuery
    )

    let doc1Resp = api.generateEmbeddingWithTask(
      model = "text-embedding-embeddinggemma-300m",
      input = "Neural networks can be implemented using TensorFlow or PyTorch libraries in Python. First, install the required packages, then create layers and compile the model.",
      task = RetrievalDocument,
      title = "Python Neural Network Tutorial"
    )
    let doc2Resp = api.generateEmbeddingWithTask(
      model = "text-embedding-embeddinggemma-300m",
      input = "Today's weather forecast shows sunny conditions with temperatures around 75°F. No precipitation expected.",
      task = RetrievalDocument,
      title = "Weather Report"
    )

    # Extract embeddings
    let query1Embedding = query1Resp.data[0].embedding
    let query2Embedding = query2Resp.data[0].embedding
    let doc1Embedding = doc1Resp.data[0].embedding
    let doc2Embedding = doc2Resp.data[0].embedding

    # Calculate similarities
    let query1_doc1_similarity = cosineSimilarity(query1Embedding, doc1Embedding)
    let query1_doc2_similarity = cosineSimilarity(query1Embedding, doc2Embedding)
    let query2_doc1_similarity = cosineSimilarity(query2Embedding, doc1Embedding)
    let query2_doc2_similarity = cosineSimilarity(query2Embedding, doc2Embedding)
    let query1_query2_similarity = cosineSimilarity(query1Embedding, query2Embedding)

    # Neural network query should be much more similar to neural network doc than weather doc
    check query1_doc1_similarity > query1_doc2_similarity
    check query1_doc1_similarity > query1_query2_similarity

    # Weather query should be much more similar to weather doc than neural network doc
    check query2_doc2_similarity > query2_doc1_similarity
    check query2_doc2_similarity > query1_query2_similarity

    # Queries should be less similar to each other than to relevant docs
    check query1_doc1_similarity > query1_query2_similarity
    check query2_doc2_similarity > query1_query2_similarity

    echo "✓ Retrieval similarity test passed - Query1-Doc1: " & $query1_doc1_similarity & ", Query1-Doc2: " & $query1_doc2_similarity & ", Query2-Doc2: " & $query2_doc2_similarity & ", Query1-Query2: " & $query1_query2_similarity

  test "semantic similarity clustering":
    # Test that semantic similarity task groups similar content together

    let similar1Resp = api.generateEmbeddingWithTask(
      model = "text-embedding-embeddinggemma-300m",
      input = "The chef prepared a delicious meal for the dinner guests.",
      task = SemanticSimilarity
    )
    let similar2Resp = api.generateEmbeddingWithTask(
      model = "text-embedding-embeddinggemma-300m",
      input = "A tasty dinner was cooked by the chef for the visitors.",
      task = SemanticSimilarity
    )
    let differentResp = api.generateEmbeddingWithTask(
      model = "text-embedding-embeddinggemma-300m",
      input = "The weather forecast predicts rain tomorrow afternoon.",
      task = SemanticSimilarity
    )

    let similar1Embedding = similar1Resp.data[0].embedding
    let similar2Embedding = similar2Resp.data[0].embedding
    let differentEmbedding = differentResp.data[0].embedding

    let similar_similarity = cosineSimilarity(similar1Embedding, similar2Embedding)
    let diff1_similarity = cosineSimilarity(similar1Embedding, differentEmbedding)
    let diff2_similarity = cosineSimilarity(similar2Embedding, differentEmbedding)

    # Semantically similar sentences should have high similarity (> 0.8)
    check similar_similarity > 0.8

    # Semantically different sentences should have much lower similarity (< 0.6)
    check diff1_similarity < 0.6
    check diff2_similarity < 0.6

    # Similar pair should be much more similar than different pairs
    check similar_similarity > diff1_similarity + 0.2
    check similar_similarity > diff2_similarity + 0.2

    echo "✓ Semantic similarity test passed - Similar: " & $similar_similarity & ", Different1: " & $diff1_similarity & ", Different2: " & $diff2_similarity

  test "task-specific embedding differences":
    # Test that different tasks produce different embeddings for the same input

    let sameInput = "How do neural networks work?"

    let retrievalResp = api.generateEmbeddingWithTask(
      model = "text-embedding-embeddinggemma-300m",
      input = sameInput,
      task = RetrievalQuery
    )
    let similarityResp = api.generateEmbeddingWithTask(
      model = "text-embedding-embeddinggemma-300m",
      input = sameInput,
      task = SemanticSimilarity
    )
    let classificationResp = api.generateEmbeddingWithTask(
      model = "text-embedding-embeddinggemma-300m",
      input = sameInput,
      task = Classification
    )

    let retrievalEmbedding = retrievalResp.data[0].embedding
    let similarityEmbedding = similarityResp.data[0].embedding
    let classificationEmbedding = classificationResp.data[0].embedding

    # Calculate pairwise similarities
    let ret_sim = cosineSimilarity(retrievalEmbedding, similarityEmbedding)
    let ret_class = cosineSimilarity(retrievalEmbedding, classificationEmbedding)
    let sim_class = cosineSimilarity(similarityEmbedding, classificationEmbedding)

    # Task-specific prompts should produce noticeably different embeddings
    # (though they'll still be somewhat similar since the input is the same)
    check ret_sim < 0.95  # Should be less than near-perfect similarity
    check ret_class < 0.95
    check sim_class < 0.95

    echo "✓ Task-specific embedding differences test passed - Retrieval-Similarity: " & $ret_sim & ", Retrieval-Classification: " & $ret_class & ", Similarity-Classification: " & $sim_class