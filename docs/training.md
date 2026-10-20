# Training on Babel

Babel's hosted player receives a private decision and submits glyph messages
or lineup picks. Prompt model calls run inside the player. The
headless simulator also supports numeric Metta RL and native PufferLib
training through a local bridge. Metta post-training learns from complete
scripted games.

## Numeric training

After syncing `nimby.lock` as shown in the [README](../README.md):

```sh
nim c -d:release --parallelBuild:1 --path:src -o:/tmp/babel-train-bridge tools/train_bridge.nim
python3 tools/test_train_bridge.py /tmp/babel-train-bridge
```

Pass the binary and `coworld_manifest_template.json` to
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
The exporter writes owner-only `trajectories.jsonl` and `manifest.json`; it creates no admitted training examples or splits.
Scripted attempts retain their actual prompt, response, policy, and parsed/applied action.
All model-serving fields remain null.

After syncing `nimby.lock` as shown in the [README](../README.md):

```sh
nim c --parallelBuild:1 --path:src --out:bin/export-posttrain tools/export_posttrain.nim
bin/export-posttrain /tmp/babel-posttrain-corpus 100 11 source-engine-1
```

Convert the raw event stream into complete episodes from a Metta checkout:

```sh
uv run --package coworld python - <<'PYTHON'
from pathlib import Path
from coworld.decision_trajectory import export_complete_episodes, read_trajectory_jsonl

source = Path("/tmp/babel-posttrain-corpus/trajectories.jsonl")
destination = Path("/tmp/babel-posttrain-corpus/complete-episodes.jsonl")
count = export_complete_episodes(read_trajectory_jsonl(source), destination)
assert count == 100
PYTHON
```

The conversion validates every event and preserves complete episodes. It does
not grant teacher approval or fabricate model receipts.

Keep source diagnostic versions distinct from published package versions.
The shared `metta_training.posttrain.hosted.export_hosted` importer requires external review bound to the complete-episode corpus SHA256 and exact source revision.
It assigns whole seed families to splits and rejects unreviewed teachers or model calls without registered platform receipts.
Previous direct datasets remain historical artifacts; they cannot qualify current labels.

A source-owned scripted corpus provides candidate imitation data, not trained-model strength or published runtime parity.
Evaluate a frozen learner through the same native player protocol with actual registered engine/model receipts.

## Matched wording panels

Pass `promptVariant` and `promptSeed` in language-bridge resets. Use `canonical`,
`plain`, `numbered`, `questions`, or `reordered`, or `mixed` with an explicit
nonnegative seed. Mixed resolves by seed modulo five and stays fixed for the
whole game. Both speaker and listener retain their original task formats and
private view. Numeric resets reject noncanonical selections.

The source exporter accepts:

```sh
bin/export-posttrain OUTPUT EPISODES FIRST_SEED GAME_VERSION OPERATOR_PROMPT PROMPT_VARIANT PROMPT_SEED
```

Mixed exports advance the prompt seed once per episode and record each selection in the manifest.
Run the exporter from a clean, committed game checkout. Use separate private
output directories for each training wording and identical scenario seeds. Episode identities include the selected wording and prompt seed;
scenario-family identities remain tied to the game seed. The shared importer must
keep every wording of a scenario in the same split. Retain content-bound external
teacher review; prompt diversity does not admit unreviewed labels.

Held-out briefing and reference wordings require `split: validation` in language bridge resets; training exports reject them. Freeze
policies, opponents, scenario seeds, seat assignments, and ordinary round budgets
for paired canonical/held-out runs. Report scores, invalid actions, fallback,
truncation, and missing evidence separately. Scripted parity tests cannot establish
reduced collapse or improved model learning.

After building the bridge, run the complete matched wording panel:

```sh
python3 tools/test_prompt_variants.py /tmp/babel-train-bridge
```

The eight complete 24-round games cover every direct wording and one mixed selection.
They check role visibility, private notes, message hashes, unchanged scripted actions
and outcomes, and held-out training rejection. The existing hosted-trajectory fixture
checks mixed selection through real native players and a local model endpoint.

Hosted private observations record `prompt_selection` and `prompt_attempts`.
Each model attempt's entry carries its identity and hashes of the exact recorded
system and user messages. External actions without native prompt evidence have
no attempt hashes; selection metadata does not establish a model call.
