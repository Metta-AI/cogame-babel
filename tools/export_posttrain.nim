## Export complete scripted Babel games as Metta post-training examples.
## Usage: nim r --path:src tools/export_posttrain.nim OUTPUT EPISODES [FIRST_SEED]

import std/[json, os, osproc, strutils]
import babel/[sim, llm]

const OperatorPrompt = "Build a shared glyph code from feedback."

when isMainModule:
  let args = commandLineParams()
  if args.len notin 2 .. 3:
    quit("usage: export_posttrain OUTPUT EPISODES [FIRST_SEED]", 1)
  let output = args[0]
  let episodes = parseInt(args[1])
  let firstSeed = if args.len == 3: parseInt(args[2]) else: 0
  if episodes < 10 or firstSeed < 0:
    quit("at least ten episodes and a nonnegative first seed are required", 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  createDir(output)
  let sourceRevision = execProcess("git rev-parse HEAD").strip()
  var
    trainRows: seq[string]
    validationRows: seq[string]
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
        let user =
          if call.kind == ckSpeak:
            sim.speakerPrompt(call.pair, OperatorPrompt)
          else:
            sim.listenerPrompt(call.pair, OperatorPrompt)
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
          completion = %*{"pick": lineupLetter(decision.pick), "notes": ""}
          doAssert parsePick(completion).pick == decision.pick
          sim.applyPick(call.pair, decision.pick, decision.notes, true)
        let row = %*{
          "episode_id": "babel-" & $seed,
          "seed": "babel-" & $seed,
          "decision_id": decisionId,
          "prompt": [
            {"role": "system", "content": sim.systemPrompt(call.seat)},
            {"role": "user", "content": user}
          ],
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
    runs.add(%*{"seed": seed, "decisions": decisionId, "results": results})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  let manifest = %*{
    "schema_version": 1,
    "game": "babel",
    "source_revision": sourceRevision,
    "teacher": "scripted",
    "operator_prompt": OperatorPrompt,
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len,
    "runs": runs
  }
  writeFile(output / "manifest.json", pretty(manifest) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
