# Manual interactive test for the OpenAI Realtime API (text-only).
# Run with: nix develop -c nim r tests/manual_realtime_text.nim

import
  std/[options, os, strutils],
  openai_leap

proc main() =
  ## Run an interactive text chat over the Realtime API.
  let openai = newOpenAiApi(baseUrl = getEnv("OPENAI_BASE_URL", "https://api.openai.com/v1").strip(leading = false, chars = {'/'}))
  echo "Connecting to Realtime API..."
  let session = openai.connectRealtime(getEnv("REALTIME_MODEL", "gpt-realtime-2"))

  # Consume session.created
  let created = session.nextEvent()
  if created.isNone or created.get.`type` != "session.created":
    echo "ERROR: did not receive session.created"
    session.close()
    openai.close()
    return
  echo "Session created."

  # Configure text-only
  let config = RealtimeSessionConfig()
  config.output_modalities = option(@["text"])
  config.instructions = option(getEnv("REALTIME_INSTRUCTIONS", "You are a helpful assistant. Keep responses concise."))
  session.updateSession(config)

  # Consume session.updated
  let updated = session.nextEvent()
  if updated.isSome and updated.get.`type` == "session.updated":
    echo "Session configured for text-only."
  echo ""
  echo "Type a message and press Enter. Type 'quit' to exit."
  echo "---"

  while true:
    stdout.write("> ")
    stdout.flushFile()
    let line = stdin.readLine().strip()
    if line.len == 0:
      continue
    if line == "quit":
      break

    session.addItem(newTextItem("user", line))
    session.createResponse()

    var fullText = ""
    while true:
      let event = session.nextEvent()
      if event.isNone:
        echo "\n[connection closed]"
        session.close()
        openai.close()
        return
      case event.get.`type`
      of "response.output_text.delta":
        if event.get.delta.isSome:
          let chunk = event.get.delta.get
          stdout.write(chunk)
          stdout.flushFile()
          fullText &= chunk
      of "response.output_text.done":
        discard
      of "response.done":
        echo ""
        break
      of "error":
        if event.get.error.isSome:
          echo "\n[error] " & event.get.error.get.message
        break
      else:
        discard

  echo "Bye."
  session.close()
  openai.close()

main()
