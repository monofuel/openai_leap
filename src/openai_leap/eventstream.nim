import
  std/options,
  crunchy

type
  EventStreamMessage* = object
    headers*: seq[(string, string)]
    payload*: string

  EventStreamParser* = ref object
    buffer*: string

proc newEventStreamParser*(): EventStreamParser =
  EventStreamParser(buffer: "")

proc feed*(parser: EventStreamParser, data: string) =
  parser.buffer.add(data)

proc readU32BE(data: string, offset: int): uint32 =
  result = (uint32(data[offset].ord) shl 24) or
           (uint32(data[offset + 1].ord) shl 16) or
           (uint32(data[offset + 2].ord) shl 8) or
           uint32(data[offset + 3].ord)

proc readU16BE(data: string, offset: int): uint16 =
  result = (uint16(data[offset].ord) shl 8) or
           uint16(data[offset + 1].ord)

proc next*(parser: EventStreamParser): Option[EventStreamMessage] =
  if parser.buffer.len < 12:
    return none(EventStreamMessage)

  let totalLength = readU32BE(parser.buffer, 0).int
  let headersLength = readU32BE(parser.buffer, 4).int
  let preludeCrc = readU32BE(parser.buffer, 8)

  if totalLength < 16 or totalLength > 1048576:
    parser.buffer = parser.buffer[1 .. ^1]
    return none(EventStreamMessage)

  if parser.buffer.len < totalLength:
    return none(EventStreamMessage)

  let computedPreludeCrc = crc32(parser.buffer[0 ..< 8])
  if computedPreludeCrc != preludeCrc:
    parser.buffer = parser.buffer[1 .. ^1]
    return none(EventStreamMessage)

  let messageCrc = readU32BE(parser.buffer, totalLength - 4)
  let computedMessageCrc = crc32(parser.buffer[0 ..< totalLength - 4])
  if computedMessageCrc != messageCrc:
    parser.buffer = parser.buffer[totalLength .. ^1]
    return none(EventStreamMessage)

  var headers: seq[(string, string)] = @[]
  var pos = 12
  let headersEnd = 12 + headersLength
  while pos < headersEnd:
    if pos >= parser.buffer.len:
      break
    let nameLen = parser.buffer[pos].ord
    pos += 1
    if pos + nameLen > headersEnd:
      break
    let name = parser.buffer[pos ..< pos + nameLen]
    pos += nameLen

    if pos >= headersEnd:
      break
    let headerType = parser.buffer[pos].ord
    pos += 1

    if headerType == 7:
      if pos + 2 > headersEnd:
        break
      let valueLen = readU16BE(parser.buffer, pos).int
      pos += 2
      if pos + valueLen > headersEnd:
        break
      let value = parser.buffer[pos ..< pos + valueLen]
      pos += valueLen
      headers.add((name, value))
    else:
      break

  let payloadStart = 12 + headersLength
  let payloadEnd = totalLength - 4
  let payload = if payloadEnd > payloadStart:
    parser.buffer[payloadStart ..< payloadEnd]
  else:
    ""

  parser.buffer = parser.buffer[totalLength .. ^1]
  result = some(EventStreamMessage(headers: headers, payload: payload))
