import openai_leap

let openai = newOpenAiApi()

let models = openai.listModels()
echo "OpenAI Models:"
for m in models:
  echo m.id
let system = "Please talk like a pirate. you are Longbeard the Llama."
let prompt = "How are you today?"
let resp = openai.createChatCompletion("gpt-4o", system, prompt)
echo resp

openai.close()
