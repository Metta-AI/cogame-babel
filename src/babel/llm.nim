## Native sidecar transport and canonical private prompt templates.
## Missing endpoint selects unsupervised scripted fallback; retired provider
## credentials never activate inference. The game server does not import this module.

import
  std/[base64, json, math, monotimes, options, os, sets, strutils, tables],
  bitworld/[decision_trajectory, native_http],
  game_policy, sim

from std/unicode import validateUtf8

export game_policy

const
  TrainingOperatorPrompt* = "Build a shared glyph code from feedback."
  AnthropicVersion = "2023-06-01"

type
  LlmCallEvidence* = object
    prompt*, request*, rawResponse*: JsonNode
    response*: Option[string]
    model*: string
    platformCallId*, providerRequestId*: Option[string]
    responseHeaders*: Option[Table[string, string]]
    responseBodyB64*, responseHeadersB64*: Option[string]
    responseComplete*, responseReaderJoined*: Option[bool]
    httpStatus*: Option[int]
    latencyMs*: Option[float]
    inputTokens*, outputTokens*: Option[int]
    decoder*: JsonNode
    modelIdentity*, tokenizerIdentity*, chatTemplateSha256*, stopReason*: Option[string]
    promptTokenIds*, sampledTokenIds*: Option[seq[int]]
    behaviorLogprobs*: Option[seq[float]]

  LlmClient* = ref object
    lastCall*: LlmCallEvidence
    beforeCall*: proc(evidence: LlmCallEvidence) {.closure, gcsafe.}
    sidecarEndpoint: string
    model: string
    temperature: float
    maxOutputTokens: int
    disabled*: bool    ## true once credentials are known-unavailable
    scripted: ScriptedPolicy

proc newLlmClient*(): LlmClient =
  result = LlmClient(
    model: getEnv("COWORLD_LLM_MODEL", "anthropic/claude-haiku-4.5"),
    temperature: getEnv("COWORLD_LLM_TEMPERATURE", "1").parseFloat(),
    maxOutputTokens: getEnv("PLAYER_MAX_OUTPUT_TOKENS", "900").parseInt(),
    scripted: newScriptedPolicy(0)
  )
  if classify(result.temperature) in {fcNan, fcInf, fcNegInf} or
      result.temperature < 0 or result.temperature > 1:
    raise newException(ValueError, "COWORLD_LLM_TEMPERATURE must be finite and in 0..1")
  let sidecarEndpoint = getEnv("COWORLD_LLM_ENDPOINT").strip()
  if sidecarEndpoint.len > 0:
    result.sidecarEndpoint = sidecarEndpoint.strip(chars = {'/'}, leading = false)
    return
  result.disabled = true
  echo "babel llm: no native endpoint; using unsupervised scripted fallback"

proc newScriptedClient*(seed: int): LlmClient =
  ## Runs the baseline without resolving model credentials or opening a transport.
  LlmClient(scripted: newScriptedPolicy(seed), disabled: true)

proc scriptedAction*(client: LlmClient, sim: Sim, call: Call): Decision =
  client.scripted.scriptedAction(sim, call)

# ---- Native sidecar transport ------------------------------------------

proc privateAttempt*(evidence: LlmCallEvidence, attemptId: string,
    failure = ""): DecisionAttempt =
  result = newDecisionAttempt(attemptId, "babel-prompt", aoModel)
  result.model = some(evidence.model)
  result.prompt = evidence.prompt
  result.request = evidence.request
  result.response = if evidence.response.isSome: %evidence.response.get() else: newJNull()
  result.rawResponse = evidence.rawResponse
  result.decoder = evidence.decoder
  result.platformCallId = evidence.platformCallId
  result.responseHeaders = evidence.responseHeaders
  result.providerRequestId = evidence.providerRequestId
  result.responseBodyB64 = evidence.responseBodyB64
  result.responseHeadersB64 = evidence.responseHeadersB64
  result.responseComplete = evidence.responseComplete
  result.responseReaderJoined = evidence.responseReaderJoined
  result.httpStatus = evidence.httpStatus
  result.latencyMs = evidence.latencyMs
  result.inputTokens = evidence.inputTokens
  result.outputTokens = evidence.outputTokens
  result.rejectionReason = if failure.len > 0: some(failure) else: none(string)
  result.modelIdentity = evidence.modelIdentity
  result.tokenizerIdentity = evidence.tokenizerIdentity
  result.chatTemplateSha256 = evidence.chatTemplateSha256
  result.stopReason = evidence.stopReason
  result.promptTokenIds = evidence.promptTokenIds
  result.sampledTokenIds = evidence.sampledTokenIds
  result.behaviorLogprobs = evidence.behaviorLogprobs

proc completeText*(client: LlmClient, system, user: string, slot: int,
    deadline: MonoTime): string =
  client.lastCall = LlmCallEvidence(
    prompt: %*[{"role": "system", "content": system}, {"role": "user", "content": user}],
    request: newJNull(), rawResponse: newJNull(),
    model: client.model, decoder: %*{"max_tokens": client.maxOutputTokens, "temperature": client.temperature})
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "temperature": client.temperature,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  headers["X-Coworld-Player-Slot"] = $slot
  body["model"] = %client.model
  headers["anthropic-version"] = AnthropicVersion
  let url = client.sidecarEndpoint & "/v1/messages"
  client.lastCall.request = copy(body)
  if client.beforeCall != nil:
    client.beforeCall(client.lastCall)
  var requestControl: NativeRequestControl
  let response = performNativePost(url, headers, $body, deadline, requestControl)
  client.lastCall.latencyMs = response.latencyMs
  client.lastCall.responseReaderJoined = response.responseReaderJoined
  let observedResponse = response.httpStatus.isSome or response.headerBytes.len > 0 or response.bodyBytes.len > 0
  if observedResponse:
    client.lastCall.responseBodyB64 = some(encode(response.bodyBytes))
    client.lastCall.responseHeadersB64 = some(encode(response.headerBytes))
    client.lastCall.responseComplete = some(response.transferComplete)
    client.lastCall.httpStatus = response.httpStatus
    if validateUtf8(response.bodyBytes) == -1:
      client.lastCall.rawResponse = %response.bodyBytes
  if validateUtf8(response.headerBytes) != -1:
    raise newException(BabelError, "received HTTP headers are not valid UTF-8")
  var responseHeaders: HttpHeaders
  var receivedHeaders = initTable[string, string]()
  var identityHeaders = initHashSet[string]()
  for line in response.headerBytes.splitLines():
    if line.startsWith("HTTP/"):
      responseHeaders.setLen(0)
      receivedHeaders.clear()
      identityHeaders.clear()
    elif line.len > 0:
      let colon = line.find(':')
      if colon <= 0:
        raise newException(BabelError, "invalid received HTTP header")
      let name = line[0 ..< colon]
      let value = line[colon + 1 .. ^1].strip()
      let normalized = name.toLowerAscii()
      if normalized in ["request-id", "x-request-id", "x-softmax-llm-call-id",
          "x-coworld-checkpoint-sha256", "x-coworld-tokenizer-sha256",
          "x-coworld-chat-template-sha256"]:
        if normalized in identityHeaders:
          raise newException(BabelError, "duplicate received identity header")
        identityHeaders.incl(normalized)
      responseHeaders.add((name, value))
      receivedHeaders[name] = value
  if observedResponse:
    client.lastCall.responseHeaders = some(receivedHeaders)
  if responseHeaders.contains("request-id") and responseHeaders.contains("x-request-id") and
      responseHeaders["request-id"] != responseHeaders["x-request-id"]:
    raise newException(BabelError, "conflicting received request identity headers")
  for key in ["request-id", "x-request-id"]:
    if responseHeaders.contains(key):
      client.lastCall.providerRequestId = some(responseHeaders[key])
      break
  for (header, field) in [
      ("x-softmax-llm-call-id", "call"),
      ("x-coworld-checkpoint-sha256", "model"),
      ("x-coworld-tokenizer-sha256", "tokenizer"),
      ("x-coworld-chat-template-sha256", "template")]:
    if responseHeaders[header].len > 0:
      case field
      of "call":
        let identity = responseHeaders[header]
        if identity.len != 36:
          raise newException(BabelError, "received platform call identity is not a UUID")
        for index, character in identity:
          if index in [8, 13, 18, 23]:
            if character != '-':
              raise newException(BabelError, "received platform call identity is not a UUID")
          elif character notin {'0'..'9', 'a'..'f', 'A'..'F'}:
            raise newException(BabelError, "received platform call identity is not a UUID")
        client.lastCall.platformCallId = some(identity)
      of "model": client.lastCall.modelIdentity = some(responseHeaders[header])
      of "tokenizer": client.lastCall.tokenizerIdentity = some(responseHeaders[header])
      else: client.lastCall.chatTemplateSha256 = some(responseHeaders[header])
  if response.kind != nhComplete:
    raise newException(BabelError, "native transport " & $response.kind)
  let status = response.httpStatus.get()
  if status == 401 or status == 403:
    client.disabled = true
    raise newException(BabelError, "native inference auth failed (" & $status & ")")
  if status == 429:
    let detail = response.bodyBytes[0 .. min(response.bodyBytes.high, 300)]
    raise newException(BabelError, "llm throttled (429): " & detail)
  if status < 200 or status >= 300:
    raise newException(BabelError, "native inference error " & $status &
      ": " & response.bodyBytes[0 .. min(response.bodyBytes.high, 300)])
  let payload = parseJson(response.bodyBytes)
  if payload.kind != JObject or payload["model"].kind != JString or
      payload["content"].kind != JArray:
    raise newException(BabelError, "native response violates the completion schema")
  client.lastCall.model = payload["model"].getStr()
  case payload["stop_reason"].kind
  of JString: client.lastCall.stopReason = some(payload["stop_reason"].getStr())
  of JNull: discard
  else: raise newException(BabelError, "native stop reason must be text or null")
  if payload.hasKey("usage") and payload["usage"].kind != JNull:
    let usage = payload["usage"]
    if usage.kind != JObject or usage["input_tokens"].kind != JInt or
        usage["output_tokens"].kind != JInt or usage["input_tokens"].getInt() < 0 or
        usage["output_tokens"].getInt() < 0:
      raise newException(BabelError, "native usage must contain nonnegative integer counts")
    client.lastCall.inputTokens = some(usage["input_tokens"].getInt())
    client.lastCall.outputTokens = some(usage["output_tokens"].getInt())
  if payload.hasKey("sampling_evidence") and payload["sampling_evidence"].kind != JNull:
    let sampling = payload["sampling_evidence"]
    if sampling.kind != JObject or sampling["prompt_token_ids"].kind != JArray or
        sampling["completion_token_ids"].kind != JArray or sampling["stop_reason"].kind != JString:
      raise newException(BabelError, "native sampling evidence violates the token schema")
    var promptIds, sampledIds: seq[int]
    var probabilities: seq[float]
    for token in sampling["prompt_token_ids"]:
      if token.kind != JInt or token.getInt() < 0:
        raise newException(BabelError, "native prompt token IDs must be nonnegative integers")
      promptIds.add(token.getInt())
    for token in sampling["completion_token_ids"]:
      if token.kind != JInt or token.getInt() < 0:
        raise newException(BabelError, "native sampled token IDs must be nonnegative integers")
      sampledIds.add(token.getInt())
    if sampling["behavior_log_probs"].kind != JNull:
      if sampling["behavior_log_probs"].kind != JArray:
        raise newException(BabelError, "native draw probabilities must be an array or null")
      for probability in sampling["behavior_log_probs"]:
        if probability.kind notin {JInt, JFloat} or
            classify(probability.getFloat()) in {fcNan, fcInf, fcNegInf} or probability.getFloat() > 0:
          raise newException(BabelError, "native draw probabilities must be finite nonpositive numbers")
        probabilities.add(probability.getFloat())
      if probabilities.len != sampledIds.len:
        raise newException(BabelError, "native draw probabilities must match sampled token IDs")
    client.lastCall.promptTokenIds = some(promptIds)
    client.lastCall.sampledTokenIds = some(sampledIds)
    if sampling["behavior_log_probs"].kind != JNull:
      client.lastCall.behaviorLogprobs = some(probabilities)
    client.lastCall.stopReason = some(sampling["stop_reason"].getStr())
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(BabelError, "native inference refusal")
  for contentBlock in payload["content"]:
    if contentBlock.kind != JObject or contentBlock["type"].kind != JString:
      raise newException(BabelError, "native content block violates the completion schema")
    if contentBlock["type"].getStr() == "text":
      if contentBlock["text"].kind != JString:
        raise newException(BabelError, "native text content must be text")
      result.add(contentBlock["text"].getStr())
  client.lastCall.response = some(result)
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(BabelError, "reply cut off at max_tokens before " &
      "any JSON: " & result[0 .. min(result.high, 160)].replace("\n", " "))
