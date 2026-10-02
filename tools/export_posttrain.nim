## Export complete scripted Babel games as Metta post-training examples.
## Usage: nim r --path:src tools/export_posttrain.nim OUTPUT EPISODES FIRST_SEED GAME_VERSION

import std/[json, options, os, osproc, strutils]
import bitworld/decision_trajectory
import babel/[sim, llm, player_view, player_policy]

when isMainModule:
  let args = commandLineParams()
  if args.len notin 4 .. 5:
    quit("usage: export_posttrain OUTPUT EPISODES FIRST_SEED GAME_VERSION [OPERATOR_PROMPT]", 1)
  let output = args[0]
  let episodes = parseInt(args[1])
  let firstSeed = parseInt(args[2])
  let gameVersion = args[3]
  let operatorPrompt = if args.len == 5: args[4] else: TrainingOperatorPrompt
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
    var sim = initSim(config)
    var decisionId = 0
    let trajectory = newDecisionTrajectory("babel-" & $seed, "babel-" & $seed,
      "babel", gameVersion, sourceRevision)
    while not sim.done:
      let call = sim.currentCall()
      case call.kind
      of ckRound:
        sim.beginRound()
      of ckSpeak, ckPick:
        let view = sim.decisionView(call)
        let prompt = promptMessages(view, operatorPrompt)
        let completion = scriptedAction(view)
        let decision = if call.kind == ckSpeak:
          sim.parseSpeak(call.seat, completion)
          else: parsePick(completion)
        if call.kind == ckSpeak:
          sim.applySpeak(call.pair, decision.tokens, decision.notes, true)
        else:
          sim.applyPick(call.pair, decision.pick, decision.notes, true)
        let episodeId = "babel-" & $seed
        let attemptId = episodeId & "-" & $decisionId & "-teacher"
        let actualAction = sim.actionJson(call, decision)
        var teacher = newDecisionAttempt(attemptId, "scripted-babel", aoTeacher)
        teacher.response = %($completion)
        teacher.rawResponse = %($completion)
        teacher.prompt = prompt
        teacher.request = %*{"teacher": "scripted-babel", "seed": seed, "observation": view}
        teacher.model = some("scripted-babel")
        teacher.modelIdentity = some(sourceRevision)
        teacher.decoder = %*{"method": "deterministic"}
        teacher.parsedAction = actualAction
        teacher.accepted = true
        trajectory.recordDecision(episodeId & "-" & $decisionId, $call.seat, view,
          @[teacher], some(attemptId), actualAction, asAccepted, terminal = sim.done)
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
    trajectory.finish(esCompleted, results, outcomes)
    trajectoryRows.add(trajectory.eventsJsonl().strip())
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
    "operator_prompt": operatorPrompt,
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len,
    "runs": runs
  }
  writeFile(output / "manifest.json", pretty(manifest) & "\n")
  for name in ["train.jsonl", "validation.jsonl", "trajectories.jsonl", "manifest.json"]:
    setFilePermissions(output / name, {fpUserRead, fpUserWrite})
  echo "train=", trainRows.len, " validation=", validationRows.len
