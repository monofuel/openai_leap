# openai_leap

Nim OpenAI API library

A very basic OpenAI API client to use from Nim.
openai_leap uses a [Curly](https://github.com/guzba/curly) pool to manage connections.

## Example

- The library assumes that `OPENAI_API_KEY` will be set in the environment and uses the default ChatGPT API endpoint.

```bash
export OPENAI_API_KEY="your-key-goes-here"
```

Simple example with a fully buffered response:
```nim
import openai_leap

let openai = newOpenAiApi()

let models = openai.listModels()
echo "OpenAI Models:"
for m in models:
  echo m.id
let system = "Please talk like a pirate. You are Longbeard the Llama."
let prompt = "How are you today?"
let resp = openai.createChatCompletion("gpt-4o", system, prompt)
echo resp

openai.close()
```

Simple example with a streamed response using a callback:
```nim
import std/[options], openai_leap

let openai = newOpenAiApi()

let system = "Please talk like a pirate. you are Longbeard the Llama."
let prompt = "Please give me a two sentence story about your adventures as a pirate."
proc callback(response: ChatCompletionChunk) =
  write(stdout, response.choices[0].delta.get.content)
  flushFile(stdout) # flush stdout so we can see the response while it is being streamed, not only on newlines

echo ""
openai.streamChatCompletion("gpt-4o", system, prompt, callback)
echo ""

openai.close()
```

- `newOpenAiApi` has optional named parameters:
  - `baseUrl` can change the OpenAI endpoint.
    - "https://api.openai.com/v1" is the default.
    - "http://localhost:11434/v1" may be used for a locally running Ollama instance.
  - `apiKey` may be set to directly pass the API key as a parameter, rather than using the `OPENAI_API_KEY` environment variable.
    - If you wish to use Ollama, you can provide a bogus value for the API key.
  - `organization` optionally lets you set the organization header in API requests.
  - `curlPoolSize` controls the size of the Curly pool to manage HTTP connections. The default is 4.
  - `curlTimeout` is a float32 representing milliseconds to control the timeout for HTTP requests. The default is 60000 (60 seconds).
    - I'm not sure what the server-side timeout is. The request time is highly variable depending on the size of the prompt, the model being used, and the size of the response. You may want a lower time for faster failures and retries if you know your requests are small, or a higher time for larger requests.
    - Higher timeouts are safer, but it can be a frustrating user experience if simple requests hang when you know they likely failed.

## TypeSafe decisions

`createSystemOne` calls the Jev-compatible `/systemone` endpoint on TypeSafe,
LM Studio, or llama.cpp. Use a decision model such as Kev; this endpoint does
not generate chat text. The OpenAI-style `/decisions` endpoint is separate
and is not supported by this method.

```nim
import
  std/[json, options, tables],
  openai_leap

let api = newOpenAiApi("http://localhost:1234/v1", apiKey = "lm-studio")
var questions: OrderedTable[string, SystemOneQuestion]
questions["action"] = SystemOneQuestion(
  `type`: "choice",
  instructions: %"What should Wayfarer do next?",
  criteria: some(%*{"follow": "walk after the player", "stay": "wait here"})
)
questions["wait"] = SystemOneQuestion(
  `type`: "noul", instructions: %"Should Wayfarer wait here?"
)
questions["urgency"] = SystemOneQuestion(
  `type`: "score", instructions: %"How urgent is this request?",
  criteria: some(%*["not urgent", "somewhat urgent", "very urgent"])
)

let response = api.createSystemOne(
  "kev-4b", "Wait here while I collect iron.", questions
)
echo response.answers["action"].choice.get
echo response.answers["action"].probabilities.get["stay"]
echo response.answers["wait"].noul.get
echo response.answers["urgency"].score.get
echo response.usage.input_tokens
api.close()
```

Use `CreateSystemOneReq` for structured state or media. `state` and question
`instructions` accept JSON strings, objects, or arrays. `criteria` accepts an
object for `choice` and optional `noul` rubrics, or an ordered array for `score`.
Choice descriptions may be explicit JSON nulls. Type-dependent answer fields
are `Option` values; score legends and probabilities retain string index keys.
For structured state, replace the text call in the example above with:

```nim
let req = CreateSystemOneReq(
  model: "kev-4b",
  state: %*{"player": "monofuel", "chat": "Wait here."},
  questions: questions
)
let response = api.createSystemOne(req, Opts(curlTimeout: 30))
```

Both overloads accept `Opts` for per-request bearer tokens, organization,
and timeout overrides. Timeout values are in seconds. Requests are sent
without modifying or sanitizing caller data; server errors raise `OpenAiError`.

For compatible multimodal servers/models, set `req.images` or `req.files` to
`some(@[dataUrl])`, where `dataUrl` is an inline `data:image/...;base64,...`
or supported `data:audio/...;base64,...` URL. Fetching and encoding media is
the caller's responsibility. Kev's text-only tests do not verify image/audio
inference. See the [TypeSafe API](https://docs.typesafe.ai/api) and
[llama.cpp System One documentation](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md#post-v1systemone-typesafe-compatible-system-one-api)
for server-specific support.

## Testing

- Testing expects that `OPENAI_API_KEY` is set in the environment with a valid OpenAI API key.
  - If this key is not set, the tests will instead assume Ollama is running locally and test against the Ollama OpenAI API.

- You can run `nimble test` to run the default test suite that does not upload any files or make any changes to the OpenAI API.
  - These tests include the embedding & chat API endpoints, tool usage, and basic serialization tests to ensure Optional types are handled correctly.

- `nix develop -c nim r tests/test_typesafe.nim` runs the offline TypeSafe tests.
- `nix develop -c nim r tests/manual_systemone.nim` runs the live decision test
  against Azem and a loaded `kev-4b` by default. Override `SYSTEMONE_BASE_URL`,
  `SYSTEMONE_MODEL`, and `SYSTEMONE_API_KEY` for another server. This test is
  separate from the default suite and does not explicitly load models or change
  server settings; the server may load the requested model automatically.

- `nim c -r tests/manual_tuning_test.nim` performs a fine-tuning test.
  - This requires uploading some sample test data and creating a new fine-tune; remember to clean up afterward.

## Notes

### JSON Usage

OpenAI API requests require the use of snake_case and have some optional fields that need to be omitted correctly. This library handles that for you. [Jsony](https://github.com/treeform/jsony) is used for serialization and includes a `dumpHook()` to ensure that `nil` Optional fields are omitted from the generated JSON.

### Message Content Parts

The chat completion endpoint for OpenAI has a `content` field that accepts either a string or a sequence of content parts of type 'text' or 'image_url'. Nim does not have a good way to express this type union, so we currently only support a sequence of content parts.

```nim
let req = CreateChatCompletionReq()
req.model = model
req.messages = @[
  Message(role: "system", content: option(@[MessageContentPart(`type`: "text", text: option(systemPrompt))])),
  Message(role: "user", content: option(@[MessageContentPart(`type`: "text", text: option(input))]))
  ]
let resp = api.createChatCompletion(req)
```

## Related Repos

- [llama_leap](https://github.com/monofuel/llama_leap) is a Nim client for the Ollama API.
- [vertex_leap](https://github.com/monofuel/vertex_leap) is a client for Google's VertexAI API.
- [mono_llm](https://github.com/monofuel/mono_llm) is a higher-level Nim library that creates a unified interface for OpenAI, Ollama, and VertexAI.
