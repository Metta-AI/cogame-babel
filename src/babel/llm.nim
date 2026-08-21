## Claude-backed decision making for Babel. Each seat's policy is just a
## prompt: the game server composes the seat's view (alphabet, notes,
## history, and the target or the message plus lineup) plus that seat's
## prompt and asks Claude what it sends or which card it picks.
##
## Credentials, in order of preference:
##   Bedrock sidecar / bearer token   - hosted pods
##   ANTHROPIC_API_KEY                - the key itself
##   ANTHROPIC_API_KEY_URI            - a URI holding the key
## With no credentials every decision falls back to the always-legal
## scripted baseline immediately (no retries, no network waits) so offline
## certification still completes - this fallback is load-bearing. The same
## scripted bot is also a fieldable policy: a player that registers as
## scripted plays it deliberately, LLM or not.

import
  std/[json, os, random, strutils, tables, unicode],
  bitworld/runtime,
  curly,
  sim

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"
  ## The private dictionary a seat may carry between rounds.
  MaxNotesLen* = 600

type
  Decision* = object
    tokens*: seq[int]   ## speaker: the message, token ids
    pick*: int          ## listener: 0..3
    notes*: string      ## "" when the reply carried none

  LlmTransport = enum
    ltNone, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl: Curly
    transport: LlmTransport
    apiKey: string          ## anthropic transport
    bedrockEndpoint: string ## bedrock transport: sidecar or public host
    bedrockModels: seq[string]  ## candidates, tried in order on denial
    bedrockModel: int           ## index into bedrockModels
    bedrockToken: string
    model: string
    maxOutputTokens: int
    timeoutSeconds: int
    disabled: bool    ## true once credentials are known-unavailable
    rand: Rand

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

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: config.model,
    maxOutputTokens: config.maxOutputTokens,
    timeoutSeconds: config.llmTimeoutSeconds,
    rand: initRand(config.seed xor 0x5EED)
  )
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

# ---- Scripted baseline ------------------------------------------------------

const
  ## Attribute-value slots for the decoder's association counts: shapes
  ## 0..3, colours 4..7, counts 8..11.
  AttributeSlots = 12

proc attributeSlots(scene: Scene): array[3, int] =
  [scene.shape, 4 + scene.colour, 8 + scene.count]

proc scriptedMessage*(target: int): seq[int] =
  ## The fixed compositional code on token ids: shape, then 4 + colour,
  ## then 8 + count.
  let slots = attributeSlots(sceneOf(target))
  @[slots[0], slots[1], slots[2]]

proc associations(sim: Sim, seat: int):
    array[Tokens, array[AttributeSlots, int]] =
  ## assoc[token][attribute value] counts from this seat's own feedback:
  ## every completed round it was in (either role, any partner) credits
  ## the revealed target's three values to every token of that round's
  ## message. Evidence is pooled across partners rather than keyed per
  ## partner alias: a seat meets each partner only twice per six rounds,
  ## and per-partner tables were measured to reach only ~0.58 success by
  ## round 12 against the ~0.89 of the pooled table.
  var messages: Table[(int, int), seq[int]]
  for event in sim.events:
    case event.kind
    of evSpeak:
      messages[(event.round, event.pair)] = event.tokens
    of evPick:
      if seat != event.seat and seat != event.other:
        continue
      let target = sim.schedule[event.round].targets[event.pair]
      let message = messages.getOrDefault((event.round, event.pair))
      for token in message:
        for slot in attributeSlots(sceneOf(target)):
          inc result[token][slot]
    else:
      discard

proc scriptedPick*(client: LlmClient, sim: Sim, pair: int): int =
  ## Count-based decoder: scores each candidate by the summed association
  ## of the message's tokens with the candidate's three values; ties
  ## (including the no-evidence start) break by the seeded RNG.
  let plan = sim.plan
  let assoc = sim.associations(plan.listeners[pair])
  var best = int.low
  var bestPicks: seq[int]
  for index in 0 ..< LineupSize:
    var score = 0
    for token in sim.tokens[pair]:
      for slot in attributeSlots(sceneOf(plan.lineups[pair][index])):
        score += assoc[token][slot]
    if score > best:
      best = score
      bestPicks = @[index]
    elif score == best:
      bestPicks.add(index)
  bestPicks[client.rand.rand(bestPicks.high)]

proc scriptedAction*(client: LlmClient, sim: Sim, call: Call): Decision =
  ## Rule-based baseline: the fixed code as speaker, the count decoder as
  ## listener. Always legal; never produces notes.
  case call.kind
  of ckSpeak:
    result.tokens = scriptedMessage(sim.plan.targets[call.pair])
  of ckPick:
    result.pick = client.scriptedPick(sim, call.pair)
  else:
    raise newException(BabelError, "no decision is due")

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

proc systemPrompt(sim: Sim, seat: int): string =
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

proc speakerPrompt(sim: Sim, pair: int, prompt: string): string =
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

proc listenerPrompt(sim: Sim, pair: int, prompt: string): string =
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

proc extractJsonObject(text: string): JsonNode =
  ## Pulls the first {...} object out of a model response, tolerating fences.
  let start = text.find('{')
  let stop = text.rfind('}')
  if start < 0 or stop <= start:
    ## Quote the head of the reply so a hosted log shows WHAT the model
    ## sent instead of JSON (prose, a refusal, a cut-off analysis...).
    var head = text.strip()
    if head.len > 160:
      head = head[0 ..< 160] & "..."
    raise newException(BabelError, "no JSON object in response: " &
      head.replace("\n", " "))
  parseJson(text[start .. stop])

proc completeText(client: LlmClient, system, user: string): string =
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  var url: string
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    url = client.bedrockUrl()
  else:
    body["model"] = %client.model
    ## Only the Claude 5 / Opus tiers accept an effort setting; Haiku 4.5
    ## rejects the whole request with a 400 if it is present.
    if "haiku" notin client.model and "4-5" notin client.model:
      body["output_config"] = %*{"effort": "low"}
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    url = AnthropicUrl
  let response = client.curl.post(url, headers, $body, client.timeoutSeconds)
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
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(BabelError, "anthropic refusal")
  for contentBlock in payload["content"]:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(BabelError, "reply cut off at max_tokens before " &
      "any JSON: " & result[0 .. min(result.high, 160)].replace("\n", " "))

proc cleanNotes*(text: string): string =
  ## Notes over the cap are cut at a rune boundary with the cut marked.
  result = text.strip()
  if result.runeLen <= MaxNotesLen:
    return
  result = result.runeSubStr(0, MaxNotesLen - 1) & "…"

proc parseSpeak*(sim: Sim, seat: int, payload: JsonNode): Decision =
  ## Maps the model's JSON onto token ids through the seat's own view:
  ## "tokens" is an array of single glyphs, or one string of glyphs
  ## separated by spaces. Any glyph outside the alphabet is an invalid
  ## reply. Length is checked by applySpeak.
  result.notes = cleanNotes(payload{"notes"}.getStr())
  let node = payload{"tokens"}
  var glyphs: seq[string]
  if node.isNil:
    raise newException(BabelError, "no tokens in response")
  case node.kind
  of JArray:
    for entry in node:
      if entry.kind != JString:
        raise newException(BabelError, "tokens must be glyph strings")
      glyphs.add(entry.getStr().strip())
  of JString:
    for part in strutils.splitWhitespace(node.getStr()):
      glyphs.add(part)
  else:
    raise newException(BabelError, "tokens must be an array of glyphs")
  for glyph in glyphs:
    if glyph.runeLen != 1:
      raise newException(BabelError,
        "each token must be exactly one glyph: " & glyph)
    result.tokens.add(sim.tokenOf(seat, glyph))

proc parsePick*(payload: JsonNode): Decision =
  ## "pick" is a letter A-D (any case, trailing text tolerated), or an
  ## integer: 0..3 as an index, 4 as the 1-based D.
  result.notes = cleanNotes(payload{"notes"}.getStr())
  let node = payload{"pick"}
  if node.isNil:
    raise newException(BabelError, "no pick in response")
  var pick = -1
  case node.kind
  of JInt:
    pick = node.getInt()
    if pick == LineupSize:
      pick = LineupSize - 1
  of JString:
    let text = node.getStr().strip()
    if text.len == 0:
      raise newException(BabelError, "empty pick")
    let head = text[0].toUpperAscii()
    if head in 'A' .. 'D':
      pick = ord(head) - ord('A')
    elif head in '0' .. '9':
      pick = ord(head) - ord('0')
      if pick == LineupSize:
        pick = LineupSize - 1
  else:
    discard
  if pick < 0 or pick >= LineupSize:
    raise newException(BabelError, "pick must be A-D: " & $node)
  result.pick = pick

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
      let payload = extractJsonObject(client.completeText(system, user))
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
      echo "babel llm: seat ", call.seat, " attempt ", attempt, " failed: ",
        error.msg
      if client.disabled:
        break
  echo "babel llm: seat ", call.seat, " falling back to scripted decision"
  client.scriptedAction(sim, call)
