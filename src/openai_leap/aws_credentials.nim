import
  std/[json, os, osproc, strutils, times],
  openai_leap/sigv4

var
  cachedCreds: AwsCredentials
  cachedExpiration: Time

proc loadAwsCredentials*(profile: string = ""): AwsCredentials =
  if cachedCreds.accessKeyId.len > 0 and getTime() < cachedExpiration:
    return cachedCreds

  let akid = getEnv("AWS_ACCESS_KEY_ID")
  let secret = getEnv("AWS_SECRET_ACCESS_KEY")
  if akid.len > 0 and secret.len > 0:
    cachedCreds = AwsCredentials(
      accessKeyId: akid,
      secretAccessKey: secret,
      sessionToken: getEnv("AWS_SESSION_TOKEN")
    )
    cachedExpiration = getTime() + initDuration(minutes = 50)
    return cachedCreds

  var cmd = "aws configure export-credentials --format process"
  let resolvedProfile = if profile.len > 0: profile else: getEnv("AWS_PROFILE")
  if resolvedProfile.len > 0:
    cmd.add(" --profile " & resolvedProfile)

  let (output, exitCode) = execCmdEx(cmd)
  if exitCode != 0:
    raise newException(IOError, "Failed to load AWS credentials: " & output)

  let j = parseJson(output)
  cachedCreds = AwsCredentials(
    accessKeyId: j["AccessKeyId"].getStr,
    secretAccessKey: j["SecretAccessKey"].getStr,
    sessionToken: j.getOrDefault("SessionToken").getStr
  )

  if j.hasKey("Expiration"):
    let expStr = j["Expiration"].getStr
    let expTime = parse(expStr.replace("Z", "+00:00"), "yyyy-MM-dd'T'HH:mm:sszzz").toTime()
    cachedExpiration = expTime - initDuration(seconds = 60)
  else:
    cachedExpiration = getTime() + initDuration(minutes = 50)

  return cachedCreds
