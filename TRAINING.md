# Training

The certified `standard` variant uses the headless simulator. Build the
persistent bridge and play complete scripted and random games:

```sh
nimby sync nimby.lock
nim c -d:release --path:src -o:/tmp/babel-train-bridge tools/train_bridge.nim
python3 tools/test_train_bridge.py /tmp/babel-train-bridge
```

Pass the binary and `coworld_manifest_template.json` to
`recipes.external.coworld_metta_rl.train` or
`recipes.external.coworld.train` in Metta, with `players=4` and a finite
`total_timesteps`. The observation has 404 numeric features. Ten action
heads choose message length, eight token slots, and the listener's A–D
pick. Unused heads are ignored for the current role. The speaker's target
is absent from listener observations; the listener's lineup and message
are absent from speaker observations. Feedback history includes only rounds
in which the acting seat participated.

`teacher` uses the game's scripted compositional code and listener. This
baseline is also available as hosted prompts in the Metta post-training
exporter:

```sh
nim r -d:release --path:src tools/export_posttrain.nim /tmp/babel-posttrain 10 1
```

The exporter writes complete games to `train.jsonl` and `validation.jsonl`.
Training on those examples distills the scripted baseline; it does not
establish stronger play.
