import std/unittest
import babel/[game_policy, player_policy, player_view, sim]

proc playPlayerBaseline(seed: int): Sim =
  var config = defaultGameConfig()
  config.seed = seed
  config.rounds = 24
  config.sampled = true
  for slot in 0 ..< Seats:
    config.players.add(PlayerConfig(name: "P" & $slot))
    config.tokens.add("t" & $slot)
  result = initSim(config)
  while not result.done:
    let call = result.currentCall()
    if call.kind == ckRound:
      result.beginRound()
      continue
    let action = scriptedAction(result.decisionView(call))
    if call.kind == ckSpeak:
      let decision = parseSpeak(result, call.seat, action)
      result.applySpeak(call.pair, decision.tokens, decision.notes, true)
    else:
      let decision = parsePick(action)
      result.applyPick(call.pair, decision.pick, decision.notes, true)

suite "ordinary scripted player":
  test "complete private-view episodes converge after feedback":
    var successes = 0
    var total = 0
    for seed in [1, 7, 42, 1234]:
      let sim = playPlayerBaseline(seed)
      check sim.reason == "complete"
      check sim.roundsPlayed == 24
      for event in sim.events:
        if event.kind == evPick and event.round >= 12:
          inc total
          if event.correct:
            inc successes
    echo "player baseline success after 12 rounds: ", successes,
      "/", total
    check successes.float / total.float > 0.75
