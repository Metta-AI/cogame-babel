# Babel

An **emergent-language referential game** for the Softmax Coworld
platform, on the
[cogame-parley](https://github.com/Metta-AI/cogame-parley) technology
stack (forked from [cogame-focus](https://github.com/Metta-AI/cogame-focus)).
Four cogs, a 16-glyph alphabet that means nothing, and 24 rounds to make
it mean something. Every round the four seats split into two pairs, each
with a **speaker** and a **listener** (partners and roles rotate so every
ordered relation occurs once per six rounds). The speaker sees a target
scene — a *shape* (circle, square, triangle, star), a *colour* (red, blue,
green, yellow), and a *count* (1–4) — and sends a message of 1–8 glyphs.
The listener sees the message and a lineup of four scenes (the target, a
near miss, a partial match, a clear miss) labelled A–D and picks one.
**Both score when the pick is right.** Nothing but glyphs crosses between
seats, and every seat sees the 16 tokens under its own seeded symbols in
its own order, so no convention can be agreed in advance: meaning has to
be grounded in-episode from the feedback after each round. Every seat
keeps private notes the server feeds back verbatim — and records for the
audience, who watch the dictionaries form.

**The game is LLM-driven and a policy is just a prompt.** Whenever a seat
speaks or listens the game server sends that seat's policy prompt, its
alphabet, its notes, its own history, and the target (or the message and
lineup) to Claude, which answers with the glyphs (or the pick) and new
notes. Player containers exist only to deliver their prompt over the
websocket. A built-in **scripted baseline** (a fixed shape/colour/count
token code as speaker, a count-based association decoder as listener)
plays any seat that registers as scripted — and every seat when no LLM
credentials are available, so episodes (and offline certification) always
complete.

Seats play under **anonymous cog names** (Sprocket, Gizmo, …): policy
display names never reach the agents' prompts, so nobody can meta-game
"that seat is the champion". The spectator and replay viewers map the
aliases back to policy names; results are reported under policy names.

Scoring: a seat's `correct` is the successful rounds it was in (either
role); `score = correct / rounds played` (0..1). Results also report
`asSpeaker` and `asListener`. The episode ends `complete` after `rounds`
rounds (default 24, max 60) or `deadline` when the episode clock stops
play between rounds.

## Layout

- `src/babel.nim` — entrypoint (Coworld runtime contract, live vs replay mode)
- `src/babel/sim.nim` — pure rules: alphabet and per-seat views, pairing
  schedule, scenes and lineups, speak/pick, tallies, endings, replay
  derivation; shared by server, tests, and the wasm viewer
- `src/babel/llm.nim` — Claude client + the scripted code-and-decode baseline
- `src/babel/server.nim` — mummy HTTP/WS server (player, global, replay)
- `src/babel_player.nim` — the prompt-delivery player (`PLAYER_PROMPT` /
  `PLAYER_SCRIPTED` env)
- `client/` — shared canvas renderer + global/player/replay pages (the
  parley broadcast chrome around the Babel stage)
- `replay-viewer/` — static wasm replay viewer (`?replay=<url>`)
- `tools/build_replay_viewer.sh` — Coworld replay-viewer build hook
- `data/` — cog sprites and art, borrowed from
  [coworld-ctf](https://github.com/Metta-AI/coworld-ctf) (MIT)
- `docs/plans/` — the design note this game was built from

## Local loop

```bash
export PATH="$HOME/.nimby/nim/bin:$PATH"
nimby --global sync nimby.lock                 # fetch pinned packages
# Generate nim.cfg from your nimby package tree (not committed - the
# paths are machine-specific):
rm -f nim.cfg
for pkg in ~/.nimby/pkgs/*; do
  if [ -d "$pkg/src" ]; then echo "--path:\"$pkg/src\"" >> nim.cfg;
  else echo "--path:\"$pkg\"" >> nim.cfg; fi
done
echo '--path:"src"' >> nim.cfg

nim r --path:src tests/test_sim.nim            # rules tests
nim r -d:release --path:src tests/test_bot.nim # scripted-baseline tests
nim c -d:release -o:bin/babel src/babel.nim
nim c -d:release -o:bin/babel-player src/babel_player.nim
nim c --hints:off -d:emscripten replay-viewer/babel_replay.nim  # wasm viewer
# See tmp/config.json for a four-seat fixture; run with COGAME_* env + 4
# players (tmp/run_e2e.sh does this). Export ANTHROPIC_API_KEY for real
# Claude play; omit for the scripted baseline.
```

Coworld packaging (from a metta checkout):

```bash
uv run coworld build --project <this dir> --version 0.1.x
uv run coworld certify <this dir>/dist/coworld_manifest.json
uv run coworld upload-coworld <this dir>/dist/coworld_manifest.json
uv run coworld secret put babel anthropic_api_key <keyfile>   # hosted Claude
```

## Fielding a policy

```bash
uv run coworld upload-policy <babel image> --name my-babel \
  --run /bin/babel-player \
  --secret-env PLAYER_PROMPT="Your Babel strategy here."
```

Or field the scripted coder: same image, `--env PLAYER_SCRIPTED=1`.
