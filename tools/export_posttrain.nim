## Export complete scripted Babel games as Metta post-training examples.
## Usage: nim r --path:src tools/export_posttrain.nim OUTPUT EPISODES FIRST_SEED GAME_VERSION

import std/[json, os, osproc, strutils]
import babel/[sim, llm, player_view, player_policy]

const OperatorPrompt = TrainingOperatorPrompt

when isMainModule:
  let args = commandLineParams()
  if args.len != 4:
    quit("usage: export_posttrain OUTPUT EPISODES FIRST_SEED GAME_VERSION", 1)
  let output = args[0]
  let episodes = parseInt(args[1])
  let firstSeed = parseInt(args[2])
  let gameVersion = args[3]
  doAssert gameVersion.len > 0
  if episodes < 10 or firstSeed < 0:
    quit("at least ten episodes and a nonnegative first seed are required", 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  createDir(output)
  setFilePermissions(output, {fpUserRead, fpUserWrite, fpUserExec})
  let sourceRevision = execProcess("git rev-parse HEAD").strip()
  var
    trainRows: seq[string]
    validationRows: seq[string]
    trajectoryRows: seq[string]
    runs = newJArray()
  for seed in firstSeed ..< firstSeed + episodes:
    var config = defaultGameConfig()
    config.seed = seed
    for seat in 0 ..< Seats:
      config.players.add(PlayerConfig(name: "scripted-" & $seat))
      config.tokens.add("training-seat-" & $seat)
    config = sampleEpisode(config)
    let client = newScriptedClient(seed)
    var sim = initSim(config)
    var decisionId = 0
    while not sim.done:
      let call = sim.currentCall()
      case call.kind
      of ckRound:
        sim.beginRound()
      of ckSpeak, ckPick:
        let view = sim.decisionView(call)
        let prompt = promptMessages(view, OperatorPrompt)
        let decision = client.scriptedAction(sim, call)
        var completion: JsonNode
        if call.kind == ckSpeak:
          var glyphs = newJArray()
          for token in decision.tokens:
            glyphs.add(%sim.glyphOf(call.seat, token))
          completion = %*{"tokens": glyphs, "notes": ""}
          doAssert sim.parseSpeak(call.seat, completion).tokens == decision.tokens
          sim.applySpeak(call.pair, decision.tokens, decision.notes, true)
        else:
          completion = %*{"pick": decision.pick, "notes": ""}
          doAssert parsePick(completion).pick == decision.pick
          sim.applyPick(call.pair, decision.pick, decision.notes, true)
        let episodeId = "babel-" & $seed
        let attemptId = episodeId & "-" & $decisionId & "-teacher"
        trajectoryRows.add($(%*{
          "schema_version": "1", "event_type": "decision",
          "episode_id": episodeId, "decision_id": episodeId & "-" & $decisionId,
          "decision_index": decisionId, "game": "babel", "game_version": gameVersion,
          "source_revision": sourceRevision, "seat": $call.seat,
          "visibility": "private", "observation": view, "prompt": prompt,
          "attempts": [{"attempt_id": attemptId, "policy": "scripted-babel",
            "origin": "teacher", "response": $completion, "raw_response": $completion,
            "prompt": prompt, "request": {"teacher": "scripted-babel",
              "seed": seed, "observation": view}, "model": "scripted-babel",
            "model_identity": sourceRevision, "decoder": {"method": "deterministic"},
            "parsed_action": completion, "accepted": true}],
          "selected_attempt_id": attemptId, "executed_action": completion,
          "action_status": "accepted", "terminal": sim.done
        }))
        let row = %*{
          "episode_id": "babel-" & $seed,
          "seed": "babel-" & $seed,
          "decision_id": decisionId,
          "prompt": prompt,
          "completion": [{"role": "assistant", "content": $completion}],
          "game": "babel",
          "action_schema_revision": "babel-decision-v1"
        }
        if seed mod 5 == 0:
          validationRows.add($row)
        else:
          trainRows.add($row)
        inc decisionId
      of ckNone:
        discard
    let results = sim.resultsJson()
    doAssert results["reason"].getStr() == "complete"
    var outcomes = newJObject()
    for seat in 0 ..< Seats:
      outcomes[$seat] = %sim.score(seat)
    trajectoryRows.add($(%*{
      "schema_version": "1", "event_type": "episode", "episode_id": "babel-" & $seed,
      "seed_family": "babel-" & $seed, "game": "babel", "game_version": gameVersion,
      "source_revision": sourceRevision, "status": "completed", "outcome": results,
      "participant_outcomes": outcomes
    }))
    runs.add(%*{"seed": seed, "decisions": decisionId, "results": results})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "trajectories.jsonl", trajectoryRows.join("\n") & "\n")
  let manifest = %*{
    "schema_version": 1,
    "game": "babel",
    "game_version": gameVersion,
    "source_revision": sourceRevision,
    "teacher": "scripted",
    "operator_prompt": OperatorPrompt,
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len,
    "runs": runs
  }
  writeFile(output / "manifest.json", pretty(manifest) & "\n")
  for name in ["train.jsonl", "validation.jsonl", "trajectories.jsonl", "manifest.json"]:
    setFilePermissions(output / name, {fpUserRead, fpUserWrite})
  echo "train=", trainRows.len, " validation=", validationRows.len
