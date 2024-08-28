# openai_leap

Nim OpenAI api library

Very basic OpenAI API client to use from Nim.
openai_leap uses a [Curly](https://github.com/guzba/curly) pool to manage connections.
OpenAI API requests require the use of snake_case and have some optional fields that need to be omitted correctly. This library handles that for you. [Jsony](https://github.com/treeform/jsony) is used for serialization, and includes a `dumpHook()` to ensure that nil Optional fields are ommitted from the generated JSON.


## Example

- The library assumes that `OPENAI_API_KEY` will be set in the environment, and uses the default chatGPT api endpoint.

```bash
export OPENAI_API_KEY="your-key-goes-here"
```

```nim
import openai_leap

let openai = newOpenAIAPI()

let models = openai.listModels()
echo "OpenAI Models:"
for m in models:
  echo m.id
let system = "Please talk like a pirate. you are Longbeard the Llama."
let prompt = "How are you today?"
let resp = openai.createChatCompletion("gpt-4o", system, prompt)
echo resp

openai.close()
```

- `newOpenAIAPI` has optional named parameters
  - `baseUrl` can change the openAI endpoint. 
    - "https://api.openai.com/v1" is the default.
    - "http://localhost:11434/v1" may be used for a locally running Ollama instance.
  - `apiKey` may be set to directly pass the API key as a parameter, rather than using the `OPENAI_API_KEY` environment variable.
    - If you wish to use Ollama, you can put in a bogus value for the API key.
  - `organization` optinally lets you set the organization header in API requests
  - `curlPoolSize` controls the size of the curly pool to manage http connections. the default is 4
  - `curlTimeout` is a float32 of milliseconds to control the timeout for http requests. the default is 60000 (60 seconds)
    - I'm not sure what the server-side timeout is. The request time is highly variable depending on the size of the prompt, the model being used, and size of the response. You may want a lower time for faster failures and retries If you know your requests are small, or a higher time for larger requests.
    - Higher timeouts are safer but it can be a frusterating user experience if simple requests hang when you know they likely failed.


## Testing

- Testing expects that `OPENAI_API_KEY` is set in the environment with a valid OpenAI API key.
  - If this key is not set, the tests will instead assume Ollama is running locally, and test against the Ollama OpenaAI API.

- You can run `nimble test` to run the default test suite that do not upload any files or make any changes to the OpenAI API.
  - These tests include the embedding & chat API endpoints, tool usage, and basic serialization tests to ensure Optional types are handled correctly.

- `nim c -r tests/manual_tuning_test.nim` performs a finetuning test.
  - This requires uploading some sample test data and creating a new fine-tune, remember to clean up after.

## Notes

The chat completion endpoint for OpenAI has a `content` field that accepts either a string, or a sequence of content parts of type 'text' or 'image_url'. Nim does not have a good way to express this type union, so we currently only support a sequence of content parts.
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

- [mono_llm](https://github.com/monofuel/mono_llm) is a higher level Nim library that creates a unified interface for OpenAI, Ollama, and VertexAI.
