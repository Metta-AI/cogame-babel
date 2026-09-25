## Private turn view for an ordinary Babel player. The game owns visibility;
## policies receive only their alphabet, own feedback, and current task.

import std/[json, tables]
import sim

proc glyphMessage(sim: Sim, seat: int, tokens: seq[int]): JsonNode =
  result = newJArray()
  for token in tokens:
    result.add(%sim.glyphOf(seat, token))

proc decisionView*(sim: Sim, call: Call): JsonNode =
  let seat = call.seat
  var alphabet = newJArray()
  for token in 0 ..< Tokens:
    alphabet.add(%sim.glyphOf(seat, token))

  var history = newJArray()
  var messages: Table[(int, int), seq[int]]
  for event in sim.events:
    case event.kind
    of evSpeak:
      messages[(event.round, event.pair)] = event.tokens
    of evPick:
      if seat != event.seat and seat != event.other:
        continue
      let plan = sim.schedule[event.round]
      var lineup = newJArray()
      var lineupScenes = newJArray()
      for scene in plan.lineups[event.pair]:
        lineup.add(%scene)
        lineupScenes.add(%sceneText(scene))
      var entry = %*{
        "round": event.round,
        "role": (if seat == event.seat: "listener" else: "speaker"),
        "partner": sim.names[if seat == event.seat: event.other else: event.seat],
        "message": sim.glyphMessage(seat,
          messages[(event.round, event.pair)]),
        "target": plan.targets[event.pair],
        "target_scene": sceneText(plan.targets[event.pair]),
        "pick": event.pick,
        "picked_scene": sceneText(plan.lineups[event.pair][event.pick]),
        "correct": event.correct
      }
      if seat == event.seat:
        entry["lineup"] = lineup
        entry["lineup_scenes"] = lineupScenes
      history.add(entry)
    else:
      discard

  result = %*{
    "protocol": "babel.player.v2",
    "type": "decision",
    "id": sim.events.len,
    "slot": seat,
    "name": sim.names[seat],
    "round": sim.round,
    "rounds": sim.config.rounds,
    "role": (if call.kind == ckSpeak: "speaker" else: "listener"),
    "partner": sim.names[sim.partnerOf(seat)],
    "alphabet": alphabet,
    "notes": sim.notes[seat],
    "history": history
  }
  let plan = sim.plan
  if call.kind == ckSpeak:
    result["target"] = %plan.targets[call.pair]
    result["target_scene"] = %sceneText(plan.targets[call.pair])
  else:
    result["message"] = sim.glyphMessage(seat, sim.tokens[call.pair])
    var lineup = newJArray()
    var lineupScenes = newJArray()
    for scene in plan.lineups[call.pair]:
      lineup.add(%scene)
      lineupScenes.add(%sceneText(scene))
    result["lineup"] = lineup
    result["lineup_scenes"] = lineupScenes
