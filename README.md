# Focus

Sid Sackson's **Focus** (Parker Brothers' **Domination**) for the Softmax
Coworld platform, on the
[cogame-parley](https://github.com/Metta-AI/cogame-parley) technology
stack. Two cogs, an 8×8 board with the three squares in each corner
missing (52 squares), 18 pieces each. Pieces stack; whoever owns the top
piece controls the stack. Move the top *k* pieces of a stack you control
exactly *k* squares orthogonally and land on whatever is there; stacks
over five shed from the bottom (your own to your reserve, enemy pieces
captured); drop a reserve piece anywhere instead of moving. **The last
player able to move wins**; the ply cap settles on material.

**The game is LLM-driven and a policy is just a prompt.** Every ply the
game server sends the acting seat's policy prompt, the board, and the
complete legal-move list to Claude, which answers with what the cog says
and which move it makes. Player containers exist only to deliver their
prompt over the websocket. A built-in **scripted baseline** (two-ply
minimax on material, captures, and mobility) plays any seat that
registers as scripted — and every seat when no LLM credentials are
available, so episodes (and offline certification) always complete.

Seats play under **anonymous cog names** (Sprocket, Gizmo, …): policy
display names never reach the agents' prompts, so nobody can meta-game
"that seat is the champion". The spectator and replay viewers map the
aliases back to policy names; results are reported under policy names.

## Layout

- `src/focus.nim` — entrypoint (Coworld runtime contract, live vs replay mode)
- `src/focus/sim.nim` — pure rules: board, moves, cap, reserve, endings,
  replay derivation; shared by server, tests, and the wasm viewer
- `src/focus/llm.nim` — Claude client + the scripted baseline bot
- `src/focus/server.nim` — mummy HTTP/WS server (player, global, replay)
- `src/focus_player.nim` — the prompt-delivery player (`PLAYER_PROMPT` /
  `PLAYER_SCRIPTED` env)
- `client/` — shared canvas renderer + global/player/replay pages (the
  parley broadcast chrome around a Focus board)
- `replay-viewer/` — static wasm replay viewer (`?replay=<url>`)
- `tools/build_replay_viewer.sh` — Coworld replay-viewer build hook
- `data/` — cog sprites and art, borrowed from
  [coworld-ctf](https://github.com/Metta-AI/coworld-ctf) (MIT)
- `docs/plans/` — the design note this port was built from

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
nim c -d:release -o:bin/focus src/focus.nim
nim c -d:release -o:bin/focus-player src/focus_player.nim
# See tmp/config.json for a two-seat fixture; run with COGAME_* env + 2
# players. Export ANTHROPIC_API_KEY for real Claude play; omit for the
# scripted baseline.
```

Coworld packaging (from a metta checkout):

```bash
uv run coworld build --project <this dir> --version 0.1.x
uv run coworld certify <this dir>/dist/coworld_manifest.json
uv run coworld upload-coworld <this dir>/dist/coworld_manifest.json
uv run coworld secret put focus anthropic_api_key <keyfile>   # hosted Claude
```

## Fielding a policy

```bash
uv run coworld upload-policy <focus image> --name my-focus \
  --run /bin/focus-player \
  --secret-env PLAYER_PROMPT="Your Focus strategy here."
```

Or field the scripted tactician: same image, `--env PLAYER_SCRIPTED=1`.
