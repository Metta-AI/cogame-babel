import std/[json, unittest]
import babel/[game_policy, player_view, sim]

suite "ordinary player view":
  test "each decision exposes only its seat's current task and feedback":
    var config = defaultGameConfig()
    config.seed = 42
    config.rounds = 2
    config.sampled = true
    for slot in 0 ..< Seats:
      config.players.add(PlayerConfig(name: "P" & $slot))
      config.tokens.add("t" & $slot)
    var sim = initSim(config)
    let scripted = newScriptedPolicy(config.seed)
    sim.beginRound()

    let speaker = sim.currentCall()
    let speakView = sim.decisionView(speaker)
    check speakView["role"].getStr() == "speaker"
    check speakView.hasKey("target")
    check speakView.hasKey("target_scene")
    check not speakView.hasKey("lineup")
    check not speakView.hasKey("message")
    check speakView["alphabet"].len == Tokens
    check speakView["history"].len == 0
    let spoken = scripted.scriptedAction(sim, speaker)
    sim.applySpeak(speaker.pair, spoken.tokens, "private note", true)

    let listener = sim.currentCall()
    let listenView = sim.decisionView(listener)
    check listenView["role"].getStr() == "listener"
    check not listenView.hasKey("target")
    check not listenView.hasKey("target_scene")
    check listenView["lineup"].len == LineupSize
    check listenView["lineup_scenes"].len == LineupSize
    check listenView["message"].len == spoken.tokens.len
    check listenView["history"].len == 0
    let picked = scripted.scriptedAction(sim, listener)
    sim.applyPick(listener.pair, picked.pick, "", true)

    let otherPair = sim.currentCall()
    check sim.decisionView(otherPair)["history"].len == 0
    let own = sim.decisionView((ckSpeak, 0, speaker.seat))
    check own["history"].len == 1
    check own["notes"].getStr() == "private note"
    check not own["history"][0].hasKey("lineup")
    check own["history"][0].hasKey("picked_scene")
    check own["history"][0]["target"].getInt() ==
      speakView["target"].getInt()
    let listenerHistory = sim.decisionView((ckPick, 0, listener.seat))
    check listenerHistory["history"][0]["lineup"].len == LineupSize
