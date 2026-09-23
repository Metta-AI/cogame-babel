## Persistent JSONL bridge for Metta RL and native PufferLib.
## nim c -d:release --path:src -o:babel-train-bridge tools/train_bridge.nim

import std/[json, os]
import babel/[llm, sim]

const OperatorPrompt = "Communicate the target scene and choose the matching scene."

proc seedOf(value: string): int =
  var hash = 2166136261'u32
  for ch in value:
    hash = (hash xor uint32(ord(ch))) * 16777619'u32
  int(hash and 0x7fffffff'u32)

proc heads(): JsonNode =
  result = newJArray()
  var lengths = newJArray()
  for count in 1 .. MaxMessage:
    lengths.add(%count)
  result.add(%*{"name": "length", "choices": lengths})
  for index in 0 ..< MaxMessage:
    var choices = newJArray()
    for token in 0 ..< Tokens:
      choices.add(%token)
    result.add(%*{"name": "token" & $index, "choices": choices})
  var picks = newJArray()
  for pick in 0 ..< LineupSize:
    picks.add(%pick)
  result.add(%*{"name": "pick", "choices": picks})

proc decision(game: Sim, id: int): JsonNode =
  let call = game.currentCall()
  let plan = game.plan()
  let speaker = call.kind == ckSpeak
  var glyphs = newJArray()
  for token in 0 ..< Tokens:
    glyphs.add(%game.glyphOf(call.seat, token))
  var lineup = newJArray()
  var message = newJArray()
  if not speaker:
    for scene in plan.lineups[call.pair]:
      lineup.add(%scene)
    for token in game.tokens[call.pair]:
      message.add(%game.glyphOf(call.seat, token))
  let view = %*{
    "round": game.round, "rounds": game.config.rounds,
    "role": (if speaker: "speaker" else: "listener"),
    "pair": call.pair, "partner": game.partnerOf(call.seat),
    "alphabet": glyphs,
    "target": (if speaker: plan.targets[call.pair] else: -1),
    "lineup": lineup, "message": message,
    "correct": game.correct[call.seat],
    "played": game.seatRounds[call.seat]
  }
  var properties = newJObject()
  var required = newJArray()
  for head in heads():
    let name = head["name"].getStr()
    properties[name] = %*{"enum": head["choices"]}
    required.add(%name)
  let user = if speaker:
    game.speakerPrompt(call.pair, OperatorPrompt)
    else: game.listenerPrompt(call.pair, OperatorPrompt)
  %*{
    "kind": "decision", "game": "babel", "decision_id": id,
    "seat": call.seat, "engine_seat": call.seat, "turn": game.round,
    "semantic_view": view, "inbox": [],
    "messages": [
      {"role": "system", "content": game.systemPrompt(call.seat)},
      {"role": "user", "content": user}
    ],
    "speech_messages": [],
    "action_schema": {"type": "object", "properties": properties,
      "required": required},
    "typed_question": newJNull()
  }

proc encoding(game: Sim, id: int): JsonNode =
  let call = game.currentCall()
  let plan = game.plan()
  let speaker = call.kind == ckSpeak
  var values = newJArray()
  for value in [call.seat, call.pair, game.round, game.config.rounds,
      (if speaker: 1 else: 0), game.correct[call.seat],
      game.seatRounds[call.seat]]:
    values.add(%value)
  let target = if speaker: plan.targets[call.pair] else: -1
  values.add(%target)
  for index in 0 ..< LineupSize:
    values.add(%(if speaker: -1 else: plan.lineups[call.pair][index]))
  for index in 0 ..< MaxMessage:
    values.add(%(if speaker or index >= game.tokens[call.pair].len: -1
      else: game.tokens[call.pair][index]))
  # A seat sees feedback only from rounds in which it participated.
  var seen = 0
  for event in game.events:
    if event.kind == evPick and call.seat in [event.seat, event.other]:
      let plan = game.schedule[event.round]
      values.add(%(if call.seat == event.other: 1 else: 0))
      values.add(%plan.targets[event.pair])
      for scene in plan.lineups[event.pair]:
        values.add(%scene)
      var tokens: seq[int]
      for previous in game.events:
        if previous.kind == evSpeak and previous.round == event.round and
            previous.pair == event.pair:
          tokens = previous.tokens
      for index in 0 ..< MaxMessage:
        values.add(%(if index < tokens.len: tokens[index] else: -1))
      values.add(%event.pick)
      values.add(%(if event.correct: 1 else: 0))
      inc seen
  for round in seen ..< game.config.rounds:
    for field in 0 ..< 16:
      values.add(%(-1))
  %*{"decision_id": id, "values": values, "action_heads": heads()}

proc teacherAction(game: Sim, client: LlmClient): JsonNode =
  let call = game.currentCall()
  let baseline = client.scriptedAction(game, call)
  result = %*{"length": (if call.kind == ckSpeak: baseline.tokens.len else: 1),
    "pick": (if call.kind == ckPick: baseline.pick else: 0)}
  for index in 0 ..< MaxMessage:
    result["token" & $index] = %(if call.kind == ckSpeak and
      index < baseline.tokens.len: baseline.tokens[index] else: 0)

when isMainModule:
  let args = commandLineParams()
  if args.len != 1:
    quit("usage: babel-train-bridge MANIFEST", 1)
  let manifest = parseFile(args[0])
  let variant = manifest["variants"][0]
  doAssert variant["id"].getStr() == "standard"
  var game: Sim
  var client: LlmClient
  var id = 0
  while not stdin.endOfFile:
    let request = parseJson(stdin.readLine())
    var response: JsonNode
    case request["kind"].getStr()
    of "reset":
      doAssert request["players"].getInt() == Seats
      let seed = seedOf(request["seed"].getStr())
      var config = defaultGameConfig()
      let runtime = copy(variant["game_config"])
      runtime["tokens"] = %*["t0", "t1", "t2", "t3"]
      runtime["seed"] = %seed
      config.update($runtime)
      config = sampleEpisode(config)
      game = initSim(config)
      game.beginRound()
      client = newScriptedClient(seed)
      id = 0
      response = game.decision(id)
    of "encode":
      doAssert not game.done
      response = game.encoding(id)
    of "teacher":
      doAssert not game.done
      response = %*{"response": $game.teacherAction(client)}
    of "step":
      doAssert not game.done and request["decision_id"].getInt() == id
      let action = parseJson(request["response"].getStr())
      for head in heads():
        doAssert action[head["name"].getStr()] in head["choices"]
      let call = game.currentCall()
      if call.kind == ckSpeak:
        var tokens: seq[int]
        for index in 0 ..< action["length"].getInt():
          tokens.add(action["token" & $index].getInt())
        game.applySpeak(call.pair, tokens, "", false)
      else:
        game.applyPick(call.pair, action["pick"].getInt(), "", false)
      inc id
      if game.done:
        var scores = newJObject()
        for seat in 0 ..< Seats:
          scores[$seat] = %game.score(seat)
        response = %*{"kind": "accepted", "action": action,
          "observation": %*{"kind": "terminal", "scores": scores}}
      else:
        if game.currentCall().kind == ckRound:
          game.beginRound()
        response = %*{"kind": "accepted", "action": action,
          "observation": game.decision(id)}
    else:
      raise newException(ValueError, "unknown command: " & request["kind"].getStr())
    stdout.writeLine($response)
    stdout.flushFile()
