import std/[json, sets, unittest]
import babel/sim

proc fixtureConfig(rounds = 24, seed = 0): GameConfig =
  result = defaultGameConfig()
  result.rounds = rounds
  result.seed = seed
  ## Pinned, so these tests exercise the rules rather than the budget cap.
  result.sampled = true
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("token-" & $index)

proc sharedAttributes(a, b: Scene): int =
  (if a.shape == b.shape: 1 else: 0) +
    (if a.colour == b.colour: 1 else: 0) +
    (if a.count == b.count: 1 else: 0)

proc playRound(sim: var Sim, pickTarget = true) =
  ## Drives one whole round: both speakers send a fixed code, both
  ## listeners pick the target (or A when `pickTarget` is false).
  sim.beginRound()
  for pair in 0 ..< 2:
    let plan = sim.schedule[sim.round]
    let scene = sceneOf(plan.targets[pair])
    sim.applySpeak(pair, @[scene.shape, 4 + scene.colour, 8 + scene.count],
      "", scripted = true)
    var pick = 0
    if pickTarget:
      for index in 0 ..< LineupSize:
        if plan.lineups[pair][index] == plan.targets[pair]:
          pick = index
    sim.applyPick(pair, pick, "", scripted = true)

suite "schedule":
  test "every ordered speaker->listener relation occurs once per 6 rounds":
    let sim = initSim(fixtureConfig(rounds = 24, seed = 3))
    check sim.schedule.len == 24
    for pass in 0 ..< 4:
      var seen = initHashSet[(int, int)]()
      for r in pass * 6 ..< pass * 6 + 6:
        let plan = sim.schedule[r]
        for pair in 0 ..< 2:
          check plan.speakers[pair] != plan.listeners[pair]
          seen.incl((plan.speakers[pair], plan.listeners[pair]))
        ## Each seat plays exactly once per round.
        var seats = initHashSet[int]()
        for pair in 0 ..< 2:
          seats.incl(plan.speakers[pair])
          seats.incl(plan.listeners[pair])
        check seats.len == Seats
      check seen.len == 12

  test "pair 0 is the pair containing seat 0, and the roles alternate":
    let sim = initSim(fixtureConfig(rounds = 12, seed = 9))
    for r in 0 ..< 12:
      let plan = sim.schedule[r]
      check plan.speakers[0] == 0 or plan.listeners[0] == 0
    ## Round 0: M0 with seat 0 speaking; round 3: M0 with seat 0 listening.
    check sim.schedule[0].speakers[0] == 0
    check sim.schedule[0].listeners[0] == 1
    check sim.schedule[0].speakers[1] == 2
    check sim.schedule[0].listeners[1] == 3
    check sim.schedule[1].listeners[0] == 2
    check sim.schedule[2].listeners[0] == 3
    check sim.schedule[3].speakers[0] == 1
    check sim.schedule[3].listeners[0] == 0
    check sim.schedule[3].speakers[1] == 3
    check sim.schedule[3].listeners[1] == 2

suite "scenes":
  test "scene ids round-trip and read as text":
    for id in 0 ..< 64:
      let scene = sceneOf(id)
      check sceneId(scene) == id
      check scene.shape in 0 .. 3
      check scene.colour in 0 .. 3
      check scene.count in 0 .. 3
    check sceneId(Scene(shape: 2, colour: 2, count: 2)) == 42
    check sceneText(42) == "3 green triangles"
    check sceneText(sceneId(Scene(shape: 3, colour: 0, count: 0))) ==
      "1 red star"
    check sceneText(0) == "1 red circle"
    check sceneText(63) == "4 yellow stars"

  test "lineups hold the target, a near miss, a partial, and a clear miss":
    for seed in [0, 1, 7, 42, 1234]:
      let sim = initSim(fixtureConfig(rounds = 24, seed = seed))
      for plan in sim.schedule:
        for pair in 0 ..< 2:
          let lineup = plan.lineups[pair]
          let target = plan.targets[pair]
          check lineup.len == LineupSize
          check target in lineup
          var uniq = initHashSet[int]()
          var shared: seq[int]
          for id in lineup:
            check id in 0 ..< 64
            uniq.incl(id)
            if id != target:
              shared.add(sharedAttributes(sceneOf(id), sceneOf(target)))
          check uniq.len == LineupSize
          check shared.len == 3
          check 2 in shared
          check 1 in shared
          check 0 in shared

suite "alphabet":
  test "16 distinct glyphs drawn from the pool":
    let sim = initSim(fixtureConfig(seed = 7))
    check sim.glyphs.len == Tokens
    var seen = initHashSet[string]()
    for glyph in sim.glyphs:
      check glyph in GlyphPool
      seen.incl(glyph)
    check seen.len == Tokens
    check GlyphPool.len >= 32

  test "the pool holds no shape-like symbols":
    ## Anything that reads as a circle, square, triangle, star, pentagon,
    ## hexagon, diamond, or box would look like a scene icon on the stage.
    const Forbidden = [
      "⟁", "⬠", "⬟", "⊞", "⊠", "◬", "✶", "✹", "❂", "✦", "⍟", "⬢", "⬡",
      "⬣", "⧊", "⧎", "⛤", "⛥", "⛦", "⛧", "⛛", "⧖", "⧲", "⊕", "⊗", "☖",
      "⏣", "⌬", "⟐", "⟠", "⧫", "⟡", "❖", "⚴", "⚼", "⚝", "○", "●", "□",
      "■", "△", "▲", "▽", "▼", "☆", "★", "◇", "◆", "◯", "◻", "◼", "⬜",
      "⬛", "⭐", "✪", "✫", "✬", "✭", "✮", "✯", "✰", "⬢", "⬣", "⌖", "⌲",
      "⍥", "⍧", "♇", "☍"
    ]
    var seen = initHashSet[string]()
    for glyph in GlyphPool:
      check glyph notin Forbidden
      check glyph.len > 1          # a multi-byte symbol, not ASCII
      seen.incl(glyph)
    check seen.len == GlyphPool.len

  test "per-seat views are permutations that invert through tokenOf":
    let sim = initSim(fixtureConfig(seed = 7))
    check sim.perm.len == Seats
    for seat in 0 ..< Seats:
      check sim.perm[seat].len == Tokens
      var covered = initHashSet[int]()
      for token in 0 ..< Tokens:
        covered.incl(sim.perm[seat][token])
        check sim.tokenOf(seat, sim.glyphOf(seat, token)) == token
        check sim.perm[seat][sim.inversePerm[seat][token]] == token
      check covered.len == Tokens
    check sim.perm[0] != sim.perm[1]
    check sim.perm[1] != sim.perm[2]
    check sim.perm[2] != sim.perm[3]
    check sim.perm[0] != sim.perm[3]
    expect BabelError:
      discard sim.tokenOf(0, "Z")

suite "play":
  test "the first call is a round start; speak then pick per pair":
    var sim = initSim(fixtureConfig(seed = 0))
    check sim.events.len == 1
    check sim.events[0].kind == evStart
    check sim.round == -1
    check sim.currentCall().kind == ckRound
    check sim.tableStateJson()["phase"].getStr() == "between"
    check sim.tableStateJson()["pairs"].len == 0
    sim.beginRound()
    check sim.round == 0
    check sim.events[^1].kind == evRound
    check sim.events[^1].speakers == @[0, 2]
    check sim.events[^1].listeners == @[1, 3]
    check sim.currentCall() == (ckSpeak, 0, 0)
    check sim.tableStateJson()["phase"].getStr() == "speak0"
    sim.applySpeak(0, @[1, 2, 3], "shape first", scripted = false)
    check sim.currentCall() == (ckPick, 0, 1)
    check sim.notes[0] == "shape first"
    check sim.events[^1].kind == evSpeak
    check sim.events[^1].text == "shape first"
    check sim.events[^1].tokens == @[1, 2, 3]
    check sim.tableStateJson()["phase"].getStr() == "pick0"
    sim.applyPick(0, 2, "", scripted = false)
    check sim.currentCall() == (ckSpeak, 1, 2)
    check sim.tableStateJson()["phase"].getStr() == "speak1"
    sim.applySpeak(1, @[0], "", scripted = true)
    check sim.currentCall() == (ckPick, 1, 3)
    sim.applyPick(1, 0, "listen closely", scripted = true)
    check sim.notes[3] == "listen closely"
    check sim.roundsPlayed == 1
    check sim.currentCall().kind == ckRound
    check sim.tableStateJson()["phase"].getStr() == "between"
    ## Notes persist when a later reply carries none, and overwrite when
    ## it does.
    sim.beginRound()
    sim.applySpeak(0, @[5], "", scripted = false)
    check sim.notes[2] == ""
    check sim.notes[0] == "shape first"
    sim.applyPick(0, 1, "", scripted = false)
    check sim.notes[0] == "shape first"

  test "illegal speaks and picks are rejected and change nothing":
    var sim = initSim(fixtureConfig(seed = 0))
    expect BabelError:
      sim.applySpeak(0, @[1], "", scripted = false)   # no round yet
    sim.beginRound()
    expect BabelError:
      sim.beginRound()                                # round already live
    expect BabelError:
      sim.applySpeak(1, @[1], "", scripted = false)   # pair 0 speaks first
    expect BabelError:
      sim.applyPick(0, 0, "", scripted = false)       # nothing said yet
    expect BabelError:
      sim.applySpeak(0, @[], "", scripted = false)    # empty message
    expect BabelError:
      sim.applySpeak(0, @[1, 2, 3, 4, 5, 6, 7, 8, 9], "", scripted = false)
    expect BabelError:
      sim.applySpeak(0, @[16], "", scripted = false)  # token out of range
    expect BabelError:
      sim.applySpeak(0, @[-1], "", scripted = false)
    check sim.events.len == 2
    sim.applySpeak(0, @[0, 1, 2, 3, 4, 5, 6, 7], "", scripted = false)
    expect BabelError:
      sim.applySpeak(0, @[1], "", scripted = false)   # already spoken
    expect BabelError:
      sim.applyPick(1, 0, "", scripted = false)       # wrong pair
    expect BabelError:
      sim.applyPick(0, 4, "", scripted = false)
    expect BabelError:
      sim.applyPick(0, -1, "", scripted = false)
    check sim.events.len == 3
    check sim.currentCall() == (ckPick, 0, 1)

  test "tallies and scores follow the picks":
    var sim = initSim(fixtureConfig(rounds = 4, seed = 5))
    sim.playRound(pickTarget = true)
    for seat in 0 ..< Seats:
      check sim.correct[seat] == 1
      check sim.seatRounds[seat] == 1
    check sim.asSpeaker == [1, 0, 1, 0]
    check sim.asListener == [0, 1, 0, 1]
    check sim.events[^1].kind == evPick
    check sim.events[^1].correct
    check sim.events[^3].kind == evPick
    ## Round 1 (M1: (0,2),(1,3), seats 0 and 1 speak): both listeners miss
    ## unless A happens to be the target.
    sim.beginRound()
    for pair in 0 ..< 2:
      let plan = sim.schedule[1]
      sim.applySpeak(pair, @[9], "", scripted = true)
      var wrong = 0
      while plan.lineups[pair][wrong] == plan.targets[pair]:
        inc wrong
      sim.applyPick(pair, wrong, "", scripted = true)
    check not sim.events[^1].correct
    for seat in 0 ..< Seats:
      check sim.correct[seat] == 1
      check sim.seatRounds[seat] == 2
    let state = sim.tableStateJson()
    check state["seats"][0]["score"].getFloat() == 0.5
    check state["seats"][0]["correct"].getInt() == 1
    check state["round"].getInt() == 1
    check state["roundsPlayed"].getInt() == 2
    check state["rounds"].getInt() == 4
    check state["pairs"][0]["correct"].getBool() == false
    check state["pairs"][0]["pick"].getInt() >= 0
    check state["glyphs"].len == Tokens
    check state["perm"].len == Seats
    check not state["gameDone"].getBool()
    ## Seat roles follow the live round.
    check state["seats"][0]["role"].getStr() == "speaker"
    check state["seats"][0]["partner"].getInt() == 2
    check state["seats"][2]["role"].getStr() == "listener"

  test "the last round completes the episode":
    var sim = initSim(fixtureConfig(rounds = 2, seed = 11))
    sim.playRound(pickTarget = true)
    check not sim.done
    sim.playRound(pickTarget = false)
    check sim.done
    check sim.reason == "complete"
    check sim.roundsPlayed == 2
    check sim.events[^1].kind == evEnd
    check sim.events[^1].text == "complete"
    check sim.events[^1].round == 2
    check sim.currentCall().kind == ckNone
    check sim.tableStateJson()["phase"].getStr() == "done"
    check sim.tableStateJson()["pairs"].len == 2
    expect BabelError:
      sim.beginRound()
    let results = sim.resultsJson()
    check results["reason"].getStr() == "complete"
    check results["rounds"].getInt() == 2
    check results["maxRounds"].getInt() == 2
    check results["names"].len == Seats
    check results["names"][0].getStr() == "P1"
    for seat in 0 ..< Seats:
      let expected = results["correct"][seat].getInt().float / 2.0
      check abs(results["scores"][seat].getFloat() - expected) < 1e-9
      check results["asSpeaker"][seat].getInt() +
        results["asListener"][seat].getInt() ==
        results["correct"][seat].getInt()

  test "endEarly stops a live episode on the deadline":
    var sim = initSim(fixtureConfig(rounds = 8, seed = 2))
    sim.playRound()
    sim.playRound()
    sim.endEarly()
    check sim.done
    check sim.reason == "deadline"
    check sim.roundsPlayed == 2
    check sim.events[^1].kind == evEnd
    check sim.events[^1].round == 2
    let before = sim.events.len
    sim.endEarly()                # idempotent
    check sim.events.len == before
    let results = sim.resultsJson()
    check results["reason"].getStr() == "deadline"
    check results["rounds"].getInt() == 2
    check results["scores"][0].getFloat() == 1.0
    expect BabelError:
      sim.beginRound()

  test "a fresh episode scores zero, not NaN":
    let sim = initSim(fixtureConfig(seed = 0))
    let results = sim.resultsJson()
    for seat in 0 ..< Seats:
      check results["scores"][seat].getFloat() == 0.0
    check results["reason"].getStr() == ""
    check sim.tableStateJson()["seats"][0]["score"].getFloat() == 0.0

suite "replay":
  test "re-deriving frames from the event log reproduces the episode":
    var sim = initSim(fixtureConfig(rounds = 7, seed = 5))
    var rng = 11
    while not sim.done:
      let call = sim.currentCall()
      rng = (rng * 1103515245 + 12345) mod 2147483648
      case call.kind
      of ckRound:
        sim.beginRound()
      of ckSpeak:
        var tokens: seq[int]
        for index in 0 .. rng mod MaxMessage:
          tokens.add((rng div (index + 1)) mod Tokens)
        sim.applySpeak(call.pair, tokens,
          (if rng mod 3 == 0: "note " & $rng else: ""), rng mod 2 == 0)
      of ckPick:
        sim.applyPick(call.pair, rng mod LineupSize,
          (if rng mod 5 == 0: "dict " & $rng else: ""), rng mod 2 == 1)
      of ckNone:
        discard
    var events: seq[GameEvent]
    for event in sim.events:
      events.add(eventFromJson(event.eventToJson()))
    let frames = replayMatch(sim.config, events)
    check frames.len == events.len + 1
    check frames[^1].done
    check frames[^1].reason == sim.reason
    check frames[^1].correct == sim.correct
    check frames[^1].notes == sim.notes
    check $frames[^1].tableStateJson() == $sim.tableStateJson()
    check frames[0].round == -1
    check frames[0].events.len == 0
    check frames[1].events.len == 1
    ## The replayed log mirrors the recorded one (the final pick settles
    ## the episode, so its frame already carries the end event).
    check frames[^1].events.len == events.len
    check frames[^1].events[^1].kind == evEnd

  test "a deadline end is settled from the log":
    var sim = initSim(fixtureConfig(rounds = 9, seed = 8))
    sim.playRound()
    sim.beginRound()
    sim.applySpeak(0, @[2], "", scripted = true)
    sim.endEarly()
    var events: seq[GameEvent]
    for event in sim.events:
      events.add(eventFromJson(event.eventToJson()))
    let frames = replayMatch(sim.config, events)
    check frames[^1].done
    check frames[^1].reason == "deadline"
    check $frames[^1].tableStateJson() == $sim.tableStateJson()

  test "a log from another seed is rejected":
    var sim = initSim(fixtureConfig(rounds = 4, seed = 1))
    sim.playRound()
    var other = fixtureConfig(rounds = 4, seed = 2)
    expect BabelError:
      discard replayMatch(other, sim.events)

  test "event JSON round-trips":
    var sim = initSim(fixtureConfig(seed = 0))
    sim.beginRound()
    let roundEvent = sim.events[^1]
    let roundJson = roundEvent.eventToJson()
    check roundJson["pairs"].len == 2
    check roundJson["pairs"][0]["speaker"].getInt() == 0
    check roundJson["pairs"][0]["lineup"].len == 4
    check not roundJson.hasKey("seat")
    let roundBack = eventFromJson(roundJson)
    check roundBack.kind == evRound
    check roundBack.round == 0
    check roundBack.speakers == roundEvent.speakers
    check roundBack.listeners == roundEvent.listeners
    check roundBack.targets == roundEvent.targets
    check roundBack.lineups == roundEvent.lineups
    sim.applySpeak(0, @[3, 9, 14], "✦ means red", scripted = false)
    let speak = sim.events[^1].eventToJson()
    check speak["kind"].getStr() == "speak"
    check speak["pair"].getInt() == 0
    check speak["seat"].getInt() == 0
    check speak["other"].getInt() == 1
    check speak["tokens"].len == 3
    check speak["scripted"].getBool() == false
    check speak["text"].getStr() == "✦ means red"
    check not speak.hasKey("pick")
    let speakBack = eventFromJson(speak)
    check speakBack.tokens == @[3, 9, 14]
    check speakBack.other == 1
    sim.applyPick(0, 1, "", scripted = true)
    let pick = sim.events[^1].eventToJson()
    check pick["kind"].getStr() == "pick"
    check pick["seat"].getInt() == 1
    check pick["other"].getInt() == 0
    check pick["pick"].getInt() == 1
    check pick["scripted"].getBool()
    check pick.hasKey("correct")
    check not pick.hasKey("text")
    let pickBack = eventFromJson(pick)
    check pickBack.pick == 1
    check pickBack.correct == sim.events[^1].correct
    check pickBack.scripted
    let start = sim.events[0].eventToJson()
    check start["kind"].getStr() == "start"
    check not start.hasKey("round")
    check eventFromJson(start).kind == evStart

suite "determinism":
  test "the seed fixes the schedule, the glyphs, and the views":
    let a = initSim(fixtureConfig(seed = 7))
    let b = initSim(fixtureConfig(seed = 7))
    check a.schedule == b.schedule
    check a.glyphs == b.glyphs
    check a.perm == b.perm
    check a.names == b.names
    let c = initSim(fixtureConfig(seed = 8))
    check c.schedule != a.schedule
    check c.glyphs != a.glyphs
    check c.perm != a.perm

  test "the budget caps rounds and pacing":
    var config = fixtureConfig(rounds = 500, seed = 0)
    config.sampled = false
    config.turnDelayMs = 10_000
    let fitted = sampleEpisode(config)
    check fitted.rounds == EpisodeCallBudget div CallsPerRound
    check fitted.rounds == 60
    check fitted.turnDelayMs == PacingBudgetMs div 60
    check fitted.sampled
    check sampleEpisode(fitted) == fitted
    var small = fixtureConfig(rounds = 1, seed = 0)
    small.sampled = false
    check sampleEpisode(small).rounds == MinRounds
