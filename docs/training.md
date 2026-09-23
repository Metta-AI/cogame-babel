# Training on Babel

Babel's hosted player submits a prompt; the game server makes the
language-model calls and accepts glyph messages or lineup picks. The
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
records the exact system and user prompts sent to the model and the built-in
scripted baseline's accepted JSON reply. Every seat's glyph alphabet is
seeded independently; speaker labels use the acting seat's visible glyphs.
Whole games are assigned to training or validation by seed.

After syncing `nimby.lock` as shown in the [README](../README.md):

```sh
nim c --path:src --out:bin/export-posttrain tools/export_posttrain.nim
bin/export-posttrain /tmp/babel-posttrain-dataset 100
```

The output contains `train.jsonl`, `validation.jsonl`, and `manifest.json`.
Rows match Metta post-training's `Example` schema. The manifest records the
source revision, per-game scores, decision counts, and the operator prompt.
The prompts use `PLAYER_PROMPT="Build a shared glyph code from feedback."`.

From a Metta checkout with `metta-posttrain` installed:

```sh
uv run --package metta-posttrain --extra train python -m metta_posttrain.train \
  --dataset /tmp/babel-posttrain-dataset \
  --output /tmp/babel-posttrain-run \
  --model MODEL_OR_PATH --max-steps 1000 --max-length 2048
```

Check the optimizer manifest for overlength examples with the chosen
tokenizer. This dataset imitates the scripted baseline; it does not measure
trained-model score. A trained model needs serving through the game's
configured Anthropic or Bedrock provider before it can play.
