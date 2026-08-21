# Babel: an emergent-language coworld

Four cogs, a 16-glyph alphabet that means nothing, and 24 rounds to make it
mean something. Built on the cogame-parley technology stack exactly as
cogame-focus is (Nim game server implementing the Coworld runtime contract,
LLM-driven decisions where **a policy is just a prompt**, an always-available
scripted baseline, a pure `sim` module shared by server / tests / wasm viewer,
the parley broadcast chrome around a canvas stage). Fork of cogame-focus
0.1.3; every convention there holds here unless this note says otherwise.

## The game

- **Seats:** exactly 4 (`num_agents` = 4). Anonymous cog aliases from the
  seed as in focus (`CogNames`), policy names spectator-only.
- **Rounds:** `rounds` (default 24, min 2, max 60; cert fixture 6). Every
  seat plays every round: the four seats are split into two **pairs**, each
  with a **speaker** and a **listener**.
- **Pairing schedule** (deterministic): the three perfect matchings of four
  seats are `M0 = {(0,1),(2,3)}`, `M1 = {(0,2),(1,3)}`, `M2 = {(0,3),(1,2)}`.
  Round `r` (0-based) uses `M[r mod 3]`; within each pair `(a,b)` the speaker
  is `a` when `(r div 3) mod 2 == 0`, else `b`. So every ordered (speaker →
  listener) relation occurs once per 6 rounds; 24 rounds = 4 passes.
  Pair 0 is the pair containing seat 0; pair 1 is the other.
- **Scenes:** a scene is `(shape, colour, count)` with
  `shape ∈ {circle, square, triangle, star}` (index 0..3),
  `colour ∈ {red, blue, green, yellow}` (0..3), `count ∈ {1,2,3,4}` (0..3).
  Scene id = `shape*16 + colour*4 + count`, 0..63. A scene is described in
  text as e.g. `3 green triangles` / `1 red star`.
- **Per pair per round:** the sim draws a **target** scene and a **lineup** of
  4 distinct scenes (target + 3 distractors, each distractor differs from
  the target in at least one attribute; exactly one distractor shares two
  attributes with the target, one shares one, one shares none — so the
  lineup always has a near miss, a partial, and a clear miss). The lineup is
  shuffled; the listener sees candidates labelled A B C D. The speaker sees
  only the target, never the lineup. Both pairs in a round are independent.
- **The channel:** the speaker sends a **message of 1..8 tokens**, each a
  token id 0..15. Nothing else crosses between seats — there is no free-text
  table talk (that would let English do the work).
- **Alphabet and the other-play trick:**
  - `GlyphPool` is a fixed list of ~40 broad-font-coverage symbols (Dingbats
    / Misc Symbols, nothing that looks like a circle, square, triangle or
    star: e.g. `✚ ✦ ✶ ✹ ❖ ⊕ ⊗ ⊞ ⊠ ⋈ ⌘ ⌬ ⍟ ⏣ ☖ ♆ ♃ ♄ ⚶ ⚹ ⛬ ✠ ✤ ✿ ❂ ⬢ ⬡
    ⬠ ⬟ ⬣ ⧫ ⟁ ⟡ ⟐ ⟠ ⧊ ⧎ ⧖ ⧩ ⧲`). Per episode the sim draws 16 of them from
    the seed: `glyphs[16]`, the **canonical** alphabet (spectators see this).
  - Per seat the sim draws a permutation `perm[seat][16]` from the seed.
    Seat `s` sees token id `t` as glyph `glyphs[perm[s][t]]`, and its prompt
    lists its alphabet in the order `perm[s][0..15]`. A speaker's reply names
    glyphs from *its* view; the server maps them back to ids through
    `perm[speaker]^-1`; the listener is shown ids through `perm[listener]`.
    Glyph identity therefore never survives the channel, only token identity
    does — a prompt that says "use ✦ for red" or "the first glyph means red"
    coordinates nothing. Meaning has to be grounded in-episode from feedback.
- **Feedback:** after the listener picks, both pair members learn the truth
  (target, pick, correct). Every seat's prompt carries its **own history**:
  each past round it was in, with partner alias, role, the message in its own
  glyphs, the lineup / target, the pick, and the verdict. It never sees the
  other pair's rounds. Partner aliases are visible so a policy can keep
  per-partner conventions.
- **Private notes:** every reply may carry `"notes"` (≤ 600 chars). The
  server stores the latest notes per seat and feeds them back verbatim as
  `YOUR NOTES FROM EARLIER ROUNDS`. Notes are private to the seat in-game but
  **recorded in the event log and shown to spectators** — the audience
  watches each cog's dictionary form. Notes are overwritten when present in
  a reply, kept when absent.
- **Scoring:** a round-pair is a success iff the listener picked the target.
  A seat's `correct` = successes in the rounds it was in (as either role);
  seat `score = correct / roundsPlayed` (0..1, float). Results also report
  `asSpeaker` and `asListener` success counts per seat. Fully cooperative;
  the league ranks seats by mean episode score.
- **Endings:** `reason = "complete"` after `rounds` rounds; `"deadline"` if
  the episode clock stops play (see budgeting). Scores use rounds actually
  played.

## Decisions: LLM with scripted fallback

Transport, credentials, JSON-only output contract, retry-once-then-fallback,
Bedrock model list, `extractJsonObject`, and the "no credentials ⇒ every seat
scripted" rule are ported from focus `llm.nim` unchanged.

**Speaker call.** System prompt: the rules (as above, in plain words), that
the listener sees the same 16 *tokens* but under different symbols and in a
different order, that there are no words — only glyphs — and the OUTPUT
FORMAT rule (reply begins with `{`). User prompt: `Round r of R. You are
SPEAKER to <listener alias>.` · `YOUR ALPHABET (16 glyphs, use only these):
<glyphs in perm order, space-separated>` · `YOUR NOTES FROM EARLIER ROUNDS:
…` · `YOUR HISTORY: …` · `THE TARGET: 3 green triangles` · operator prompt
block (as focus: "GUIDANCE FROM YOUR OPERATOR …") ·
`Reply with ONLY {"tokens": ["✦","⊗",…], "notes": "…"} — 1 to 8 glyphs from
your alphabet.` Parsing: each entry must be exactly one glyph from the
seat's alphabet (also accept a single string with glyphs separated by
spaces); unknown glyph ⇒ invalid reply ⇒ retry once ⇒ scripted fallback.

**Listener call.** User prompt: `Round r of R. You are LISTENER to <speaker
alias>.` · alphabet · notes · history · `MESSAGE FROM <speaker>: ✦ ⊗ ✦` ·
`THE LINEUP: A) 3 green triangles  B) 1 red star  C) 3 green circles  D) 2
green triangles` · operator block · `Reply with ONLY {"pick": "B", "notes":
"…"}`. Parsing: pick must be A-D (accept lowercase, or the 0-3 / 1-4
integer forms). Invalid ⇒ retry once ⇒ scripted fallback.

**Scripted baseline** (fieldable policy; no-credentials fallback):
- As speaker: a fixed compositional code on token *ids*: message =
  `[shape, 4 + colour, 8 + count]` (three tokens, always in that order).
- As listener: a count-based decoder. It keeps, per partner alias,
  `assoc[token][attribute value]` counts accumulated from its own feedback
  (every round it was in, either role: the revealed target's three values
  are credited to every token of that round's message). It scores each
  lineup candidate by the summed association of the message's tokens with
  the candidate's three values and picks the max; ties (including the
  no-evidence start) break by the seeded RNG. Two scripted seats paired
  together converge within a pass; a scripted seat is therefore the
  "consistent-convention partner" an LLM policy must adapt to.
- Never produces notes.

**Episode budgeting.** 4 model calls per round (2 speakers + 2 listeners,
sequential, outside the lock as in focus). `EpisodeCallBudget = 240` ⇒
`rounds` capped at 60 at sample time. `PlayBudgetFraction = 0.6` of
`COWORLD_TIMEOUT_SECONDS` (assumed `episodeTimeoutSeconds` = 1200 when the
env is silent, exactly focus's rule). The deadline is checked **before every
model call**; once past it, the rest of the *current* round is decided by
the scripted baseline (instant) so the round completes, then the sim ends
with `reason = "deadline"`. `turnDelayMs` (default 300, cert 0) paces
between rounds, bounded by `PacingBudgetMs` as in focus.

## Sim module

`src/babel/types.nim` — `BabelError`, `PlayerConfig`, `GameConfig` (focus's
fields with `rounds` replacing `maxPlies`), `Scene`, `EventKind`,
`GameEvent`, `defaultGameConfig`, `update`.

`src/babel/sim.nim` — pure rules, no IO:
- `Seats = 4`, `Tokens = 16`, `MaxMessage = 8`, `LineupSize = 4`,
  `GlyphPool`, `ShapeNames`, `ColourNames`, `CogNames`.
- `Sim` = config, `names`, `glyphs: seq[string]` (16), `perm: seq[seq[int]]`
  (4×16), `inversePerm`, the full precomputed **schedule** (for each round:
  pairs with speaker/listener/target/lineup — all drawn from the seed at
  `initSim`, so a replay re-derives them), `round` (current, 0-based),
  `phase` within the round (which call is next: pair0-speak, pair0-pick,
  pair1-speak, pair1-pick), per-round live data (tokens / pick / correct per
  pair), per-seat tallies (`correct`, `asSpeaker`, `asListener`,
  `roundsPlayed`), `notes: seq[string]`, `done`, `reason`, `events`.
- Event kinds and fields (flat `GameEvent`, JSON via `eventToJson` /
  `eventFromJson`, omit unset fields):
  - `start` — `text` = "" (alphabet/perms are derivable from the seed and
    are carried in the replay `config` for the viewer's convenience).
  - `round` — `round`; `pairs: [{speaker, listener, target, lineup[4]}, {…}]`
    (serialized as `pairs` array of objects; in Nim as parallel seqs:
    `speakers[2]`, `listeners[2]`, `targets[2]`, `lineups[2][4]`).
  - `speak` — `round`, `pair`, `seat` (speaker), `other` (listener),
    `tokens: seq[int]` (ids), `scripted: bool`, `text` = the speaker's
    notes after this reply (may be empty).
  - `pick` — `round`, `pair`, `seat` (listener), `other` (speaker), `pick`
    (0..3), `correct: bool`, `scripted`, `text` = the listener's notes.
  - `end` — `text` = reason, `round` = rounds played.
- API: `initSim`, `sampleEpisode` (cap rounds to the budget, pacing),
  `tableNames`, `sceneText(id)`, `sceneOf(id): Scene`, `currentCall(sim):
  (kind, pair, seat)` (what decision is needed next), `applySpeak(sim, pair,
  tokens, notes, scripted)`, `applyPick(sim, pair, pick, notes, scripted)`,
  `endEarly`, `resultsJson`, `tableStateJson`, `replayMatch(config, events)`
  (re-derives frames by re-applying speak/pick events through the same
  rules; `round`/`start` events are checked against the derived schedule and
  the frame is appended; `end` settles), `glyphOf(sim, seat, token)`,
  `tokenOf(sim, seat, glyph)`.
- Illegal operations (wrong pair/phase, token out of range, message empty
  or > 8, pick out of range) raise `BabelError`.

**`tableStateJson`** (one frame; the viewer draws exactly this):
```json
{"seats":[{"name":"Sprocket","score":0.5,"correct":3,"asSpeaker":2,"asListener":1,
           "role":"speaker|listener|","partner":2,"notes":"…"}, ×4],
 "round":5,"rounds":24,"roundsPlayed":5,
 "glyphs":["✦",…16],"perm":[[…16],×4],
 "pairs":[{"speaker":0,"listener":1,"target":37,"lineup":[37,5,21,36],
           "tokens":[3,9,14]|null,"pick":2|null,"correct":true|null}, {…}],
 "phase":"speak0|pick0|speak1|pick1|between|done",
 "gameDone":false,"reason":""}
```
`pairs` reflects the round in progress (or the last completed round once
`done`). Scene ids are ints; the viewer decodes them.

**`resultsJson`** (platform-facing, policy names):
`{"names":[4],"scores":[4 floats],"correct":[4],"asSpeaker":[4],
"asListener":[4],"rounds":<played>,"maxRounds":<cap>,"reason":"complete|deadline"}`.

**Replay payload** (`babel.replay.v1`): `{"protocol","names","policyNames",
"config":{"rounds","seed","sampled":true,"glyphs":[16],"perm":[4][16]},
"events","results"}`; replay mode and the wasm viewer add `"states"` (one
`tableStateJson` per event prefix) exactly as focus does.

## Server, player, protocol

`src/babel/server.nim` — focus's server with the game loop replaced: loop
over `currentCall` until done; for each call snapshot the sim, ask the LLM
(or scripted) outside the lock, apply under the lock, broadcast; deadline
check before each call as specified; `finishEpisode` unchanged (final frames
to players first, then results, then replay). Endpoints identical. Player
frames never include `policyNames`; since Babel has hidden information
(targets, lineups, notes, and the other pair's traffic are not for the
seats), the **player websocket gets a redacted state**: only its own seat's
tallies, the round counter, and `done` — decisions are server-side so this
loses nothing.

`src/babel_player.nim` — focus_player with the default prompt replaced by a
sound Babel strategy (invent a compositional code: one glyph per attribute
value; as speaker be consistent; as listener update a per-partner dictionary
from feedback and write it into `notes`; prefer the near-miss reading when
unsure). Protocol `babel.player.v1`, same frame shapes as focus.

## Viewer

`client/renderer.js` — **the parley/focus chrome verbatim** (topband,
scorebug plates, feed + round heads, scrubber with round spans and beat
markers, endscreen, name map, effects bookkeeping, both drivers, replay
pacing). Replace the board scene with the Babel stage:
- Two **booths** stacked vertically (one per pair). In each booth, left to
  right: the speaker cog (sprite in its seat colour) with its **scene card**
  (a card showing `count` copies of the `shape` filled in the `colour`,
  drawn with canvas primitives — crisp, saturated, real art not a label);
  the **glyph ribbon** between the cogs (the message in canonical glyphs,
  large, drawn in the speaker's colour; it slides in when the `speak` event
  lands); the listener cog with the **lineup** of four cards labelled A-D.
  On `pick`: correct ⇒ the chosen card flashes green with a ✔; wrong ⇒ the
  chosen card shakes (small x-jitter for ~600 ms) and turns red while the
  true card gets an amber outline. Effects are timed like focus's last-move
  arrow (hold then fade).
- Under each cog: name, `score` as `correct/roundsPlayed`, and the seat's
  latest **notes** as a small parchment (3 lines, ellipsized) — the
  dictionary forming in public.
- Idle: before round 1 the booths show empty cards.
- Glyphs render with `font: "… 'rajdhani', 'Apple Symbols', 'Segoe UI
  Symbol', 'Noto Sans Symbols 2', system-ui, sans-serif"` so the symbol
  falls through to a system font when rajdhani lacks it.
- Scorebug plate: name, `correct` big, label `correct`, pips = `asSpeaker`
  (filled) + `asListener` (hollow), ▶ marker on seats acting this round.
- Feed lines: `ROUND n` heads; `Sprocket → Gizmo: ✦ ⊗ ✦` (speak, in canonical
  glyphs, speaker colour); `Gizmo picks B (3 green circles) — ✘ it was 3
  green triangles` / `— ✔` (pick; `feed-score seatN` class on success);
  `Sprocket notes: …` (say-styled, only when notes changed); `Final — 17/24
  (71%)` etc. Scrubber: one span per round, a beat marker per pick coloured
  by the listener's seat on success and a neutral ghost marker on failure,
  the end marker taller.
- Endscreen columns: `score`, `correct`, `as speaker`, `as listener`;
  verdict = the top seat's name + "LEADS THE TABLE" (or "ALL LEVEL"); title
  `FINAL — n ROUNDS`. Reason line for `deadline`.
- Wordmark `BA<span>BEL</span>`. Clock: `ROUND r / R · <phase>` e.g.
  `SPROCKET SPEAKS` / `GIZMO LISTENS`.

`replay-viewer/babel_replay.nim` (exports `bab_*`, module
`BabelReplayModule`), `config.nims`, `index.html`, `static_replay.js`,
`tools/build_replay_viewer.sh` — focus's with the renames.

## Packaging

`babel.nimble`, `compose.yaml` (service `babel`, image `coworld-babel`),
`Dockerfile` (binaries `/bin/babel`, `/bin/babel-player`),
`Dockerfile.replay-viewer`, `coworld_manifest_template.json`: game name
`babel`, image `{{BABEL_IMAGE}}`, `source_url`
`https://github.com/Metta-AI/cogame-babel/tree/main`, tags
`["emergent-communication","cooperative","language","llm-driven",
"turn-based","four-player","referential-game"]`; `config_schema` with
`tokens`/`players` min=max=4, `num_agents` 4..4, `rounds` 2..60 default 24,
the focus timing/model knobs; `results_schema` per `resultsJson` above;
player runnables `babel-player` (prompt) and `babel-coder` (`PLAYER_SCRIPTED=1`,
"the scripted code-and-decode baseline"); variant `standard` (4 named
players, `num_agents: 4`, `rounds: 24`, `turnDelayMs: 300`); certification
(`seed: 7`, `rounds: 6`, `turnDelayMs: 0`, players: `babel-player`,
`babel-coder`, `babel-player`, `babel-coder`). Protocol / docs strings
rewritten for Babel (the player protocol text must describe the `prompt`
frame, `PLAYER_PROMPT`, `PLAYER_SCRIPTED`, and that a policy is just a
prompt).

## Tests

`tests/test_sim.nim`: schedule (every ordered pair relation once per 6
rounds; pair 0 contains seat 0), scene id round-trip and text, lineup
invariants (distinct, contains target, near/partial/clear-miss distances),
glyph draw (16 distinct from the pool) and permutations (each a permutation;
`tokenOf(glyphOf(t)) == t`; different seats differ for seed 7), apply
speak/pick legality and tallies, scoring math, `endEarly`, replay
re-derivation (`frames.len == events.len + 1`, final frame equals the live
sim's `tableStateJson`), event JSON round-trip, seed determinism (same seed ⇒
identical schedule and glyphs; different seeds differ).
`tests/test_bot.nim`: four scripted seats play full episodes legally for
seeds `[1, 7, 42, 1234]`; after 12 rounds the scripted-with-scripted success
rate exceeds 0.75; `decide` falls back to scripted with no credentials;
model replies parse (glyph arrays, space-joined string, picks as letter /
lowercase / index).

## Out of scope (v1)

More than four seats, variable lineup sizes, scene spaces beyond 4×4×4,
free-text channels, cross-episode memory.
