// Generates client/fixtures/sample_replay.json: a hand-consistent Babel
// replay payload (babel.replay.v1) built strictly from the viewer contract
// in docs/plans/2026-08-21-babel-design.md. The `states` array is derived
// by re-applying the events through a tiny JS model of the sim, so every
// states[i] is the tableStateJson after events[0..<i].
//
//   node client/fixtures/gen_fixture.js
"use strict";
var fs = require("fs");
var path = require("path");

var SEATS = 4, TOKENS = 16, ROUNDS = 6;
var NAMES = ["Sprocket", "Gizmo", "Ratchet", "Widget"];
var POLICY_NAMES = ["lexicon-v3", "baseline (1)", "glyphwright", "baseline"];
var SCRIPTED = [false, false, false, true];   // Widget is the scripted coder
var POOL = ["✚", "✦", "✶", "✹", "❖", "⊕", "⊗", "⊞", "⊠", "⋈", "⌘", "⌬",
  "⍟", "⏣", "☖", "♆", "♃", "♄", "⚶", "⚹", "⛬", "✠", "✤", "✿", "❂", "⬢",
  "⬡", "⬠", "⬟", "⬣", "⧫", "⟁", "⟡", "⟐", "⟠", "⧊", "⧎", "⧖", "⧩", "⧲"];
var SHAPES = ["circle", "square", "triangle", "star"];
var COLOURS = ["red", "blue", "green", "yellow"];

// Deterministic PRNG (mulberry32).
function rng(seed) {
  var a = seed >>> 0;
  return function () {
    a = (a + 0x6D2B79F5) >>> 0;
    var t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
var rand = rng(7);
function pick(n) { return Math.floor(rand() * n); }
function shuffle(arr) {
  for (var i = arr.length - 1; i > 0; i--) {
    var j = pick(i + 1);
    var t = arr[i]; arr[i] = arr[j]; arr[j] = t;
  }
  return arr;
}

function sceneId(shape, colour, count) { return shape * 16 + colour * 4 + count; }
function sceneOf(id) {
  return { shape: id >> 4, colour: (id >> 2) & 3, count: id & 3 };
}
function sceneText(id) {
  var s = sceneOf(id);
  var n = s.count + 1;
  return n + " " + COLOURS[s.colour] + " " + SHAPES[s.shape] + (n === 1 ? "" : "s");
}

// Alphabet + per-seat permutations.
var glyphs = shuffle(POOL.slice()).slice(0, TOKENS);
var perm = [];
for (var s = 0; s < SEATS; s++) {
  var p = []; for (var t = 0; t < TOKENS; t++) p.push(t);
  perm.push(shuffle(p));
}

// Schedule: matchings M0 {(0,1),(2,3)}, M1 {(0,2),(1,3)}, M2 {(0,3),(1,2)}.
var M = [[[0, 1], [2, 3]], [[0, 2], [1, 3]], [[0, 3], [1, 2]]];
function lineupFor(target) {
  var tg = sceneOf(target);
  function variant(keep) {
    // keep: which attributes to share with the target (bitmask shape=1,colour=2,count=4)
    var v;
    do {
      v = {
        shape: (keep & 1) ? tg.shape : (tg.shape + 1 + pick(3)) % 4,
        colour: (keep & 2) ? tg.colour : (tg.colour + 1 + pick(3)) % 4,
        count: (keep & 4) ? tg.count : (tg.count + 1 + pick(3)) % 4
      };
    } while (sceneId(v.shape, v.colour, v.count) === target);
    return sceneId(v.shape, v.colour, v.count);
  }
  var masks2 = [3, 5, 6], masks1 = [1, 2, 4];
  var near = variant(masks2[pick(3)]);
  var partial = variant(masks1[pick(3)]);
  var clear = variant(0);
  return shuffle([target, near, partial, clear]);
}
var schedule = [];
for (var r = 0; r < ROUNDS; r++) {
  var pairs = M[r % 3].map(function (ab) {
    var flip = Math.floor(r / 3) % 2 === 1;
    var speaker = flip ? ab[1] : ab[0];
    var listener = flip ? ab[0] : ab[1];
    var target = pick(64);
    return { speaker: speaker, listener: listener, target: target,
      lineup: lineupFor(target) };
  });
  // Pair 0 is the pair containing seat 0.
  if (pairs[0].speaker !== 0 && pairs[0].listener !== 0) pairs.reverse();
  schedule.push(pairs);
}

// Scripted messages; LLM seats "improvise" (a noisy code that firms up).
function scriptedTokens(target) {
  var s = sceneOf(target);
  return [s.shape, 4 + s.colour, 8 + s.count];
}
function llmTokens(target, round) {
  var s = sceneOf(target);
  var base = [s.shape, 4 + s.colour, 8 + s.count];
  if (round < 2) {
    // Early rounds: longer, less systematic messages.
    base = base.concat([pick(16), pick(16)]);
    if (round === 0) base.push(pick(16));
  }
  return base;
}
// Picks: a planned mix of right and wrong.
var PICK_PLAN = [
  [false, true], [true, false], [true, true],
  [false, true], [true, true], [true, true]
];
var NOTES = {
  0: ["", "Partner Gizmo: first glyph seems to be the shape? unclear.",
    "Hypothesis: msg = [shape, colour, count]. ⊗-ish glyph = green?",
    "", "Widget is rigid: always 3 tokens in order shape/colour/count.",
    "Dictionary: pos1 shape, pos2 colour, pos3 count. Works w/ Widget & Ratchet."],
  1: ["Got it wrong — note the 2nd glyph.", "", "2nd glyph = colour (Sprocket uses it too).",
    "3rd glyph = count, I think. Keep trailing glyphs ignored.", "",
    "Same table code for everyone; trust positions."],
  2: ["", "", "Sprocket's messages are long; only first 3 matter?",
    "", "Confirmed: 3-slot code.", ""]
};

// ---- Model of the sim --------------------------------------------------
var state = {
  seats: NAMES.map(function (n) {
    return { name: n, score: 0, correct: 0, asSpeaker: 0, asListener: 0,
      role: "", partner: -1, notes: "" };
  }),
  round: -1, rounds: ROUNDS, roundsPlayed: 0,   // -1 before the first round, as the sim reports
  glyphs: glyphs, perm: perm,
  pairs: [], phase: "between", gameDone: false, reason: ""
};
function snapshot() { return JSON.parse(JSON.stringify(state)); }

var events = [];
var states = [snapshot()];
function emit(ev) { events.push(ev); states.push(snapshot()); }

emit({ kind: "start", text: "" });
for (var rr = 0; rr < ROUNDS; rr++) {
  var sched = schedule[rr];
  state.round = rr;
  state.phase = "speak0";
  state.pairs = sched.map(function (p) {
    return { speaker: p.speaker, listener: p.listener, target: p.target,
      lineup: p.lineup.slice(), tokens: null, pick: null, correct: null };
  });
  state.seats.forEach(function (seat, i) {
    sched.forEach(function (p) {
      if (p.speaker === i) { seat.role = "speaker"; seat.partner = p.listener; }
      if (p.listener === i) { seat.role = "listener"; seat.partner = p.speaker; }
    });
  });
  emit({ kind: "round", round: rr, pairs: sched.map(function (p) {
    return { speaker: p.speaker, listener: p.listener, target: p.target,
      lineup: p.lineup.slice() };
  }) });
  for (var pi = 0; pi < 2; pi++) {
    var p = sched[pi];
    var sp = p.speaker, li = p.listener;
    var tokens = SCRIPTED[sp] ? scriptedTokens(p.target) : llmTokens(p.target, rr);
    var spNotes = SCRIPTED[sp] ? "" : (NOTES[sp][rr] || "");
    if (spNotes) state.seats[sp].notes = spNotes;
    state.pairs[pi].tokens = tokens;
    state.phase = "pick" + pi;
    emit({ kind: "speak", round: rr, pair: pi, seat: sp, other: li,
      tokens: tokens, scripted: SCRIPTED[sp], text: state.seats[sp].notes });
    var correct = PICK_PLAN[rr][pi];
    var choice;
    if (correct) {
      choice = p.lineup.indexOf(p.target);
    } else {
      do { choice = pick(4); } while (p.lineup[choice] === p.target);
    }
    var liNotes = SCRIPTED[li] ? "" : (NOTES[li][rr] || "");
    if (liNotes) state.seats[li].notes = liNotes;
    state.pairs[pi].pick = choice;
    state.pairs[pi].correct = correct;
    if (correct) {
      state.seats[sp].correct++; state.seats[sp].asSpeaker++;
      state.seats[li].correct++; state.seats[li].asListener++;
    }
    state.phase = pi === 0 ? "speak1" : "between";
    if (pi === 1) {
      state.roundsPlayed = rr + 1;
      state.seats.forEach(function (seat) {
        seat.role = ""; seat.partner = -1;
        seat.score = seat.correct / state.roundsPlayed;
      });
    }
    emit({ kind: "pick", round: rr, pair: pi, seat: li, other: sp,
      pick: choice, correct: correct, scripted: SCRIPTED[li],
      text: state.seats[li].notes });
  }
}
state.phase = "done";
state.gameDone = true;
state.reason = "complete";
emit({ kind: "end", text: "complete", round: ROUNDS });

var results = {
  names: POLICY_NAMES.slice(),
  scores: state.seats.map(function (s) { return s.score; }),
  correct: state.seats.map(function (s) { return s.correct; }),
  asSpeaker: state.seats.map(function (s) { return s.asSpeaker; }),
  asListener: state.seats.map(function (s) { return s.asListener; }),
  rounds: ROUNDS, maxRounds: ROUNDS, reason: "complete"
};
var payload = {
  protocol: "babel.replay.v1",
  names: NAMES, policyNames: POLICY_NAMES,
  config: { rounds: ROUNDS, seed: 7, sampled: true, glyphs: glyphs, perm: perm },
  events: events, results: results, states: states
};
if (states.length !== events.length + 1) throw new Error("states/events mismatch");
var out = path.join(__dirname, "sample_replay.json");
fs.writeFileSync(out, JSON.stringify(payload, null, 1));
console.log("wrote", out, events.length, "events;",
  "glyphs:", glyphs.join(" "),
  "\nscenes r0:", schedule[0].map(function (p) { return sceneText(p.target); }));
