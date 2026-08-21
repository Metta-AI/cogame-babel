## The scripted baseline must play whole games without ever proposing an
## illegal move — it is both the no-credentials fallback (offline
## certification) and a fieldable policy, so this is the completion path.

import std/[json, monotimes, times, unittest]
import focus/[llm, sim]

proc fixture(seed: int, maxPlies = 160): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.maxPlies = maxPlies
  result.sampled = true
  for index in 0 ..< 2:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("t" & $index)

suite "scripted baseline":
  test "plays full games legally and fast":
    for seed in [1, 7, 42, 1234]:
      let config = fixture(seed)
      let client = newLlmClient(config)
      var sim = initSim(config)
      let started = getMonoTime()
      var plies = 0
      while not sim.done:
        let seat = sim.turn
        let decision = client.scriptedAction(sim, seat)
        ## The bot's move must be legal as-is: applyMove raises on
        ## anything else and would fail this test.
        sim.recordSay(seat, decision.say)
        sim.applyMove(seat, decision.move)
        inc plies
        check plies <= config.maxPlies
      let elapsed = (getMonoTime() - started).inMilliseconds
      echo "seed ", seed, ": ", plies, " plies, ", sim.reason, ", winner ",
        sim.winner, ", ", elapsed, " ms"
      ## Budget: well under a second per ply on average.
      check elapsed < plies * 1000
      let results = sim.resultsJson()
      var total = 0.0
      for score in results["scores"]:
        total += score.getFloat()
      check abs(total - 1.0) < 1e-9
      var pieces = 0
      for cell in 0 ..< Cells:
        pieces += sim.board[cell].len
      pieces += sim.reserve[0] + sim.reserve[1] +
        sim.captured[0] + sim.captured[1]
      check pieces == 36

  test "decide falls back to scripted with no credentials":
    let config = fixture(3, maxPlies = 4)
    let client = newLlmClient(config)
    var sim = initSim(config)
    let decision = client.decide(sim, sim.turn, "attack the centre",
      scripted = false)
    sim.applyMove(sim.turn, decision.move)

  test "model replies parse into moves and drops":
    let config = fixture(0)
    var sim = initSim(config)
    let moved = parseDecision(sim, 0, parseJson(
      """{"say":"hi","move":{"from":"c7","count":1,"dir":"E"}}"""))
    check moved.move.kind == mkMove
    check moved.move.fromCell == parseCell("c7")
    check moved.move.toCell == parseCell("d7")
    check moved.say == "hi"
    sim.applyMove(0, moved.move)
    let dropped = parseDecision(sim, 1, parseJson(
      """{"say":"","place":"a4"}"""))
    check dropped.move.kind == mkPlace
    check dropped.move.toCell == parseCell("a4")
    let dropped2 = parseDecision(sim, 1, parseJson(
      """{"move":{"place":"h5"}}"""))
    check dropped2.move.toCell == parseCell("h5")
    let stringy = parseDecision(sim, 1, parseJson(
      """{"move":{"from":"B6","count":"1","direction":"north"}}"""))
    check stringy.move.dir == dirN
    check stringy.move.count == 1
    expect FocusError:
      discard parseDecision(sim, 1, parseJson("""{"say":"?"}"""))
    expect FocusError:
      discard parseDecision(sim, 1, parseJson(
        """{"move":{"from":"a1","count":1,"dir":"N"}}"""))
