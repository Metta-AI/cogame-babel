## Pure game rules for Babel. No IO, no networking, no LLM — the server,
## the tests, and the wasm replay viewer all drive this same module.
##
## A `Sim` is one whole episode: the seeded alphabet and per-seat views,
## the precomputed pairing schedule with every round's targets and
## lineups, the live round's messages and picks, each seat's tallies and
## private notes, and the append-only event log. Everything random is drawn
## from the seed at `initSim`, so a replay re-derives the episode from the
## recorded speak / pick events alone.

import std/[json, random, strutils], types

export types

const
  ## An episode's whole model-call allowance (four calls per round: two
  ## speakers and two listeners). A hosted episode is killed if it outlives
  ## the platform's artifact timeout, so `rounds` is capped to this at
  ## sample time.
  EpisodeCallBudget* = 240
  CallsPerRound* = 4
  MinRounds* = 2
  ## Total spectator-pacing sleep an episode may spend, in milliseconds.
  PacingBudgetMs* = 120_000
  Seats* = 4
  Pairs* = 2
  Tokens* = 16
  MaxMessage* = 8
  LineupSize* = 4
  Scenes* = 64
  ## Abstract marks with broad font coverage (Misc Symbols / Misc
  ## Technical, all in Apple Symbols, Segoe UI Symbol, and Noto Sans
  ## Symbols), none of which reads as a circle, square, triangle, star,
  ## pentagon, hexagon, diamond, or box next to the scene cards. 16 are
  ## drawn per episode.
  GlyphPool* = [
    "⋈", "⌘", "⌗", "⌯", "♆", "♃", "♄", "♅", "⧩", "☌", "☊", "☋",
    "☿", "☤", "⚕", "⚚", "⚓", "⚔", "⚖", "⚗", "⚘", "⚜", "⚒", "☂",
    "☘", "♯", "♭", "♮", "♩", "♪", "♫", "⚑", "⚐", "☄", "☇", "☙"
  ]
  ShapeNames* = ["circle", "square", "triangle", "star"]
  ColourNames* = ["red", "blue", "green", "yellow"]
  CogNames* = [
    "Sprocket", "Gizmo", "Ratchet", "Widget", "Bolt",
    "Piston", "Flywheel", "Rivet", "Tinker", "Gasket"
  ]
  ## The three perfect matchings of four seats; round r uses M[r mod 3].
  Matchings = [
    [[0, 1], [2, 3]],
    [[0, 2], [1, 3]],
    [[0, 3], [1, 2]]
  ]

type
  CallKind* = enum
    ckRound = "round"   ## the next round needs starting (beginRound)
    ckSpeak = "speak"
    ckPick = "pick"
    ckNone = "none"     ## the episode is over

  Call* = tuple[kind: CallKind, pair, seat: int]

  Phase* = enum
    phSpeak0 = "speak0"
    phPick0 = "pick0"
    phSpeak1 = "speak1"
    phPick1 = "pick1"
    phBetween = "between"
    phDone = "done"

  RoundPlan* = object
    speakers*: array[Pairs, int]
    listeners*: array[Pairs, int]
    targets*: array[Pairs, int]               ## scene ids
    lineups*: array[Pairs, array[LineupSize, int]] ## scene ids, A-D

  Sim* = object
    config*: GameConfig
    names*: seq[string]            ## anonymous table aliases per seat
    glyphs*: seq[string]           ## the canonical alphabet, 16 glyphs
    perm*: seq[seq[int]]           ## perm[seat][token] = canonical glyph index
    inversePerm*: seq[seq[int]]    ## inversePerm[seat][glyph index] = token
    schedule*: seq[RoundPlan]      ## one plan per round, drawn at init
    round*: int                    ## round in progress / last shown; -1 before the first
    phase*: Phase
    tokens*: array[Pairs, seq[int]] ## live round: message per pair (empty = unsent)
    picks*: array[Pairs, int]      ## live round: pick per pair; -1 = unmade
    corrects*: array[Pairs, bool]  ## live round: verdict per pair
    correct*: array[Seats, int]    ## successes in rounds the seat was in
    asSpeaker*: array[Seats, int]
    asListener*: array[Seats, int]
    seatRounds*: array[Seats, int] ## rounds the seat has completed
    roundsPlayed*: int             ## rounds completed by the table
    notes*: seq[string]            ## latest private notes per seat
    done*: bool
    reason*: string                ## "complete" | "deadline"
    events*: seq[GameEvent]

# ---- Scenes -----------------------------------------------------------------

proc sceneId*(scene: Scene): int =
  scene.shape * 16 + scene.colour * 4 + scene.count

proc sceneOf*(id: int): Scene =
  if id < 0 or id >= Scenes:
    raise newException(BabelError, "bad scene id: " & $id)
  Scene(shape: id div 16, colour: (id div 4) mod 4, count: id mod 4)

proc sceneText*(id: int): string =
  ## "3 green triangles" / "1 red star".
  let scene = sceneOf(id)
  let n = scene.count + 1
  $n & " " & ColourNames[scene.colour] & " " & ShapeNames[scene.shape] &
    (if n > 1: "s" else: "")

proc lineupLetter*(index: int): string =
  $chr(ord('A') + index)

# ---- Setup ------------------------------------------------------------------

proc tableNames*(players: seq[PlayerConfig], seed: int): seq[string] =
  ## Policy display names never reach the table: every seat plays under an
  ## anonymous cog name, drawn deterministically from the seed so replays
  ## and the live table agree.
  var rng = initRand(int64(seed) * 6779 + 31)
  var pool = @CogNames
  rng.shuffle(pool)
  for index in 0 ..< players.len:
    if index < pool.len:
      result.add(pool[index])
    else:
      result.add("Cog " & $(index + 1))

proc sampleEpisode*(config: GameConfig): GameConfig =
  ## Fits the round count into one episode's call budget. Idempotent: a
  ## config that already carries the cap (a replay being re-read) is
  ## untouched.
  result = config
  if result.sampled:
    return
  result.rounds =
    max(min(config.rounds, EpisodeCallBudget div CallsPerRound), MinRounds)
  result.turnDelayMs =
    min(config.turnDelayMs, PacingBudgetMs div max(result.rounds, 1))
  result.sampled = true

proc addEvent(sim: var Sim, event: GameEvent) =
  sim.events.add(event)

proc blankEvent(kind: EventKind): GameEvent =
  GameEvent(kind: kind, round: -1, pair: -1, seat: -1, other: -1, pick: -1)

proc otherValue(rng: var Rand, value: int): int =
  ## A uniformly drawn attribute value different from `value`.
  (value + 1 + rng.rand(2)) mod 4

proc drawLineup(rng: var Rand, target: int): array[LineupSize, int] =
  ## Target plus three distractors: one sharing two attributes (near miss),
  ## one sharing one (partial), one sharing none (clear miss); shuffled.
  let t = sceneOf(target)
  var near = t
  case rng.rand(2)
  of 0: near.shape = rng.otherValue(t.shape)
  of 1: near.colour = rng.otherValue(t.colour)
  else: near.count = rng.otherValue(t.count)
  var partial = Scene(shape: rng.otherValue(t.shape),
    colour: rng.otherValue(t.colour), count: rng.otherValue(t.count))
  case rng.rand(2)
  of 0: partial.shape = t.shape
  of 1: partial.colour = t.colour
  else: partial.count = t.count
  let clear = Scene(shape: rng.otherValue(t.shape),
    colour: rng.otherValue(t.colour), count: rng.otherValue(t.count))
  var lineup = @[target, sceneId(near), sceneId(partial), sceneId(clear)]
  rng.shuffle(lineup)
  for index in 0 ..< LineupSize:
    result[index] = lineup[index]

proc drawSchedule(rng: var Rand, rounds: int): seq[RoundPlan] =
  ## Round r uses matching M[r mod 3]; within each pair (a, b) the speaker
  ## is a when (r div 3) mod 2 == 0, else b. Pair 0 holds seat 0.
  for r in 0 ..< rounds:
    var plan: RoundPlan
    let matching = Matchings[r mod 3]
    let flip = (r div 3) mod 2 == 1
    for pair in 0 ..< Pairs:
      let a = matching[pair][0]
      let b = matching[pair][1]
      plan.speakers[pair] = if flip: b else: a
      plan.listeners[pair] = if flip: a else: b
      plan.targets[pair] = rng.rand(Scenes - 1)
      plan.lineups[pair] = rng.drawLineup(plan.targets[pair])
    result.add(plan)

proc initSim*(config: GameConfig): Sim =
  if config.players.len != Seats:
    raise newException(BabelError, "babel needs exactly " & $Seats & " players")
  if config.rounds < MinRounds:
    raise newException(BabelError, "rounds must be at least " & $MinRounds)
  result = Sim(config: config, names: tableNames(config.players, config.seed))
  ## One stream for everything the seed decides: alphabet, views, schedule.
  var rng = initRand(int64(config.seed) * 7919 + 17)
  var pool = @GlyphPool
  rng.shuffle(pool)
  result.glyphs = pool[0 ..< Tokens]
  for seat in 0 ..< Seats:
    var perm = newSeq[int](Tokens)
    for token in 0 ..< Tokens:
      perm[token] = token
    rng.shuffle(perm)
    var inverse = newSeq[int](Tokens)
    for token in 0 ..< Tokens:
      inverse[perm[token]] = token
    result.perm.add(perm)
    result.inversePerm.add(inverse)
  result.schedule = rng.drawSchedule(config.rounds)
  result.round = -1
  result.phase = phBetween
  result.picks = [-1, -1]
  result.notes = newSeq[string](Seats)
  result.addEvent(blankEvent(evStart))

# ---- Queries ----------------------------------------------------------------

proc glyphOf*(sim: Sim, seat, token: int): string =
  ## How `seat` sees token `token`.
  if token < 0 or token >= Tokens:
    raise newException(BabelError, "bad token id: " & $token)
  sim.glyphs[sim.perm[seat][token]]

proc tokenOf*(sim: Sim, seat: int, glyph: string): int =
  ## The token id behind a glyph in `seat`'s view; raises on a glyph that
  ## is not in the alphabet.
  let index = sim.glyphs.find(glyph)
  if index < 0:
    raise newException(BabelError, "not a glyph of this alphabet: " & glyph)
  sim.inversePerm[seat][index]

proc messageText*(sim: Sim, seat: int, tokens: seq[int]): string =
  ## A message rendered in `seat`'s glyphs, space-separated.
  var glyphs: seq[string]
  for token in tokens:
    glyphs.add(sim.glyphOf(seat, token))
  glyphs.join(" ")

proc plan*(sim: Sim): RoundPlan =
  ## The plan of the round in progress (or last shown).
  if sim.round < 0:
    raise newException(BabelError, "no round has started")
  sim.schedule[sim.round]

proc currentCall*(sim: Sim): Call =
  ## What the episode needs next: a round start, a speaker's message, or a
  ## listener's pick.
  if sim.done:
    return (ckNone, -1, -1)
  case sim.phase
  of phBetween: (ckRound, -1, -1)
  of phSpeak0: (ckSpeak, 0, sim.plan.speakers[0])
  of phPick0: (ckPick, 0, sim.plan.listeners[0])
  of phSpeak1: (ckSpeak, 1, sim.plan.speakers[1])
  of phPick1: (ckPick, 1, sim.plan.listeners[1])
  of phDone: (ckNone, -1, -1)

proc roleOf*(sim: Sim, seat: int): string =
  ## "speaker" / "listener" in the shown round, "" before the first.
  if sim.round < 0:
    return ""
  let plan = sim.plan
  for pair in 0 ..< Pairs:
    if plan.speakers[pair] == seat: return "speaker"
    if plan.listeners[pair] == seat: return "listener"
  ""

proc partnerOf*(sim: Sim, seat: int): int =
  ## The seat paired with `seat` in the shown round; -1 before the first.
  if sim.round < 0:
    return -1
  let plan = sim.plan
  for pair in 0 ..< Pairs:
    if plan.speakers[pair] == seat: return plan.listeners[pair]
    if plan.listeners[pair] == seat: return plan.speakers[pair]
  -1

proc score*(sim: Sim, seat: int): float =
  if sim.seatRounds[seat] == 0: 0.0
  else: sim.correct[seat].float / sim.seatRounds[seat].float

# ---- Play -------------------------------------------------------------------

proc settle(sim: var Sim, reason: string) =
  sim.done = true
  sim.reason = reason
  sim.phase = phDone
  var event = blankEvent(evEnd)
  event.round = sim.roundsPlayed
  event.text = reason
  sim.addEvent(event)

proc beginRound*(sim: var Sim) =
  ## Opens the next round: logs its pairs, targets, and lineups.
  if sim.done:
    raise newException(BabelError, "the episode is over")
  if sim.phase != phBetween:
    raise newException(BabelError, "a round is already in progress")
  sim.round = sim.roundsPlayed
  sim.phase = phSpeak0
  sim.tokens = [newSeq[int](), newSeq[int]()]
  sim.picks = [-1, -1]
  sim.corrects = [false, false]
  let plan = sim.plan
  var event = blankEvent(evRound)
  event.round = sim.round
  for pair in 0 ..< Pairs:
    event.speakers.add(plan.speakers[pair])
    event.listeners.add(plan.listeners[pair])
    event.targets.add(plan.targets[pair])
    event.lineups.add(@(plan.lineups[pair]))
  sim.addEvent(event)

proc applySpeak*(sim: var Sim, pair: int, tokens: seq[int], notes: string,
    scripted: bool) =
  ## The speaker of `pair` sends its message. Raises BabelError on anything
  ## illegal; the game server falls back to the scripted baseline on a
  ## rejection.
  if sim.done:
    raise newException(BabelError, "the episode is over")
  let expected = if sim.phase == phSpeak0: 0 elif sim.phase == phSpeak1: 1
    else: -1
  if expected < 0:
    raise newException(BabelError, "no speaker is due")
  if pair != expected:
    raise newException(BabelError, "pair " & $expected & " speaks now")
  if tokens.len < 1 or tokens.len > MaxMessage:
    raise newException(BabelError,
      "a message is 1.." & $MaxMessage & " tokens")
  for token in tokens:
    if token < 0 or token >= Tokens:
      raise newException(BabelError, "bad token id: " & $token)
  let plan = sim.plan
  let speaker = plan.speakers[pair]
  sim.tokens[pair] = tokens
  if notes.len > 0:
    sim.notes[speaker] = notes
  var event = blankEvent(evSpeak)
  event.round = sim.round
  event.pair = pair
  event.seat = speaker
  event.other = plan.listeners[pair]
  event.tokens = tokens
  event.scripted = scripted
  event.text = sim.notes[speaker]
  sim.addEvent(event)
  sim.phase = if pair == 0: phPick0 else: phPick1

proc applyPick*(sim: var Sim, pair, pick: int, notes: string,
    scripted: bool) =
  ## The listener of `pair` picks A-D (0..3). Settles the tallies for both
  ## pair members and, after pair 1, closes the round.
  if sim.done:
    raise newException(BabelError, "the episode is over")
  let expected = if sim.phase == phPick0: 0 elif sim.phase == phPick1: 1
    else: -1
  if expected < 0:
    raise newException(BabelError, "no listener is due")
  if pair != expected:
    raise newException(BabelError, "pair " & $expected & " picks now")
  if pick < 0 or pick >= LineupSize:
    raise newException(BabelError, "pick must be A-D")
  let plan = sim.plan
  let speaker = plan.speakers[pair]
  let listener = plan.listeners[pair]
  let correct = plan.lineups[pair][pick] == plan.targets[pair]
  sim.picks[pair] = pick
  sim.corrects[pair] = correct
  inc sim.seatRounds[speaker]
  inc sim.seatRounds[listener]
  if correct:
    inc sim.correct[speaker]
    inc sim.correct[listener]
    inc sim.asSpeaker[speaker]
    inc sim.asListener[listener]
  if notes.len > 0:
    sim.notes[listener] = notes
  var event = blankEvent(evPick)
  event.round = sim.round
  event.pair = pair
  event.seat = listener
  event.other = speaker
  event.pick = pick
  event.correct = correct
  event.scripted = scripted
  event.text = sim.notes[listener]
  sim.addEvent(event)
  if pair == 0:
    sim.phase = phSpeak1
  else:
    inc sim.roundsPlayed
    if sim.roundsPlayed >= sim.config.rounds:
      sim.settle("complete")
    else:
      sim.phase = phBetween

proc endEarly*(sim: var Sim) =
  ## Stop now. The hosted platform kills an episode that outlives its
  ## timeout and keeps NOTHING, so a short honest episode always beats a
  ## long one that never lands. Scores use the rounds actually played.
  if sim.done:
    return
  sim.settle("deadline")

# ---- Results ----------------------------------------------------------------

proc resultsJson*(sim: Sim): JsonNode =
  var names = newJArray()
  var scoresNode = newJArray()
  var correctNode = newJArray()
  var speakerNode = newJArray()
  var listenerNode = newJArray()
  for seat in 0 ..< Seats:
    ## Results are platform-facing: the league attributes scores by POLICY
    ## name, not by the anonymous alias the seat played under.
    names.add(%sim.config.players[seat].name)
    scoresNode.add(%sim.score(seat))
    correctNode.add(%sim.correct[seat])
    speakerNode.add(%sim.asSpeaker[seat])
    listenerNode.add(%sim.asListener[seat])
  %*{
    "names": names,
    "scores": scoresNode,
    "correct": correctNode,
    "asSpeaker": speakerNode,
    "asListener": listenerNode,
    "rounds": sim.roundsPlayed,
    "maxRounds": sim.config.rounds,
    "reason": (if sim.done: sim.reason else: "")
  }

# ---- Viewer state -----------------------------------------------------------

proc pairsJson(sim: Sim): JsonNode =
  ## The round in progress (or the last completed round once done); empty
  ## before the first round.
  result = newJArray()
  if sim.round < 0:
    return
  let plan = sim.plan
  for pair in 0 ..< Pairs:
    var lineup = newJArray()
    for id in plan.lineups[pair]:
      lineup.add(%id)
    var tokens = newJNull()
    if sim.tokens[pair].len > 0:
      tokens = newJArray()
      for token in sim.tokens[pair]:
        tokens.add(%token)
    let picked = sim.picks[pair] >= 0
    result.add(%*{
      "speaker": plan.speakers[pair],
      "listener": plan.listeners[pair],
      "target": plan.targets[pair],
      "lineup": lineup,
      "tokens": tokens,
      "pick": (if picked: %sim.picks[pair] else: newJNull()),
      "correct": (if picked: %sim.corrects[pair] else: newJNull())
    })

proc tableStateJson*(sim: Sim): JsonNode =
  var seats = newJArray()
  for seat in 0 ..< Seats:
    seats.add(%*{
      "name": sim.names[seat],
      "score": sim.score(seat),
      "correct": sim.correct[seat],
      "asSpeaker": sim.asSpeaker[seat],
      "asListener": sim.asListener[seat],
      "role": sim.roleOf(seat),
      "partner": sim.partnerOf(seat),
      "notes": sim.notes[seat]
    })
  var glyphs = newJArray()
  for glyph in sim.glyphs:
    glyphs.add(%glyph)
  var perm = newJArray()
  for seat in 0 ..< Seats:
    var view = newJArray()
    for index in sim.perm[seat]:
      view.add(%index)
    perm.add(view)
  %*{
    "seats": seats,
    "round": sim.round,
    "rounds": sim.config.rounds,
    "roundsPlayed": sim.roundsPlayed,
    "glyphs": glyphs,
    "perm": perm,
    "pairs": sim.pairsJson(),
    "phase": $sim.phase,
    "gameDone": sim.done,
    "reason": sim.reason
  }

# ---- Replay -----------------------------------------------------------------

proc replayMatch*(config: GameConfig, events: seq[GameEvent]): seq[Sim] =
  ## Re-derives the state timeline from a recorded event log by replaying
  ## the speak / pick events through the rules (the schedule and alphabet
  ## come from the seed). frames[i] = state after events[0..<i]; the
  ## replayed sim's own event log mirrors the prefix so the feed lines up.
  var sim = initSim(config)
  ## initSim already logged the start event; the recorded log's first
  ## event is that same start.
  sim.events = @[]
  result.add(sim)
  for event in events:
    case event.kind
    of evStart:
      sim.events.add(event)
    of evRound:
      sim.beginRound()
      let logged = sim.events[^1]
      if event.round != logged.round or event.speakers != logged.speakers or
          event.listeners != logged.listeners or
          event.targets != logged.targets or event.lineups != logged.lineups:
        raise newException(BabelError,
          "round " & $event.round & " does not match the seeded schedule")
    of evSpeak:
      sim.applySpeak(event.pair, event.tokens, event.text, event.scripted)
    of evPick:
      sim.applyPick(event.pair, event.pick, event.text, event.scripted)
    of evEnd:
      if not sim.done:
        ## A deadline stop is not derivable from the picks alone.
        sim.settle(event.text)
    result.add(sim)

# ---- Event JSON -------------------------------------------------------------

proc eventToJson*(event: GameEvent): JsonNode =
  result = %*{"kind": $event.kind}
  if event.round >= 0:
    result["round"] = %event.round
  case event.kind
  of evStart:
    discard
  of evRound:
    var pairs = newJArray()
    for pair in 0 ..< event.speakers.len:
      var lineup = newJArray()
      for id in event.lineups[pair]:
        lineup.add(%id)
      pairs.add(%*{
        "speaker": event.speakers[pair],
        "listener": event.listeners[pair],
        "target": event.targets[pair],
        "lineup": lineup
      })
    result["pairs"] = pairs
  of evSpeak:
    result["pair"] = %event.pair
    result["seat"] = %event.seat
    result["other"] = %event.other
    var tokens = newJArray()
    for token in event.tokens:
      tokens.add(%token)
    result["tokens"] = tokens
    result["scripted"] = %event.scripted
  of evPick:
    result["pair"] = %event.pair
    result["seat"] = %event.seat
    result["other"] = %event.other
    result["pick"] = %event.pick
    result["correct"] = %event.correct
    result["scripted"] = %event.scripted
  of evEnd:
    discard
  if event.text.len > 0:
    result["text"] = %event.text

proc eventFromJson*(node: JsonNode): GameEvent =
  result = GameEvent(
    kind: parseEnum[EventKind](node["kind"].getStr()),
    round: node{"round"}.getInt(-1),
    pair: node{"pair"}.getInt(-1),
    seat: node{"seat"}.getInt(-1),
    other: node{"other"}.getInt(-1),
    pick: node{"pick"}.getInt(-1),
    correct: node{"correct"}.getBool(false),
    scripted: node{"scripted"}.getBool(false),
    text: node{"text"}.getStr("")
  )
  if node.hasKey("tokens"):
    for token in node["tokens"]:
      result.tokens.add(token.getInt())
  if node.hasKey("pairs"):
    for pair in node["pairs"]:
      result.speakers.add(pair["speaker"].getInt())
      result.listeners.add(pair["listener"].getInt())
      result.targets.add(pair["target"].getInt())
      var lineup: seq[int]
      for id in pair["lineup"]:
        lineup.add(id.getInt())
      result.lineups.add(lineup)
