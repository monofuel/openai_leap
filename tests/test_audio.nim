import openai_leap

let openai = newOpenAiApi()

doAssert openai.audioTranscriptions(
  "whisper-1",
  readFile("tests/data/how_many_roads.wav")
).text == "How many roads must a man walk down?"

openai.close()
