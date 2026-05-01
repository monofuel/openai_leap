import
  std/[strutils, times, unittest],
  curly,
  openai_leap/sigv4

suite "sigv4 request signing":
  test "signs GET request with known vectors":
    let creds = AwsCredentials(
      accessKeyId: "AKIAIOSFODNN7EXAMPLE",
      secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
      sessionToken: ""
    )
    let timestamp = dateTime(2013, mMay, 24, 0, 0, 0, zone = utc())
    var headers: curly.HttpHeaders

    signRequest(
      creds,
      "GET",
      "https://exampleservice.us-east-1.amazonaws.com/",
      "us-east-1",
      "exampleservice",
      headers,
      "",
      timestamp
    )

    var authHeader = ""
    var dateHeader = ""
    var hashHeader = ""
    for (k, v) in headers:
      if k == "Authorization":
        authHeader = v
      if k == "x-amz-date":
        dateHeader = v
      if k == "x-amz-content-sha256":
        hashHeader = v

    check dateHeader == "20130524T000000Z"
    check hashHeader == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    check authHeader.startsWith("AWS4-HMAC-SHA256")
    check "Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/exampleservice/aws4_request" in authHeader
    check "SignedHeaders=" in authHeader

  test "signs POST request with body":
    let creds = AwsCredentials(
      accessKeyId: "TESTKEY",
      secretAccessKey: "TESTSECRET",
      sessionToken: ""
    )
    let timestamp = dateTime(2024, mJan, 1, 12, 0, 0, zone = utc())
    var headers: curly.HttpHeaders
    headers["Content-Type"] = "application/json"

    signRequest(
      creds,
      "POST",
      "https://bedrock-runtime.us-east-1.amazonaws.com/model/test-model/invoke",
      "us-east-1",
      "bedrock",
      headers,
      """{"prompt": "hello"}""",
      timestamp
    )

    var authHeader = ""
    for (k, v) in headers:
      if k == "Authorization":
        authHeader = v

    check authHeader.startsWith("AWS4-HMAC-SHA256")
    check "Credential=TESTKEY/20240101/us-east-1/bedrock/aws4_request" in authHeader
    check "Signature=" in authHeader

  test "includes session token when present":
    let creds = AwsCredentials(
      accessKeyId: "TESTKEY",
      secretAccessKey: "TESTSECRET",
      sessionToken: "SESSION123"
    )
    let timestamp = dateTime(2024, mJan, 1, 12, 0, 0, zone = utc())
    var headers: curly.HttpHeaders

    signRequest(
      creds,
      "GET",
      "https://example.amazonaws.com/",
      "us-east-1",
      "example",
      headers,
      "",
      timestamp
    )

    var tokenHeader = ""
    var authHeader = ""
    for (k, v) in headers:
      if k == "x-amz-security-token":
        tokenHeader = v
      if k == "Authorization":
        authHeader = v

    check tokenHeader == "SESSION123"
    check "x-amz-security-token" in authHeader
