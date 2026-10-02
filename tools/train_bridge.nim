## Persistent JSONL bridge for Metta RL and native PufferLib.
## nim c -d:release --path:src -o:babel-train-bridge tools/train_bridge.nim

import std/[json, os]
import babel/[llm, sim, player_view, player_policy]

const OperatorPrompt = TrainingOperatorPrompt

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

proc decision(game: Sim, id: int, language: bool, operatorPrompt: string): JsonNode =
  let call = game.currentCall()
  let speaker = call.kind == ckSpeak
  let view = game.decisionView(call)
  let glyphs = view["alphabet"]
  var properties = newJObject()
  var required = newJArray()
  for head in heads():
    let name = head["name"].getStr()
    properties[name] = %*{"enum": head["choices"]}
    required.add(%name)
  if language:
    properties = %*{"notes": {"type": "string"}}
    if speaker:
      properties["tokens"] = %*{"type": "array", "minItems": 1,
        "maxItems": MaxMessage, "items": {"type": "string", "enum": glyphs}}
      required = %*["tokens"]
    else:
      properties["pick"] = %*{"type": "integer", "enum": [0, 1, 2, 3]}
      required = %*["pick"]
  %*{
    "kind": "decision", "game": "babel", "decision_id": id,
    "seat": call.seat, "engine_seat": call.seat, "turn": game.round,
    "semantic_view": view, "inbox": [],
    "messages": promptMessages(view, operatorPrompt),
    "speech_messages": [],
    "action_schema": {"type": "object", "properties": properties,
      "required": required},
    "typed_question": newJNull(),
    "inference_mode": (if language: %"text_action" else: newJNull())
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

proc teacherAction(game: Sim, client: LlmClient, language: bool): JsonNode =
  let call = game.currentCall()
  if language:
    return scriptedAction(game.decisionView(call))
  let baseline = client.scriptedAction(game, call)
  result = %*{"length": (if call.kind == ckSpeak: baseline.tokens.len else: 1),
    "pick": (if call.kind == ckPick: baseline.pick else: 0)}
  for index in 0 ..< MaxMessage:
    result["token" & $index] = %(if call.kind == ckSpeak and
      index < baseline.tokens.len: baseline.tokens[index] else: 0)

when isMainModule:
  let args = commandLineParams()
  if args.len notin 1 .. 3 or (args.len >= 2 and args[1] != "--language"):
    quit("usage: babel-train-bridge MANIFEST [--language [OPERATOR_PROMPT]]", 1)
  let language = args.len >= 2
  let operatorPrompt = if args.len == 3: args[2] else: OperatorPrompt
  let manifest = parseFile(args[0])
  let variant = manifest["variants"][0]
  doAssert variant["id"].getStr() == "standard"
  var game: Sim
  var client: LlmClient
  var fallbackPolicy: ScriptedPolicy
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
      fallbackPolicy = newScriptedPolicy(seed)
      id = 0
      response = game.decision(id, language, operatorPrompt)
    of "encode":
      doAssert not game.done
      response = game.encoding(id)
    of "teacher":
      doAssert not game.done
      response = %*{"response": $game.teacherAction(client, language)}
    of "step":
      doAssert not game.done and request["decision_id"].getInt() == id
      let call = game.currentCall()
      var action: JsonNode
      var rejection = ""
      if language:
        let resolution = game.resolveAction(call, request["response"].getStr(),
          game.decisionView(call), false, fallbackPolicy)
        action = game.actionJson(call, resolution.decision)
        rejection = resolution.rejection
      else:
        action = parseJson(request["response"].getStr())
        for head in heads():
          doAssert action[head["name"].getStr()] in head["choices"]
        var payload: JsonNode
        if call.kind == ckSpeak:
          var glyphs = newJArray()
          for index in 0 ..< action["length"].getInt():
            glyphs.add(%game.glyphOf(call.seat, action["token" & $index].getInt()))
          payload = %*{"tokens": glyphs, "notes": ""}
          let parsed = game.parseSpeak(call.seat, payload)
          game.applySpeak(call.pair, parsed.tokens, parsed.notes, false)
        else:
          payload = %*{"pick": lineupLetter(action["pick"].getInt()), "notes": ""}
          let parsed = parsePick(payload)
          game.applyPick(call.pair, parsed.pick, parsed.notes, false)
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
          "observation": game.decision(id, language, operatorPrompt)}
      if rejection.len > 0:
        response["kind"] = %"consumed_rejection"
        response["reason"] = %rejection
    else:
      raise newException(ValueError, "unknown command: " & request["kind"].getStr())
    stdout.writeLine($response)
    stdout.flushFile()
