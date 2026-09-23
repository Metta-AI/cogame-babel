# Training on Babel

Babel's player submits a prompt; the game server makes the language-model
calls and accepts glyph messages or lineup picks. The player socket does not
accept numeric actions, so Metta RL and PufferLib do not have a step/action
interface here. Metta post-training can learn from complete scripted games.

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
