import
  std/[options, unittest],
  crunchy,
  openai_leap/eventstream

proc writeU32BE(s: var string, val: uint32) =
  s.add(char((val shr 24) and 0xFF))
  s.add(char((val shr 16) and 0xFF))
  s.add(char((val shr 8) and 0xFF))
  s.add(char(val and 0xFF))

proc writeU16BE(s: var string, val: uint16) =
  s.add(char((val shr 8) and 0xFF))
  s.add(char(val and 0xFF))

proc buildEventStreamMessage(headers: seq[(string, string)], payload: string): string =
  var headerBytes = ""
  for (name, value) in headers:
    headerBytes.add(char(name.len))
    headerBytes.add(name)
    headerBytes.add(char(7))
    headerBytes.writeU16BE(value.len.uint16)
    headerBytes.add(value)

  let totalLength = 12 + headerBytes.len + payload.len + 4
  let headersLength = headerBytes.len

  var prelude = ""
  prelude.writeU32BE(totalLength.uint32)
  prelude.writeU32BE(headersLength.uint32)
  let preludeCrc = crc32(prelude)

  result = prelude
  result.writeU32BE(preludeCrc)
  result.add(headerBytes)
  result.add(payload)
  let msgCrc = crc32(result)
  result.writeU32BE(msgCrc)

suite "eventstream parser":
  test "parses a single message":
    let parser = newEventStreamParser()
    let msg = buildEventStreamMessage(
      @[(":message-type", "event"), (":event-type", "chunk")],
      """{"bytes": "dGVzdA=="}"""
    )
    parser.feed(msg)
    let result = parser.next()
    check result.isSome
    let m = result.get()
    check m.headers.len == 2
    check m.headers[0] == (":message-type", "event")
    check m.headers[1] == (":event-type", "chunk")
    check m.payload == """{"bytes": "dGVzdA=="}"""

  test "returns none for incomplete data":
    let parser = newEventStreamParser()
    parser.feed("short")
    let result = parser.next()
    check result.isNone

  test "parses empty payload":
    let parser = newEventStreamParser()
    let msg = buildEventStreamMessage(@[("type", "heartbeat")], "")
    parser.feed(msg)
    let result = parser.next()
    check result.isSome
    check result.get().payload == ""
    check result.get().headers[0] == ("type", "heartbeat")

  test "parses multiple messages fed incrementally":
    let parser = newEventStreamParser()
    let msg1 = buildEventStreamMessage(@[("n", "1")], "first")
    let msg2 = buildEventStreamMessage(@[("n", "2")], "second")
    let combined = msg1 & msg2

    parser.feed(combined[0 ..< 10])
    check parser.next().isNone

    parser.feed(combined[10 .. ^1])
    let r1 = parser.next()
    check r1.isSome
    check r1.get().payload == "first"

    let r2 = parser.next()
    check r2.isSome
    check r2.get().payload == "second"

    check parser.next().isNone
