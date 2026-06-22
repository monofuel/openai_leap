# Test the xAI (x.ai) Responses API, in particular image input serialization.
import openai_leap, std/[unittest, options, os]

const
  TestModel = "grok-4.20-0309-non-reasoning"
  BaseUrl = "https://api.x.ai/v1"
  # A valid 32x32 PNG embedded as a data URI so the test needs no network
  # fixture. xAI requires images of at least 512 pixels. The Responses API wants
  # image_url as a bare string; a nested object is rejected with a 422
  # "untagged enum ModelInput", which is exactly the bug this guards against.
  TestImageDataUri = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAKklEQVR42mNwav9KU8QwasGoBaMWjFowasGoBaMWjFowasGoBaMWDBULADnR+FtYX2VEAAAAAElFTkSuQmCC"

suite "xai responses":
  let apiKey = getEnv("XAI_API_KEY", "")
  var xai: OpenAiApi

  setup:
    xai = newOpenAiApi(BaseUrl, apiKey = apiKey)
  teardown:
    xai.close()

  test "image input is accepted":
    ## Send a text + input_image message and confirm xAI returns a response
    ## rather than a 422 from a mis-serialized nested image_url object.
    if apiKey.len == 0:
      skip()
    else:
      let req = CreateResponseReq()
      req.model = TestModel
      req.input = option(@[ResponseInput(
        `type`: "message",
        role: option("user"),
        content: option(@[
          ResponseInputContent(`type`: "input_image", image_url: option(TestImageDataUri)),
          ResponseInputContent(`type`: "input_text", text: option("Reply with one word."))
        ])
      )])

      let resp = xai.createResponse(req)
      check resp.`object` == "response"
      check resp.output.len > 0
