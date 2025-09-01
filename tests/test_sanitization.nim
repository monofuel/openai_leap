import openai_leap
import std/[unittest, options]

suite "sanitization":
  test "stripEscapeSequences removes ANSI codes":
    let s = "Hello \x1b[31mWorld\x1b[0m!"
    let cleaned = stripEscapeSequences(s)
    check cleaned == "Hello World!"

  test "sanitizeText passes through clean text":
    let s = "No colors here."
    check sanitizeText(s) == s

  test "sanitizeChatReq cleans message contents":
    var req = CreateChatCompletionReq()
    req.model = "dummy-model"
    req.messages = @[
      Message(
        role: "system",
        content: option(@[
          MessageContentPart(`type`: "text", text: option("Sys \x1b[33mYellow\x1b[0m"))
        ])
      ),
      Message(
        role: "user",
        content: option(@[
          MessageContentPart(`type`: "text", text: option("User \x1b[34mBlue\x1b[0m"))
        ])
      )
    ]

    sanitizeChatReq(req)

    let sysText = req.messages[0].content.get[0].text.get
    let userText = req.messages[1].content.get[0].text.get

    check sysText == "Sys Yellow"
    check userText == "User Blue"


