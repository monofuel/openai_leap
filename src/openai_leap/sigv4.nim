import
  std/[algorithm, sequtils, strformat, strutils, times, uri],
  crunchy, curly

type
  AwsCredentials* = object
    accessKeyId*: string
    secretAccessKey*: string
    sessionToken*: string

proc uriEncode(s: string, encodeSlash: bool = true): string =
  for c in s:
    if c in {'A'..'Z', 'a'..'z', '0'..'9', '-', '_', '.', '~'}:
      result.add(c)
    elif c == '/' and not encodeSlash:
      result.add(c)
    else:
      result.add('%')
      result.add(toHex(ord(c).uint8, 2).toUpperAscii())

proc canonicalQueryString(query: string): string =
  if query.len == 0:
    return ""
  var pairs: seq[(string, string)] = @[]
  for part in query.split('&'):
    let eqIdx = part.find('=')
    if eqIdx >= 0:
      pairs.add((uriEncode(part[0 ..< eqIdx]), uriEncode(part[eqIdx + 1 .. ^1])))
    else:
      pairs.add((uriEncode(part), ""))
  pairs.sort(proc(a, b: (string, string)): int = cmp(a[0], b[0]))
  result = pairs.mapIt(it[0] & "=" & it[1]).join("&")

proc signRequest*(
  creds: AwsCredentials,
  verb, url, region, service: string,
  headers: var curly.HttpHeaders,
  body: string,
  timestamp: DateTime = now().utc
) =
  let parsed = parseUri(url)
  let host = parsed.hostname
  if parsed.port.len > 0:
    headers["Host"] = host & ":" & parsed.port
  else:
    headers["Host"] = host

  let amzDate = timestamp.format("yyyyMMdd'T'HHmmss'Z'")
  let dateStamp = timestamp.format("yyyyMMdd")
  headers["x-amz-date"] = amzDate

  let payloadHash = sha256(body).toHex()
  headers["x-amz-content-sha256"] = payloadHash

  if creds.sessionToken.len > 0:
    headers["x-amz-security-token"] = creds.sessionToken

  var signedHeaderNames: seq[string] = @[]
  var headerMap: seq[(string, string)] = @[]
  for (k, v) in headers:
    let lower = k.toLowerAscii()
    signedHeaderNames.add(lower)
    headerMap.add((lower, v.strip()))

  headerMap.sort(proc(a, b: (string, string)): int = cmp(a[0], b[0]))
  signedHeaderNames.sort()

  var canonicalHeaders = ""
  for (k, v) in headerMap:
    canonicalHeaders.add(k & ":" & v & "\n")

  let signedHeaders = signedHeaderNames.join(";")

  let canonicalPath = if parsed.path.len == 0: "/" else: uriEncode(parsed.path, encodeSlash = false)
  let canonQuery = canonicalQueryString(parsed.query)

  let canonicalRequest = [
    verb.toUpperAscii(),
    canonicalPath,
    canonQuery,
    canonicalHeaders,
    signedHeaders,
    payloadHash
  ].join("\n")

  let credentialScope = &"{dateStamp}/{region}/{service}/aws4_request"
  let stringToSign = &"AWS4-HMAC-SHA256\n{amzDate}\n{credentialScope}\n{sha256(canonicalRequest).toHex()}"

  let kDate = hmacSha256("AWS4" & creds.secretAccessKey, dateStamp)
  let kRegion = hmacSha256(kDate, region)
  let kService = hmacSha256(kRegion, service)
  let kSigning = hmacSha256(kService, "aws4_request")
  let signature = hmacSha256(kSigning, stringToSign).toHex()

  headers["Authorization"] = &"AWS4-HMAC-SHA256 Credential={creds.accessKeyId}/{credentialScope}, SignedHeaders={signedHeaders}, Signature={signature}"
