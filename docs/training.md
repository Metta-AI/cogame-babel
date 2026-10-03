# Training on Babel

Babel's hosted player receives a private decision and submits glyph messages
or lineup picks. Prompt model calls run inside the player. The
headless simulator also supports numeric Metta RL and native PufferLib
training through a local bridge. Metta post-training learns from complete
scripted games.

## Numeric training

After syncing `nimby.lock` as shown in the [README](../README.md):

```sh
nim c -d:release --path:src -o:/tmp/babel-train-bridge tools/train_bridge.nim
python3 tools/test_train_bridge.py /tmp/babel-train-bridge
```

Pass the binary and `coworld_manifest_template.json` to
`recipes.external.coworld_metta_rl.train` or
`recipes.external.coworld.train` in Metta, with `players=4` and a finite
`total_timesteps`. The certified Standard variant produces 404 numeric
features. Ten action heads choose message length, eight token slots, and
the listener's A–D pick. Unused heads are ignored for the current role.
The speaker's target is absent from listener observations; the listener's
lineup and message are absent from speaker observations. Feedback history
includes only rounds in which the acting seat participated. The `teacher`
request uses the game's scripted compositional code and listener.

## Metta post-training

The exporter runs the production Nim simulator for 24 rounds per seed. It
records offline prompt templates and the built-in scripted baseline's accepted
JSON reply. These templates are training data, not the hosted player's exact
request body. Every seat's glyph alphabet is
seeded independently; speaker labels use the acting seat's visible glyphs.
Complete source-owned trajectories use the canonical private prompt and engine parser.
The exporter writes owner-only `trajectories.jsonl` and `manifest.json`; it creates no training labels or splits.
Scripted attempts retain their actual prompt, response, policy, and parsed/applied action.
All model-serving fields remain null.

After syncing `nimby.lock` as shown in the [README](../README.md):

```sh
nim c --path:src --out:bin/export-posttrain tools/export_posttrain.nim
bin/export-posttrain /tmp/babel-posttrain-corpus 100 11 source-engine-1
```

Keep source diagnostic versions distinct from published package versions.
The shared `metta_posttrain.hosted.export_hosted` importer requires external review bound to the corpus SHA256 and exact source revision.
It assigns whole seed families to splits and rejects unreviewed teachers or model calls without registered platform receipts.
Previous direct datasets remain historical artifacts; they cannot qualify current labels.

A source-owned scripted corpus establishes supervised imitation data, not trained-model strength or published runtime parity.
Evaluate a frozen learner through the same native player protocol with actual registered engine/model receipts.
