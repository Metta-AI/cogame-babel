## Player-side Claude transport, plus prompt templates used by offline
## post-training export. The game server does not import this module.
##
## Credentials, in order of preference:
##   COWORLD_LLM_ENDPOINT            - hosted sidecar
##   Bedrock bearer token            - local play
##   ANTHROPIC_API_KEY                - the key itself
##   ANTHROPIC_API_KEY_URI            - a URI holding the key
## With no credentials, the player sends an immediate scripted action.

import
  std/[json, math, options, os, strutils, tables],
  bitworld/runtime, bitworld/decision_trajectory,
  curly,
  game_policy, sim

export game_policy

const
  TrainingOperatorPrompt* = "Build a shared glyph code from feedback."
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"

type
  LlmTransport = enum
    ltNone, ltSidecar, ltBedrock, ltAnthropic

  LlmCallEvidence* = object
    prompt*, request*, rawResponse*: JsonNode
    response*, model*: string
    platformCallId*: Option[string]
    decoder*: JsonNode
    modelIdentity*, tokenizerIdentity*, chatTemplateSha256*, stopReason*: Option[string]
    promptTokenIds*, sampledTokenIds*: Option[seq[int]]
    behaviorLogprobs*: Option[seq[float]]

  LlmClient* = ref object
    lastCall*: LlmCallEvidence
    beforeCall*: proc(evidence: LlmCallEvidence) {.closure.}
    curl: Curly
    transport: LlmTransport
    apiKey: string          ## anthropic transport
    sidecarEndpoint: string
    bedrockEndpoint: string ## local Bedrock transport
    bedrockModels: seq[string]  ## candidates, tried in order on denial
    bedrockModel: int           ## index into bedrockModels
    bedrockToken: string
    model: string
    temperature: float
    maxOutputTokens: int
    timeoutSeconds: int
    disabled*: bool    ## true once credentials are known-unavailable
    scripted: ScriptedPolicy

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    echo "babel llm: failed to fetch ANTHROPIC_API_KEY_URI: ", error.msg
    result = ""

proc bedrockModelIds(): seq[string] =
  ## Bedrock inference-profile candidates, tried in order. BEDROCK_MODEL
  ## pins a single id; without it, fall through this list — model access is
  ## a per-account Marketplace subscription, so an id that works in one
  ## account 403s in another.
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  ## Haiku leads: hosted Bedrock capacity is shared account-wide and the
  ## sonnet profiles run out of daily tokens first.
  @[
    "us.anthropic.claude-haiku-4-5-20251001-v1:0",
    "us.anthropic.claude-sonnet-4-6",
    "us.anthropic.claude-sonnet-4-5-20250929-v1:0",
  ]

proc tryNextBedrockModel(client: LlmClient, why: string): bool =
  if client.transport != ltBedrock or
      client.bedrockModel + 1 >= client.bedrockModels.len:
    return false
  client.bedrockModel.inc
  echo "babel llm: ", client.bedrockModels[client.bedrockModel - 1],
    " unusable (", why, "); falling back to ",
    client.bedrockModels[client.bedrockModel]
  true

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" &
    client.bedrockModels[client.bedrockModel] & "/invoke"

proc newLlmClient*(): LlmClient =
  result = LlmClient(
    model: getEnv("PLAYER_MODEL", "claude-sonnet-5"),
    temperature: getEnv("COWORLD_LLM_TEMPERATURE", "1").parseFloat(),
    maxOutputTokens: getEnv("PLAYER_MAX_OUTPUT_TOKENS", "900").parseInt(),
    timeoutSeconds: getEnv("PLAYER_LLM_TIMEOUT_SECONDS", "30").parseInt(),
    scripted: newScriptedPolicy(0)
  )
  if classify(result.temperature) in {fcNan, fcInf, fcNegInf} or
      result.temperature < 0 or result.temperature > 1:
    raise newException(ValueError, "COWORLD_LLM_TEMPERATURE must be finite and in 0..1")
  let sidecarEndpoint = getEnv("COWORLD_LLM_ENDPOINT").strip()
  if sidecarEndpoint.len > 0:
    result.transport = ltSidecar
    result.sidecarEndpoint = sidecarEndpoint.strip(chars = {'/'}, leading = false)
    result.model = getEnv("COWORLD_LLM_MODEL", "anthropic/claude-haiku-4.5")
    result.curl = newCurly()
    return
  let bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION",
      getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    echo "babel llm: bedrock transport, url ", result.bedrockUrl
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "babel llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    echo "babel llm: no LLM credentials; using scripted fallback"

proc newScriptedClient*(seed: int): LlmClient =
  ## Runs the baseline without resolving model credentials or opening a transport.
  LlmClient(scripted: newScriptedPolicy(seed), disabled: true)

proc scriptedAction*(client: LlmClient, sim: Sim, call: Call): Decision =
  client.scripted.scriptedAction(sim, call)

# ---- Prompt building --------------------------------------------------------

proc seatName(sim: Sim, seat: int): string =
  sim.names[seat]

proc alphabetText(sim: Sim, seat: int): string =
  ## The seat's 16 glyphs in its own order.
  var glyphs: seq[string]
  for token in 0 ..< Tokens:
    glyphs.add(sim.glyphOf(seat, token))
  glyphs.join(" ")

proc lineupText(sim: Sim, lineup: array[LineupSize, int]): string =
  var parts: seq[string]
  for index in 0 ..< LineupSize:
    parts.add(lineupLetter(index) & ") " & sceneText(lineup[index]))
  parts.join("  ")

proc renderHistory(sim: Sim, seat: int): string =
  ## Every completed round this seat was in, in its own glyphs. It never
  ## sees the other pair's rounds.
  var messages: Table[(int, int), seq[int]]
  var lines: seq[string]
  for event in sim.events:
    case event.kind
    of evSpeak:
      messages[(event.round, event.pair)] = event.tokens
    of evPick:
      if seat != event.seat and seat != event.other:
        continue
      let plan = sim.schedule[event.round]
      let target = plan.targets[event.pair]
      let lineup = plan.lineups[event.pair]
      let message = sim.messageText(seat,
        messages.getOrDefault((event.round, event.pair)))
      let verdict =
        if event.correct: "CORRECT"
        else: "WRONG (it was " & sceneText(target) & ")"
      let pickText = lineupLetter(event.pick) & ") " &
        sceneText(lineup[event.pick])
      if seat == event.other:
        lines.add("Round " & $(event.round + 1) & " — SPEAKER to " &
          sim.seatName(event.seat) & ". Target: " & sceneText(target) &
          ". You sent: " & message & ". " & sim.seatName(event.seat) &
          " picked " & pickText & " — " & verdict & ".")
      else:
        lines.add("Round " & $(event.round + 1) & " — LISTENER to " &
          sim.seatName(event.other) & ". Message: " & message &
          ". Lineup: " & sim.lineupText(lineup) & ". You picked " &
          pickText & " — " & verdict & ".")
    else:
      discard
  if lines.len == 0:
    return "(no rounds played yet)"
  lines.join("\n")

proc systemPrompt*(sim: Sim, seat: int): string =
  let me = sim.seatName(seat)
  "You are " & me & ", a cog playing Babel with three other cogs." &
    """

Rules:
- Every round you are paired with one other cog: one of you is the
  SPEAKER, the other the LISTENER. Partners and roles rotate each round.
- A scene is a SHAPE (circle, square, triangle, star), a COLOUR (red,
  blue, green, yellow), and a COUNT (1, 2, 3, or 4): e.g. "3 green
  triangles".
- The speaker sees only a target scene and sends a message of 1 to 8
  glyphs from a 16-glyph alphabet. The listener sees the message and a
  lineup of four scenes labelled A-D (the target plus three distractors,
  one of which differs from the target in only one attribute) and picks
  one.
- Both of you score a point when the listener picks the target. The game
  is fully cooperative: your score is the share of your rounds that
  succeeded, in either role.
- There are NO words. Only glyphs cross between cogs. The listener sees
  the same 16 TOKENS as you but under DIFFERENT symbols and in a
  different order, so "use the first glyph for red" or "✦ means red"
  cannot be agreed in advance: the meaning of each token has to be
  grounded in play, from the feedback after every round (both partners
  learn the target, the pick, and whether it was right).
- Your notes are private to you and fed back to you every round. Use
  them to keep your dictionary, per partner.

OUTPUT FORMAT: reply with ONLY one JSON object, nothing else - no
analysis, no explanation, no markdown fences, no text before or after
the object. Your reply must begin with the character { and end with }."""

proc operatorBlock(prompt: string): string =
  if prompt.len == 0:
    return ""
  "GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the " &
    "rules; always reply in the requested format):\n" & prompt & "\n\n"

proc commonBlock(sim: Sim, seat: int): string =
  result.add("YOUR ALPHABET (16 glyphs, use only these): " &
    sim.alphabetText(seat) & "\n\n")
  result.add("YOUR NOTES FROM EARLIER ROUNDS:\n" &
    (if sim.notes[seat].len > 0: sim.notes[seat] else: "(none)") & "\n\n")
  result.add("YOUR HISTORY:\n" & sim.renderHistory(seat) & "\n\n")

proc speakerPrompt*(sim: Sim, pair: int, prompt: string): string =
  let plan = sim.plan
  let seat = plan.speakers[pair]
  result.add("Round " & $(sim.round + 1) & " of " & $sim.config.rounds &
    ". You are SPEAKER to " & sim.seatName(plan.listeners[pair]) & ".\n\n")
  result.add(sim.commonBlock(seat))
  result.add("THE TARGET: " & sceneText(plan.targets[pair]) & "\n\n")
  result.add(operatorBlock(prompt))
  result.add("Reply with ONLY {\"tokens\": [\"" & sim.glyphOf(seat, 0) &
    "\",\"" & sim.glyphOf(seat, 1) & "\",…], \"notes\": \"…\"} — 1 to 8 " &
    "glyphs from your alphabet, one glyph per array entry; notes at most " &
    $MaxNotesLen & " characters.")

proc listenerPrompt*(sim: Sim, pair: int, prompt: string): string =
  let plan = sim.plan
  let seat = plan.listeners[pair]
  let speaker = sim.seatName(plan.speakers[pair])
  result.add("Round " & $(sim.round + 1) & " of " & $sim.config.rounds &
    ". You are LISTENER to " & speaker & ".\n\n")
  result.add(sim.commonBlock(seat))
  result.add("MESSAGE FROM " & speaker & ": " &
    sim.messageText(seat, sim.tokens[pair]) & "\n\n")
  result.add("THE LINEUP: " & sim.lineupText(plan.lineups[pair]) & "\n\n")
  result.add(operatorBlock(prompt))
  result.add("Reply with ONLY {\"pick\": \"B\", \"notes\": \"…\"} — the " &
    "letter A, B, C, or D; notes at most " & $MaxNotesLen & " characters.")

# ---- Anthropic / Bedrock transport ------------------------------------------

proc privateAttempt*(evidence: LlmCallEvidence, attemptId: string,
    failure = ""): DecisionAttempt =
  result = newDecisionAttempt(attemptId, "babel-prompt", aoModel)
  result.model = some(evidence.model)
  result.prompt = evidence.prompt
  result.request = evidence.request
  result.response = %evidence.response
  result.rawResponse = evidence.rawResponse
  result.decoder = evidence.decoder
  result.platformCallId = evidence.platformCallId
  result.rejectionReason = if failure.len > 0: some(failure) else: none(string)
  result.modelIdentity = evidence.modelIdentity
  result.tokenizerIdentity = evidence.tokenizerIdentity
  result.chatTemplateSha256 = evidence.chatTemplateSha256
  result.stopReason = evidence.stopReason
  result.promptTokenIds = evidence.promptTokenIds
  result.sampledTokenIds = evidence.sampledTokenIds
  result.behaviorLogprobs = evidence.behaviorLogprobs

proc completeText*(client: LlmClient, system, user: string, slot: int): string =
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
  if client.transport == ltSidecar and slot >= 0:
    headers["X-Coworld-Player-Slot"] = $slot
  var url: string
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    url = client.bedrockUrl()
  elif client.transport == ltSidecar:
    body["model"] = %client.model
    headers["anthropic-version"] = AnthropicVersion
    url = client.sidecarEndpoint & "/v1/messages"
  else:
    body["model"] = %client.model
    ## Only the Claude 5 / Opus tiers accept an effort setting; Haiku 4.5
    ## rejects the whole request with a 400 if it is present.
    if "haiku" notin client.model and "4-5" notin client.model:
      body["output_config"] = %*{"effort": "low"}
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    url = AnthropicUrl
  client.lastCall.request = copy(body)
  if client.transport == ltBedrock:
    client.lastCall.model = client.bedrockModels[client.bedrockModel]
  if client.beforeCall != nil:
    client.beforeCall(client.lastCall)
  let response = client.curl.post(url, headers, $body, client.timeoutSeconds)
  client.lastCall.rawResponse = %response.body
  if response.headers.contains("X-Softmax-Llm-Call-Id"):
    client.lastCall.platformCallId = some(response.headers["X-Softmax-Llm-Call-Id"])
  for header in ["X-Coworld-Checkpoint-Sha256", "X-Coworld-Tokenizer-Sha256",
      "X-Coworld-Chat-Template-Sha256"]:
    if response.headers.contains(header):
      case header
      of "X-Coworld-Checkpoint-Sha256": client.lastCall.modelIdentity = some(response.headers[header])
      of "X-Coworld-Tokenizer-Sha256": client.lastCall.tokenizerIdentity = some(response.headers[header])
      else: client.lastCall.chatTemplateSha256 = some(response.headers[header])
  if response.code == 401 or response.code == 403:
    let detail = response.body[0 .. min(response.body.high, 400)]
    if "Model access is denied" in response.body and
        client.tryNextBedrockModel("no model access"):
      raise newException(BabelError,
        "bedrock model access denied: " & detail)
    client.disabled = true
    raise newException(BabelError,
      "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    let detail = response.body[0 .. min(response.body.high, 300)]
    discard client.tryNextBedrockModel("throttled")
    raise newException(BabelError, "llm throttled (429): " & detail)
  if response.code < 200 or response.code >= 300:
    raise newException(BabelError, "anthropic error " & $response.code &
      ": " & response.body[0 .. min(response.body.high, 300)])
  let payload = parseJson(response.body)
  if payload.hasKey("model"):
    client.lastCall.model = payload["model"].getStr()
  client.lastCall.stopReason = some(payload["stop_reason"].getStr())
  if payload.hasKey("sampling_evidence") and payload["sampling_evidence"].kind != JNull:
    let sampling = payload["sampling_evidence"]
    var promptIds, sampledIds: seq[int]
    var probabilities: seq[float]
    for token in sampling["prompt_token_ids"]: promptIds.add(token.getInt())
    for token in sampling["completion_token_ids"]: sampledIds.add(token.getInt())
    if sampling["behavior_log_probs"].kind != JNull:
      for probability in sampling["behavior_log_probs"]: probabilities.add(probability.getFloat())
    client.lastCall.promptTokenIds = some(promptIds)
    client.lastCall.sampledTokenIds = some(sampledIds)
    if sampling["behavior_log_probs"].kind != JNull:
      client.lastCall.behaviorLogprobs = some(probabilities)
    client.lastCall.stopReason = some(sampling["stop_reason"].getStr())
    client.lastCall.decoder["sampling_evidence"] = copy(sampling)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(BabelError, "anthropic refusal")
  for contentBlock in payload["content"]:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  client.lastCall.response = result
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(BabelError, "reply cut off at max_tokens before " &
      "any JSON: " & result[0 .. min(result.high, 160)].replace("\n", " "))

proc decide*(
  client: LlmClient,
  sim: Sim,
  call: Call,
  prompt: string,
  scripted: bool
): Decision =
  ## One decision for one seat. Never raises: any failure falls back to
  ## the scripted baseline so the episode always advances.
  if scripted or client.disabled:
    return client.scriptedAction(sim, call)
  let system = systemPrompt(sim, call.seat)
  for attempt in 0 .. 1:
    var user =
      if call.kind == ckSpeak: sim.speakerPrompt(call.pair, prompt)
      else: sim.listenerPrompt(call.pair, prompt)
    if attempt > 0:
      user.add("\nYour previous reply was invalid. Respond with ONLY the " &
        "requested JSON object" &
        (if call.kind == ckSpeak: ", using only glyphs from YOUR ALPHABET."
         else: ", picking one of A, B, C, or D."))
    try:
      let payload = extractJsonObject(client.completeText(system, user, call.seat))
      var decision: Decision
      ## Reject illegal replies here so the retry carries the hint.
      var probe = sim
      if call.kind == ckSpeak:
        decision = parseSpeak(sim, call.seat, payload)
        probe.applySpeak(call.pair, decision.tokens, decision.notes, false)
      else:
        decision = parsePick(payload)
        probe.applyPick(call.pair, decision.pick, decision.notes, false)
      return decision
    except CatchableError as error:
      echo "babel llm: seat ", call.seat, " attempt ", attempt, " rejected"
      if client.disabled:
        break
  echo "babel llm: seat ", call.seat, " falling back to scripted decision"
  client.scriptedAction(sim, call)
