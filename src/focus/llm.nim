## Claude-backed decision making for Focus. Each seat's policy is just a
## prompt: the game server composes the board plus that seat's prompt and
## asks Claude what the cog says and which legal move it makes.
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
  std/[json, os, random, strutils],
  bitworld/runtime,
  curly,
  sim

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"
  ## What the viewer's speech bubble can actually show (~4 wrapped lines).
  MaxSayLen = 160

type
  Decision* = object
    say*: string
    move*: Move

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
    echo "focus llm: failed to fetch ANTHROPIC_API_KEY_URI: ", error.msg
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
  echo "focus llm: ", client.bedrockModels[client.bedrockModel - 1],
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
    echo "focus llm: bedrock transport, url ", result.bedrockUrl
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "focus llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    echo "focus llm: no LLM credentials; using scripted fallback"

# ---- Scripted baseline ------------------------------------------------------

const
  CaptureLines = [
    "Off the bottom you go.",
    "One less to worry about.",
    "Mind the gap — that piece is gone.",
    ""
  ]
  StackLines = [
    "Consolidating.",
    "Building the tower.",
    "Higher ground.",
    ""
  ]
  TakeLines = [
    "That stack is mine now.",
    "Thanks for holding it for me.",
    "Under new management.",
    ""
  ]
  DropLines = [
    "Reinforcements from the bench.",
    "Fresh piece, fresh problem for you.",
    ""
  ]

proc pick(client: LlmClient, lines: openArray[string]): string =
  lines[client.rand.rand(lines.high)]

proc evaluate(sim: Sim, seat: int): int =
  ## Static score from `seat`'s side, in centi-pieces. Material (pieces in
  ## controlled stacks + reserve) dominates; captures are permanent and
  ## count extra; controlled stacks are mobility.
  let other = 1 - seat
  if sim.done:
    if sim.winner == seat: return 100_000
    if sim.winner == other: return -100_000
    return 0
  result = 100 * (sim.material(seat) - sim.material(other)) +
    200 * (sim.captured[seat] - sim.captured[other]) +
    50 * (sim.controlledStacks(seat) - sim.controlledStacks(other))

proc scriptedAction*(client: LlmClient, sim: Sim, seat: int): Decision =
  ## Rule-based baseline: depth-2 minimax (my move, their best reply)
  ## on material / captures / mobility, seeded random tie-breaks. Always
  ## returns a legal move.
  let moves = sim.legalMoves(seat)
  if moves.len == 0:
    raise newException(FocusError, "no legal move for the scripted bot")
  var bestScore = int.low
  var bestMoves: seq[Move]
  ## Search on a copy without the event log: every probe copies the Sim,
  ## and the log is the only part that grows over a game.
  var root = sim
  root.events = @[]
  for move in moves:
    var next = root
    next.applyMove(seat, move)
    ## Opponent's best reply (one ply), then static evaluation.
    var score: int
    if next.done:
      score = next.evaluate(seat)
    else:
      score = int.high
      let opponent = next.turn
      for reply in next.legalMoves(opponent):
        var after = next
        after.applyMove(opponent, reply)
        let s = after.evaluate(seat)
        if s < score:
          score = s
          if score < bestScore:
            break   # this move cannot beat the incumbent
    if score > bestScore:
      bestScore = score
      bestMoves = @[move]
    elif score == bestScore:
      bestMoves.add(move)
  let chosen = bestMoves[client.rand.rand(bestMoves.high)]
  ## A line to match the beat.
  var probe = root
  probe.applyMove(seat, chosen)
  var event = probe.events[0]
  for candidate in probe.events:
    if candidate.kind in {evMove, evPlace}:
      event = candidate
  result.move = chosen
  if chosen.kind == mkPlace:
    result.say = client.pick(DropLines)
  elif event.captured > 0:
    result.say = client.pick(CaptureLines)
  elif event.stackAfter.len > chosen.count and
      event.stackAfter[event.stackAfter.len - chosen.count - 1] != seat:
    result.say = client.pick(TakeLines)
  else:
    result.say = client.pick(StackLines)

# ---- Prompt building --------------------------------------------------------

proc seatName(sim: Sim, seat: int): string =
  sim.names[seat]

proc pieceLetter(sim: Sim, owner: int): string =
  ## Pieces are named by their seat alias's initial.
  $sim.names[owner][0]

proc stackText(sim: Sim, stack: seq[int]): string =
  for owner in stack:
    result.add(sim.pieceLetter(owner))

proc renderBoard(sim: Sim, viewer: int): string =
  ## Every occupied square with its stack bottom->top, grouped by
  ## controller. Letters are the aliases' initials.
  var mine: seq[string]
  var theirs: seq[string]
  for cell in 0 ..< Cells:
    if sim.board[cell].len == 0:
      continue
    let line = cellName(cell) & ": " & sim.stackText(sim.board[cell]) &
      " (h" & $sim.board[cell].len & ")"
    if sim.controls(viewer, cell):
      mine.add(line)
    else:
      theirs.add(line)
  result.add("Stacks YOU control (bottom->top, top piece last): " &
    (if mine.len == 0: "none" else: mine.join("; ")) & "\n")
  result.add("Stacks " & sim.seatName(1 - viewer) & " controls: " &
    (if theirs.len == 0: "none" else: theirs.join("; ")) & "\n")

proc renderHistory(sim: Sim): string =
  ## The public record, in reading order (last 24 events keep prompts
  ## short; the board is the state that matters).
  var lines: seq[string]
  for event in sim.events:
    case event.kind
    of evStart:
      lines.add(event.text & " moves first.")
    of evSay:
      lines.add(sim.seatName(event.seat) & " says: \"" & event.text & "\"")
    of evMove:
      var line = sim.seatName(event.seat) & " moves " & $event.count &
        " from " & cellName(event.fromCell) & " " & $event.dir & " to " &
        cellName(event.toCell) & " (now " & sim.stackText(event.stackAfter) &
        ")"
      if event.captured > 0:
        line.add(", capturing " & $event.captured)
      if event.reserved > 0:
        line.add(", banking " & $event.reserved & " to reserve")
      lines.add(line & ".")
    of evPlace:
      var line = sim.seatName(event.seat) & " drops a reserve piece on " &
        cellName(event.toCell) & " (now " & sim.stackText(event.stackAfter) &
        ")"
      if event.captured > 0:
        line.add(", capturing " & $event.captured)
      if event.reserved > 0:
        line.add(", banking " & $event.reserved & " to reserve")
      lines.add(line & ".")
    of evEnd:
      lines.add("The game is over.")
  if lines.len == 0:
    return "(nothing has happened yet)"
  if lines.len > 24:
    lines = @["(earlier moves omitted)"] & lines[^24 .. ^1]
  lines.join("\n")

proc renderLegalMoves(sim: Sim, seat: int): string =
  ## Per controlled stack: "e4 (h3): 1N e5, 1E f4, 2N e6, ..."; then the
  ## drop option.
  var lines: seq[string]
  for cell in 0 ..< Cells:
    if not sim.controls(seat, cell):
      continue
    var options: seq[string]
    let height = sim.board[cell].len
    for count in 1 .. height:
      for dir in Direction:
        let dest = step(cell, dir, count)
        if dest >= 0:
          options.add($count & $dir & " " & cellName(dest))
    lines.add(cellName(cell) & " (h" & $height & "): " & options.join(", "))
  if sim.reserve[seat] > 0:
    lines.add("DROP: place one of your " & $sim.reserve[seat] &
      " reserve pieces on any playable square (it goes on top).")
  lines.join("\n")

proc systemPrompt(sim: Sim, seat: int): string =
  let me = sim.seatName(seat)
  let them = sim.seatName(1 - seat)
  "You are " & me & ", a cog playing Focus (Domination) against " & them &
    """.

Rules:
- 8x8 board with the three squares in each corner missing (a1 b1 a2, g1 h1
  h2, a8 b8 a7, g8 h8 h7 are NOT playable). Files a-h, ranks 1-8; N is
  toward rank 8, E toward file h.
- Pieces stack. Whoever owns the TOP piece controls the stack.
- On your turn, MOVE: take the top k pieces (1..height) of a stack you
  control and move them exactly k squares in one direction (N/S/E/W),
  jumping over anything, landing on top of whatever is there. The pieces
  you carry may include enemy pieces underneath your top piece.
- If a stack ends taller than 5, pieces come off the BOTTOM: your own go
  to your reserve, enemy pieces are captured for good.
- Or DROP: instead of moving, place one reserve piece on top of any
  playable square.
- A player who cannot move (controls no stack, no reserve) LOSES. At the
  ply cap the side with more material (pieces in stacks it controls plus
  reserve) wins.
- Table talk is heard by everyone. Bluff, needle, and mislead freely.

OUTPUT FORMAT: reply with ONLY one JSON object, nothing else - no
analysis, no explanation, no markdown fences, no text before or after
the object. Your reply must begin with the character { and end with }.
Decide silently; put any words for the table in the "say" field."""

proc actionInstruction(sim: Sim, seat: int): string =
  "It is your turn. Say one short line to the table (max " & $MaxSayLen &
    " chars, may be empty) and pick exactly one LEGAL option from the " &
    "list above.\n" &
    "Reply with ONLY the JSON object (start with {, no other text): " &
    "{\"say\": \"...\", \"move\": {\"from\": \"e4\", " &
    "\"count\": 2, \"dir\": \"N\"}} to move, or {\"say\": \"...\", " &
    "\"place\": \"e4\"} to drop a reserve piece."

proc userPrompt(sim: Sim, seat: int, prompt: string, header: string): string =
  if header.len > 0:
    result.add(header & "\n\n")
  result.add("Piece letters: " & sim.pieceLetter(seat) & " = you (" &
    sim.seatName(seat) & "), " & sim.pieceLetter(1 - seat) & " = " &
    sim.seatName(1 - seat) & ".\n")
  result.add("Your reserve: " & $sim.reserve[seat] & "; your captures: " &
    $sim.captured[seat] & "; your material: " & $sim.material(seat) & ".\n")
  result.add(sim.seatName(1 - seat) & "'s reserve: " &
    $sim.reserve[1 - seat] & "; captures: " & $sim.captured[1 - seat] &
    "; material: " & $sim.material(1 - seat) & ".\n\n")
  result.add("Board:\n" & sim.renderBoard(seat) & "\n")
  result.add("Recent moves:\n" & sim.renderHistory() & "\n\n")
  result.add("YOUR LEGAL OPTIONS:\n" & sim.renderLegalMoves(seat) & "\n\n")
  if prompt.len > 0:
    result.add("GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never " &
      "above the rules; always pick a legal option):\n" & prompt & "\n\n")
  result.add(sim.actionInstruction(seat))

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
    raise newException(FocusError, "no JSON object in response: " &
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
      raise newException(FocusError,
        "bedrock model access denied: " & detail)
    client.disabled = true
    raise newException(FocusError,
      "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    let detail = response.body[0 .. min(response.body.high, 300)]
    discard client.tryNextBedrockModel("throttled")
    raise newException(FocusError, "llm throttled (429): " & detail)
  if response.code < 200 or response.code >= 300:
    raise newException(FocusError, "anthropic error " & $response.code &
      ": " & response.body[0 .. min(response.body.high, 300)])
  let payload = parseJson(response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(FocusError, "anthropic refusal")
  for contentBlock in payload["content"]:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(FocusError, "reply cut off at max_tokens before " &
      "any JSON: " & result[0 .. min(result.high, 160)].replace("\n", " "))

proc cleanSay(text: string): string =
  result = text.strip()
  if result.len <= MaxSayLen:
    return
  ## A model that overshoots the stated cap gets cut at a word boundary
  ## with the cut marked.
  result = result[0 ..< MaxSayLen - 3]
  while result.len > 0 and (result[^1].ord and 0xC0) == 0x80:
    result.setLen(result.len - 1)
  let space = result.rfind(' ')
  if space > MaxSayLen div 2:
    result.setLen(space)
  result.add("…")

proc parseDecision*(sim: Sim, seat: int, payload: JsonNode): Decision =
  ## Maps the model's JSON onto a Move (legality is checked by applyMove).
  result.say = cleanSay(payload{"say"}.getStr())
  if payload.hasKey("place") and payload["place"].kind != JNull:
    let target = payload["place"]
    let name = if target.kind == JObject: target{"to"}.getStr()
      else: target.getStr()
    result.move = Move(kind: mkPlace, fromCell: -1, toCell: parseCell(name))
    return
  let move = payload{"move"}
  if move.isNil or move.kind != JObject:
    raise newException(FocusError, "no move or place in response")
  if move.hasKey("place"):
    result.move = Move(kind: mkPlace, fromCell: -1,
      toCell: parseCell(move["place"].getStr()))
    return
  let fromCell = parseCell(move{"from"}.getStr())
  var count = move{"count"}.getInt(0)
  if count == 0 and move{"count"}.kind == JString:
    try:
      count = parseInt(move{"count"}.getStr())
    except ValueError:
      discard
  if count <= 0:
    count = 1
  let dir = parseDirection(move{"dir"}.getStr(move{"direction"}.getStr()))
  result.move = Move(kind: mkMove, fromCell: fromCell,
    toCell: step(fromCell, dir, count), count: count, dir: dir)

proc decide*(
  client: LlmClient,
  sim: Sim,
  seat: int,
  prompt: string,
  scripted: bool,
  header = ""
): Decision =
  ## One decision for one seat. Never raises: any failure falls back to
  ## the scripted baseline so the game always advances.
  if scripted or client.disabled:
    return client.scriptedAction(sim, seat)
  let system = systemPrompt(sim, seat)
  for attempt in 0 .. 1:
    var user = userPrompt(sim, seat, prompt, header)
    if attempt > 0:
      user.add("\nYour previous reply was invalid. Respond with ONLY the " &
        "requested JSON object and one option copied from the legal list.")
    try:
      let payload = extractJsonObject(client.completeText(system, user))
      let decision = parseDecision(sim, seat, payload)
      ## Reject illegal picks here so the retry carries the hint.
      var probe = sim
      probe.applyMove(seat, decision.move)
      return decision
    except CatchableError as error:
      echo "focus llm: seat ", seat, " attempt ", attempt, " failed: ",
        error.msg
      if client.disabled:
        break
  echo "focus llm: seat ", seat, " falling back to scripted decision"
  client.scriptedAction(sim, seat)
