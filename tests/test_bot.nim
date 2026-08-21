## The scripted baseline must play whole episodes without ever proposing
## an illegal message or pick — it is both the no-credentials fallback
## (offline certification) and a fieldable policy, so this is the
## completion path. Two scripted seats must also actually converge on the
## fixed code, or the baseline is no partner worth adapting to.

import std/[json, monotimes, times, unicode, unittest]
import babel/[llm, sim]

proc fixture(seed: int, rounds = 24): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.rounds = rounds
  result.sampled = true
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("t" & $index)

proc playScripted(config: GameConfig): Sim =
  let client = newLlmClient(config)
  result = initSim(config)
  while not result.done:
    let call = result.currentCall()
    case call.kind
    of ckRound:
      result.beginRound()
    of ckSpeak:
      let decision = client.scriptedAction(result, call)
      ## The bot's message must be legal as-is: applySpeak raises on
      ## anything else and would fail this test.
      result.applySpeak(call.pair, decision.tokens, decision.notes, true)
      check decision.notes.len == 0
    of ckPick:
      let decision = client.scriptedAction(result, call)
      result.applyPick(call.pair, decision.pick, decision.notes, true)
      check decision.notes.len == 0
    of ckNone:
      discard

suite "scripted baseline":
  test "four scripted seats play full episodes legally and fast":
    for seed in [1, 7, 42, 1234]:
      let config = fixture(seed)
      let started = getMonoTime()
      let sim = playScripted(config)
      let elapsed = (getMonoTime() - started).inMilliseconds
      check sim.done
      check sim.reason == "complete"
      check sim.roundsPlayed == config.rounds
      var picks = 0
      for event in sim.events:
        if event.kind == evPick:
          inc picks
      check picks == config.rounds * 2
      echo "seed ", seed, ": ", sim.roundsPlayed, " rounds, correct ",
        sim.correct, ", ", elapsed, " ms"
      check elapsed < config.rounds * 1000
      let results = sim.resultsJson()
      for seat in 0 ..< Seats:
        check results["scores"][seat].getFloat() >= 0.0
        check results["scores"][seat].getFloat() <= 1.0
      for seat in 0 ..< Seats:
        check sim.seatRounds[seat] == config.rounds

  test "scripted pairs converge: success above 0.75 after 12 rounds":
    var successes = 0
    var total = 0
    for seed in [1, 7, 42, 1234]:
      let sim = playScripted(fixture(seed, rounds = 24))
      for event in sim.events:
        if event.kind == evPick and event.round >= 12:
          inc total
          if event.correct:
            inc successes
    let rate = successes.float / total.float
    echo "scripted-with-scripted success after 12 rounds: ", successes, "/",
      total, " = ", rate
    check rate > 0.75

  test "decide falls back to scripted with no credentials":
    let config = fixture(3, rounds = 4)
    let client = newLlmClient(config)
    var sim = initSim(config)
    sim.beginRound()
    let spoken = client.decide(sim, sim.currentCall(), "say shape first",
      scripted = false)
    check spoken.tokens == scriptedMessage(sim.plan.targets[0])
    sim.applySpeak(0, spoken.tokens, spoken.notes, true)
    let picked = client.decide(sim, sim.currentCall(), "", scripted = false)
    sim.applyPick(0, picked.pick, picked.notes, true)
    check sim.currentCall() == (ckSpeak, 1, sim.plan.speakers[1])

  test "model replies parse through the seat's own view":
    let config = fixture(0)
    var sim = initSim(config)
    sim.beginRound()
    let seat = sim.plan.speakers[0]
    let view = sim.glyphOf(seat, 3) & " " & sim.glyphOf(seat, 9) & " " &
      sim.glyphOf(seat, 14)
    let arrayReply = parseSpeak(sim, seat, parseJson(
      """{"tokens":["""" & sim.glyphOf(seat, 3) & """","""" &
      sim.glyphOf(seat, 9) & """","""" & sim.glyphOf(seat, 14) &
      """"],"notes":"first = shape"}"""))
    check arrayReply.tokens == @[3, 9, 14]
    check arrayReply.notes == "first = shape"
    let stringReply = parseSpeak(sim, seat, parseJson(
      """{"tokens":"""" & view & """"}"""))
    check stringReply.tokens == @[3, 9, 14]
    check stringReply.notes == ""
    ## The same glyphs mean different tokens from another seat's view.
    let other = sim.plan.listeners[0]
    let crossed = parseSpeak(sim, other, parseJson(
      """{"tokens":"""" & view & """"}"""))
    check crossed.tokens != @[3, 9, 14]
    expect BabelError:
      discard parseSpeak(sim, seat, parseJson("""{"tokens":["Z"]}"""))
    expect BabelError:
      discard parseSpeak(sim, seat, parseJson(
        """{"tokens":["""" & sim.glyphOf(seat, 3) & sim.glyphOf(seat, 4) &
        """"]}"""))
    expect BabelError:
      discard parseSpeak(sim, seat, parseJson("""{"notes":"?"}"""))
    check parsePick(parseJson("""{"pick":"B"}""")).pick == 1
    check parsePick(parseJson("""{"pick":"d"}""")).pick == 3
    check parsePick(parseJson("""{"pick":"C) 3 green circles"}""")).pick == 2
    check parsePick(parseJson("""{"pick":0}""")).pick == 0
    check parsePick(parseJson("""{"pick":2}""")).pick == 2
    check parsePick(parseJson("""{"pick":4}""")).pick == 3
    check parsePick(parseJson("""{"pick":"1"}""")).pick == 1
    check parsePick(parseJson("""{"pick":"A","notes":"x"}""")).notes == "x"
    expect BabelError:
      discard parsePick(parseJson("""{"pick":"E"}"""))
    expect BabelError:
      discard parsePick(parseJson("""{"pick":7}"""))
    expect BabelError:
      discard parsePick(parseJson("""{"notes":"no pick"}"""))
    var long = ""
    for index in 0 ..< 700:
      long.add("é")
    check cleanNotes(long).runeLen == MaxNotesLen
