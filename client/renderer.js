// Babel shared renderer + drivers.
//
// One canvas scene (two booths — one per pair — each with a speaker cog and
// its scene card, the glyph ribbon carrying the message, and a listener cog
// with its four-card lineup; names, tallies and private-notes parchments
// under every cog) fed by three drivers: live /global websocket, live
// /player websocket, and replay (from the game's /replay websocket or the
// static wasm bundle). All state derivation happens server-side /
// wasm-side; this file only draws state objects:
//   {seats:[{name,score,correct,asSpeaker,asListener,role,partner,notes} ×4],
//    round, rounds, roundsPlayed, glyphs[16], perm[4][16],
//    pairs:[{speaker,listener,target,lineup[4],tokens|null,pick|null,
//            correct|null} ×2],
//    phase:"speak0|pick0|speak1|pick1|between|done", gameDone, reason}
// Spectators always see the CANONICAL alphabet (glyphs[t]); the per-seat
// permutations are the agents' problem, not the audience's.
(function () {
  "use strict";

  // Ink & Print palette, matching the coworld-ctf broadcast chrome. Babel
  // seats four cogs: red, blue, green, yellow. The extra colours stay so
  // the chrome's seatN classes keep lining up with the CSS.
  var COLORS = ["red", "blue", "green", "yellow", "violet", "orange"];
  var COLOR_HEX = {
    red: "#e0523a",
    blue: "#3f7cc4",
    green: "#45a85e",
    yellow: "#ddc531",
    violet: "#a86fd6",
    orange: "#e08a3a"
  };
  var PAPER = "#f2e8d8";
  var INK = "#2a1f16";
  var AMBER = "#e8a33d";
  var GHOST = "#8a7f72";
  var CARD_EDGE = "rgba(42, 31, 22, 0.85)";
  var STRIP = "rgba(242, 232, 216, 0.06)";
  // The pick verdict (green flash / red shake + amber truth) holds for a
  // beat, then fades down to a resting tint so a paused frame still reads.
  var PICK_HOLD_MS = 2500;
  var PICK_FADE_MS = 700;
  var PICK_REST = 0.35;
  var SHAKE_MS = 600;
  var RIBBON_SLIDE_MS = 420;

  // Symbols fall through to a system symbol font when rajdhani lacks them.
  var GLYPH_FONT = "'rajdhani', 'Apple Symbols', 'Segoe UI Symbol', " +
    "'Noto Sans Symbols 2', system-ui, sans-serif";

  var SHAPES = ["circle", "square", "triangle", "star"];
  var COLOURS = ["red", "blue", "green", "yellow"];
  var LETTERS = "ABCD";

  // Scene id = shape*16 + colour*4 + count; count 0..3 means 1..4 items.
  function sceneOf(id) {
    if (typeof id !== "number" || id < 0 || id > 63) return null;
    return { shape: id >> 4, colour: (id >> 2) & 3, count: (id & 3) + 1 };
  }

  function sceneText(id) {
    var s = sceneOf(id);
    if (!s) return "?";
    return s.count + " " + COLOURS[s.colour] + " " + SHAPES[s.shape] +
      (s.count === 1 ? "" : "s");
  }

  function assetUrl(base, name) {
    return base.replace(/\/$/, "") + "/" + name;
  }

  function loadImages(base, names, done) {
    var images = {};
    var pending = names.length;
    names.forEach(function (name) {
      var img = new Image();
      img.onload = img.onerror = function () {
        pending -= 1;
        if (pending === 0) done(images);
      };
      img.src = assetUrl(base, name);
      images[name] = img;
    });
  }

  function seatColor(index) {
    return COLORS[index % COLORS.length];
  }

  function makeRenderer(canvas, assetBase, onReady) {
    var ctx = canvas.getContext("2d");
    var names = ["soldier_red_front.png", "soldier_blue_front.png",
      "soldier_green_front.png", "soldier_yellow_front.png",
      "arena_floor.png"];
    loadImages(assetBase, names, function (images) {
      onReady({
        draw: function (view) { draw(ctx, canvas, images, view); }
      });
    });
  }

  function ellipsize(ctx, text, maxWidth) {
    if (ctx.measureText(text).width <= maxWidth) return text;
    var cut = text;
    while (cut.length > 1 && ctx.measureText(cut + "…").width > maxWidth) {
      cut = cut.slice(0, -1);
    }
    return cut + "…";
  }

  // Colour helpers for the shape rims / highlights.
  function hexToRgb(hex) {
    var n = parseInt(hex.slice(1), 16);
    return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
  }
  function shade(hex, factor) {
    var c = hexToRgb(hex).map(function (v) {
      return Math.max(0, Math.min(255, Math.round(v * factor)));
    });
    return "rgb(" + c[0] + "," + c[1] + "," + c[2] + ")";
  }
  function rgba(hex, alpha) {
    var c = hexToRgb(hex);
    return "rgba(" + c[0] + "," + c[1] + "," + c[2] + "," + alpha + ")";
  }

  // Nominal cog size; everything around a cog is measured as a multiple of
  // it so the whole seat block scales as one unit.
  var SEAT_BASE = 84;
  var NOTE_LINES = 3, NOTE_LINE_H = 12, NOTE_PAD = 6;
  var LABEL_GUTTER = 16;

  function noteHeight(scale) {
    return (NOTE_LINES * NOTE_LINE_H + NOTE_PAD * 2 - 2) * scale;
  }

  function seatBlock(size) {
    // The seat block: role tag headroom above the cog, the cog, then name,
    // score and the notes parchment below it. Parchment room is reserved
    // even while a seat has no notes: notes arrive without warning.
    var scale = size / SEAT_BASE;
    return {
      w: size * 1.9,
      above: size * 0.18,
      cogHalf: size / 2,
      below: size * 0.62 + 34 * scale + noteHeight(scale)
    };
  }

  function computeLayout(width, height) {
    // Two booths stacked vertically. In each, left to right: speaker block,
    // target card, ribbon, lineup of four cards, listener block. The ribbon
    // soaks up whatever width is left; the seat size shrinks until the
    // fixed parts fit. Callers embed this viewer at wildly different sizes,
    // so the fit is solved per frame rather than assumed.
    var margin = 10;
    var boothGap = 8;
    var boothH = (height - 2 * margin - boothGap) / 2;
    var size = Math.min(SEAT_BASE, width / 9, height / 5);
    var layout = null;
    for (var attempt = 0; attempt < 40; attempt++) {
      var b = seatBlock(size);
      var scale = size / SEAT_BASE;
      var gap = 12 * scale;
      var cardH = size * 1.45;
      var cardW = cardH * 0.78;
      var lcardH = cardH * 0.82;
      var lcardW = lcardH * 0.78;
      var lgap = 6 * scale;
      var gutter = LABEL_GUTTER * scale;
      var ribbonMin = size * 2.0;
      var fixedW = 2 * margin + 2 * b.w + cardW + 4 * lcardW + 3 * lgap +
        ribbonMin + 4 * gap;
      var blockH = b.above + 2 * b.cogHalf + b.below;
      var fits = fixedW <= width && blockH <= boothH &&
        cardH + gutter <= boothH;
      var ribbonW = Math.max(width - fixedW + ribbonMin, ribbonMin);
      var booths = [];
      for (var k = 0; k < 2; k++) {
        var top = margin + k * (boothH + boothGap);
        var cy = top + boothH / 2;
        var cogY = cy - blockH / 2 + b.above + b.cogHalf;
        var x = margin;
        var speaker = { x: x + b.w / 2, y: cogY };
        x += b.w + gap;
        var target = { x: x, y: cy - cardH / 2, w: cardW, h: cardH };
        x += cardW + gap;
        var ribbon = { x: x, y: cy - size * 0.45, w: ribbonW, h: size * 0.9 };
        x += ribbonW + gap;
        var lineup = [];
        for (var c = 0; c < 4; c++) {
          lineup.push({ x: x + c * (lcardW + lgap),
            y: cy - lcardH / 2 + gutter / 2, w: lcardW, h: lcardH });
        }
        x += 4 * lcardW + 3 * lgap + gap;
        var listener = { x: x + b.w / 2, y: cogY };
        booths.push({ top: top, h: boothH, speaker: speaker, target: target,
          ribbon: ribbon, lineup: lineup, listener: listener, gutter: gutter });
      }
      layout = { size: size, scale: scale, booths: booths, width: width,
        height: height };
      if (fits || size < 24) break;
      size *= 0.92;
    }
    return layout;
  }

  // Which seats sit in which booth: the state's pairs when it has them
  // (live global / replay), else the resting arrangement so a redacted
  // player frame still shows four cogs at two empty tables.
  function boothPairs(view) {
    var pairs = view.pairs || [];
    if (pairs.length >= 2) return pairs;
    var rest = [{ speaker: 0, listener: 1 }, { speaker: 2, listener: 3 }];
    return rest.map(function (p, i) { return pairs[i] || p; });
  }

  function draw(ctx, canvas, images, view) {
    var w = canvas.width;
    var h = canvas.height;
    var seats = view.seats || [];
    var now = view.now || Date.now();
    var layout = computeLayout(w, h);
    var scale = layout.scale;
    var size = layout.size;
    var fx = view.effects || { speakAt: [], pickAt: [] };
    var glyphs = view.glyphs || [];

    // Floor.
    var floor = images["arena_floor.png"];
    if (floor && floor.width) {
      ctx.fillStyle = ctx.createPattern(floor, "repeat");
    } else {
      ctx.fillStyle = "#16110d";
    }
    ctx.fillRect(0, 0, w, h);
    ctx.fillStyle = "rgba(18, 13, 9, 0.45)";
    ctx.fillRect(0, 0, w, h);

    // Leaders get a tag once the table is settled.
    var top = -1;
    var level = true;
    seats.forEach(function (seat) {
      if (seat.correct > top) top = seat.correct;
    });
    seats.forEach(function (seat) {
      if (seat.correct !== top) level = false;
    });

    var pairs = boothPairs(view);
    pairs.forEach(function (pair, pi) {
      var booth = layout.booths[pi];
      if (!booth) return;
      var speakerSeat = seats[pair.speaker];
      var listenerSeat = seats[pair.listener];
      var speakerColor = seatColor(pair.speaker);
      var listenerColor = seatColor(pair.listener);
      var pending = pendingSeat(view.phase, pairs);

      // Booth strip: a faint plate so the two tables read as rooms.
      ctx.save();
      ctx.fillStyle = STRIP;
      roundRect(ctx, 4, booth.top, w - 8, booth.h, 10 * scale);
      ctx.fill();
      ctx.restore();

      // Speaker: cog, scene card.
      drawSeat(ctx, images, speakerSeat, pair.speaker, booth.speaker, size,
        scale, {
          role: pair.target !== undefined && pair.target !== null ?
            "SPEAKS" : "",
          pending: pending === pair.speaker && !view.done,
          leads: view.done && !level && speakerSeat &&
            speakerSeat.correct === top,
          roundsPlayed: view.roundsPlayed
        });
      drawCard(ctx, booth.target, pair.target, scale, {
        accent: COLOR_HEX[speakerColor]
      });

      // Ribbon: the message in canonical glyphs, speaker-coloured.
      var speakAt = fx.speakAt[pi];
      var slide = typeof speakAt === "number" ?
        Math.min(1, (now - speakAt) / RIBBON_SLIDE_MS) : 1;
      drawRibbon(ctx, booth.ribbon, pair.tokens, glyphs,
        COLOR_HEX[speakerColor], slide, scale);

      // Lineup A–D with the pick verdict on top.
      var pickAt = fx.pickAt[pi];
      var pickAge = typeof pickAt === "number" ? now - pickAt : null;
      var verdictAlpha = pickAge === null ? PICK_REST :
        pickAge < PICK_HOLD_MS ? 1 :
        Math.max(PICK_REST, 1 - (pickAge - PICK_HOLD_MS) / PICK_FADE_MS *
          (1 - PICK_REST));
      var lineup = pair.lineup || [];
      for (var c = 0; c < 4; c++) {
        var rect = booth.lineup[c];
        var picked = typeof pair.pick === "number" && pair.pick === c;
        var isTruth = lineup[c] !== undefined && lineup[c] === pair.target;
        var shake = 0;
        if (picked && pair.correct === false && pickAge !== null &&
            pickAge < SHAKE_MS) {
          shake = Math.sin(pickAge / 22) * 4 * scale * (1 - pickAge / SHAKE_MS);
        }
        var shifted = { x: rect.x + shake, y: rect.y, w: rect.w, h: rect.h };
        drawCard(ctx, shifted, lineup[c], scale, {
          label: LETTERS[c],
          labelColor: picked ? COLOR_HEX[listenerColor] : GHOST,
          verdict: picked ? (pair.correct ? "correct" : "wrong") :
            (isTruth && pair.correct === false ? "truth" : ""),
          verdictAlpha: verdictAlpha
        });
      }

      // Listener.
      drawSeat(ctx, images, listenerSeat, pair.listener, booth.listener, size,
        scale, {
          role: pair.target !== undefined && pair.target !== null ?
            "LISTENS" : "",
          pending: pending === pair.listener && !view.done,
          leads: view.done && !level && listenerSeat &&
            listenerSeat.correct === top,
          roundsPlayed: view.roundsPlayed
        });
    });
  }

  // The seat whose decision the table is waiting on.
  function pendingSeat(phase, pairs) {
    var m = /^(speak|pick)([01])$/.exec(phase || "");
    if (!m) return -1;
    var pair = pairs[Number(m[2])];
    if (!pair) return -1;
    return m[1] === "speak" ? pair.speaker : pair.listener;
  }

  // Cog, role tag, name, score and the notes parchment.
  function drawSeat(ctx, images, seat, index, pos, size, scale, opts) {
    if (!seat) return;
    var color = seatColor(index);
    var sprite = images["soldier_" + color + "_front.png"];

    ctx.save();
    ctx.translate(pos.x, pos.y);
    if (sprite && sprite.width) {
      ctx.imageSmoothingEnabled = false;
      ctx.drawImage(sprite, -size / 2, -size / 2, size, size);
    } else {
      ctx.fillStyle = COLOR_HEX[color];
      ctx.fillRect(-size / 3, -size / 3, size / 1.5, size / 1.5);
    }
    ctx.restore();

    // Acting halo.
    if (opts.pending) {
      ctx.save();
      ctx.strokeStyle = AMBER;
      ctx.lineWidth = 3;
      ctx.setLineDash([6, 5]);
      ctx.beginPath();
      ctx.arc(pos.x, pos.y, size * 0.62, 0, Math.PI * 2);
      ctx.stroke();
      ctx.restore();
    }

    // Role tag over the cog while a round is on; LEADS once it is over.
    var tag = opts.leads ? "LEADS" : opts.role;
    if (tag) {
      drawTag(ctx, pos.x, pos.y - size * 0.52, tag,
        opts.leads ? AMBER : COLOR_HEX[color], scale);
    }

    // Name.
    ctx.save();
    ctx.font = "600 " + Math.round(13 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.textAlign = "center";
    ctx.textBaseline = "alphabetic";
    ctx.fillStyle = PAPER;
    ctx.shadowColor = "rgba(0,0,0,0.8)";
    ctx.shadowBlur = 4;
    ctx.fillText(ellipsize(ctx, seat.name || "", size * 1.7), pos.x,
      pos.y + size * 0.62 + 12 * scale);

    // Score: correct / roundsPlayed in amber.
    var played = typeof opts.roundsPlayed === "number" ? opts.roundsPlayed :
      (seat.roundsPlayed || 0);
    ctx.font = "700 " + Math.round(13 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = AMBER;
    ctx.fillText((seat.correct || 0) + " / " + played, pos.x,
      pos.y + size * 0.62 + 27 * scale);
    ctx.restore();

    // Notes parchment.
    var bw = size * 1.9;
    drawParchment(ctx, pos.x - bw / 2, pos.y + size * 0.62 + 34 * scale, bw,
      seat.notes || "", scale);
  }

  function drawParchment(ctx, x, y, w, text, scale) {
    var pad = NOTE_PAD * scale;
    var lineH = NOTE_LINE_H * scale;
    var h = noteHeight(scale);
    ctx.save();
    ctx.font = Math.round(10.5 * scale) + "px " + GLYPH_FONT;
    var lines = text ? wrapLines(ctx, text, w - pad * 2, NOTE_LINES) : [];
    ctx.fillStyle = text ? "rgba(242, 232, 216, 0.92)" :
      "rgba(242, 232, 216, 0.10)";
    ctx.strokeStyle = text ? CARD_EDGE : "rgba(242, 232, 216, 0.18)";
    ctx.lineWidth = 1;
    ctx.setLineDash(text ? [] : [3, 3]);
    roundRect(ctx, x, y, w, h, 3 * scale);
    ctx.fill();
    ctx.stroke();
    ctx.setLineDash([]);
    // Folded corner.
    if (text) {
      ctx.beginPath();
      ctx.moveTo(x + w - 7 * scale, y);
      ctx.lineTo(x + w, y + 7 * scale);
      ctx.lineTo(x + w - 7 * scale, y + 7 * scale);
      ctx.closePath();
      ctx.fillStyle = "rgba(42, 31, 22, 0.25)";
      ctx.fill();
    }
    ctx.textAlign = "left";
    ctx.textBaseline = "top";
    if (text) {
      ctx.fillStyle = INK;
      lines.forEach(function (line, i) {
        ctx.fillText(line, x + pad, y + pad + i * lineH);
      });
    } else {
      ctx.fillStyle = GHOST;
      ctx.font = "600 " + Math.round(8 * scale) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.fillText("NO NOTES YET", x + pad, y + pad);
    }
    ctx.restore();
  }

  function wrapLines(ctx, text, maxWidth, maxLines) {
    var words = text.split(/\s+/);
    var lines = [];
    var line = "";
    words.forEach(function (word) {
      var probe = line ? line + " " + word : word;
      if (ctx.measureText(probe).width > maxWidth && line) {
        lines.push(line);
        line = word;
      } else {
        line = probe;
      }
    });
    if (line) lines.push(line);
    var overflow = lines.length > maxLines;
    lines = lines.slice(0, maxLines);
    if (overflow && lines.length) {
      lines[lines.length - 1] = ellipsize(ctx, lines[lines.length - 1] + "…",
        maxWidth);
    }
    return lines.map(function (l) { return ellipsize(ctx, l, maxWidth); });
  }

  // A scene card: `count` copies of `shape` filled in `colour` on paper.
  // No scene (idle table / redacted frame) draws an empty dashed card.
  // opts: {label, labelColor, accent, verdict:"correct|wrong|truth|",
  //        verdictAlpha}
  function drawCard(ctx, rect, sceneId, scale, opts) {
    var scene = sceneOf(sceneId);
    var r = 5 * scale;
    ctx.save();
    if (opts.label) {
      ctx.font = "700 " + Math.round(12 * scale) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.textAlign = "center";
      ctx.textBaseline = "alphabetic";
      ctx.fillStyle = opts.labelColor || "#b8ac98";
      ctx.fillText(opts.label, rect.x + rect.w / 2, rect.y - 4 * scale);
    }
    if (!scene) {
      ctx.fillStyle = "rgba(242, 232, 216, 0.08)";
      ctx.strokeStyle = "rgba(242, 232, 216, 0.22)";
      ctx.lineWidth = 1;
      ctx.setLineDash([4, 3]);
      roundRect(ctx, rect.x, rect.y, rect.w, rect.h, r);
      ctx.fill();
      ctx.stroke();
      ctx.restore();
      return;
    }
    // Paper with a soft drop shadow.
    ctx.shadowColor = "rgba(0,0,0,0.55)";
    ctx.shadowBlur = 6 * scale;
    ctx.shadowOffsetY = 2 * scale;
    ctx.fillStyle = PAPER;
    roundRect(ctx, rect.x, rect.y, rect.w, rect.h, r);
    ctx.fill();
    ctx.shadowColor = "transparent";
    ctx.strokeStyle = opts.accent || CARD_EDGE;
    ctx.lineWidth = opts.accent ? 2 : 1;
    ctx.stroke();

    // Items: 1 centred, 2 side by side, 3 in a triangle, 4 in a grid.
    var spots = [
      [[0.5, 0.5]],
      [[0.3, 0.5], [0.7, 0.5]],
      [[0.5, 0.3], [0.3, 0.7], [0.7, 0.7]],
      [[0.3, 0.3], [0.7, 0.3], [0.3, 0.7], [0.7, 0.7]]
    ][scene.count - 1];
    var radius = rect.w * (scene.count === 1 ? 0.3 : 0.17);
    var color = COLOR_HEX[COLOURS[scene.colour]];
    spots.forEach(function (spot) {
      drawShape(ctx, scene.shape, rect.x + spot[0] * rect.w,
        rect.y + spot[1] * rect.h, radius, color);
    });

    // Verdict overlay.
    var a = opts.verdictAlpha === undefined ? 1 : opts.verdictAlpha;
    if (opts.verdict === "correct" || opts.verdict === "wrong") {
      var tint = opts.verdict === "correct" ? COLOR_HEX.green : COLOR_HEX.red;
      ctx.fillStyle = rgba(tint, 0.55 * a);
      roundRect(ctx, rect.x, rect.y, rect.w, rect.h, r);
      ctx.fill();
      ctx.strokeStyle = rgba(tint, a);
      ctx.lineWidth = 3;
      ctx.stroke();
      ctx.font = "700 " + Math.round(rect.h * 0.55) + "px " + GLYPH_FONT;
      ctx.textAlign = "center";
      ctx.textBaseline = "middle";
      ctx.globalAlpha = a;
      ctx.fillStyle = PAPER;
      ctx.shadowColor = INK;
      ctx.shadowBlur = 4;
      ctx.fillText(opts.verdict === "correct" ? "✔" : "✘",
        rect.x + rect.w / 2, rect.y + rect.h / 2 + rect.h * 0.03);
      ctx.globalAlpha = 1;
    } else if (opts.verdict === "truth") {
      ctx.strokeStyle = rgba(AMBER, a);
      ctx.lineWidth = 3;
      roundRect(ctx, rect.x - 2, rect.y - 2, rect.w + 4, rect.h + 4,
        r + 2);
      ctx.stroke();
    }
    ctx.restore();
  }

  function drawShape(ctx, shape, cx, cy, radius, color) {
    ctx.save();
    ctx.fillStyle = color;
    ctx.strokeStyle = shade(color, 0.55);
    ctx.lineWidth = Math.max(1, radius * 0.12);
    ctx.lineJoin = "round";
    ctx.beginPath();
    if (shape === 0) {
      ctx.arc(cx, cy, radius, 0, Math.PI * 2);
    } else if (shape === 1) {
      var s = radius * 0.9;
      roundRect(ctx, cx - s, cy - s, 2 * s, 2 * s, radius * 0.15);
    } else if (shape === 2) {
      var tr = radius * 1.1;
      for (var i = 0; i < 3; i++) {
        var ang = -Math.PI / 2 + i * Math.PI * 2 / 3;
        var px = cx + Math.cos(ang) * tr;
        var py = cy + radius * 0.12 + Math.sin(ang) * tr;
        if (i === 0) ctx.moveTo(px, py); else ctx.lineTo(px, py);
      }
      ctx.closePath();
    } else {
      var outer = radius * 1.12;
      var inner = outer * 0.45;
      for (var k = 0; k < 10; k++) {
        var rr = k % 2 === 0 ? outer : inner;
        var a = -Math.PI / 2 + k * Math.PI / 5;
        var sx = cx + Math.cos(a) * rr;
        var sy = cy + radius * 0.06 + Math.sin(a) * rr;
        if (k === 0) ctx.moveTo(sx, sy); else ctx.lineTo(sx, sy);
      }
      ctx.closePath();
    }
    ctx.fill();
    ctx.stroke();
    // Highlight.
    ctx.beginPath();
    ctx.arc(cx - radius * 0.3, cy - radius * 0.3, radius * 0.22, 0,
      Math.PI * 2);
    ctx.fillStyle = "rgba(242, 232, 216, 0.35)";
    ctx.fill();
    ctx.restore();
  }

  // The message between the cogs, large canonical glyphs in the speaker's
  // colour, sliding in from the speaker's side when it lands.
  function drawRibbon(ctx, rect, tokens, glyphs, color, slide, scale) {
    ctx.save();
    ctx.fillStyle = "rgba(18, 13, 9, 0.55)";
    ctx.strokeStyle = "rgba(242, 232, 216, 0.14)";
    ctx.lineWidth = 1;
    roundRect(ctx, rect.x, rect.y, rect.w, rect.h, rect.h / 2);
    ctx.fill();
    ctx.stroke();
    // Direction: a faint shaft with a head at the listener's end.
    var midY = rect.y + rect.h / 2;
    ctx.strokeStyle = "rgba(242, 232, 216, 0.18)";
    ctx.fillStyle = "rgba(242, 232, 216, 0.18)";
    ctx.lineWidth = 1.5;
    ctx.beginPath();
    ctx.moveTo(rect.x + rect.h * 0.5, rect.y + rect.h - 5 * scale);
    ctx.lineTo(rect.x + rect.w - rect.h * 0.55, rect.y + rect.h - 5 * scale);
    ctx.stroke();
    ctx.beginPath();
    ctx.moveTo(rect.x + rect.w - rect.h * 0.4, rect.y + rect.h - 5 * scale);
    ctx.lineTo(rect.x + rect.w - rect.h * 0.6, rect.y + rect.h - 9 * scale);
    ctx.lineTo(rect.x + rect.w - rect.h * 0.6, rect.y + rect.h - 1 * scale);
    ctx.closePath();
    ctx.fill();
    if (!tokens || !tokens.length) {
      ctx.fillStyle = GHOST;
      ctx.font = "600 " + Math.round(9 * scale) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.textAlign = "center";
      ctx.textBaseline = "middle";
      ctx.fillText("· · ·", rect.x + rect.w / 2, midY);
      ctx.restore();
      return;
    }
    var n = tokens.length;
    var fontPx = Math.min(rect.h * 0.72, (rect.w - rect.h) / n * 0.85);
    ctx.font = "700 " + Math.round(fontPx) + "px " + GLYPH_FONT;
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    var step = Math.min(fontPx * 1.25, (rect.w - rect.h) / n);
    var startX = rect.x + rect.w / 2 - (n - 1) * step / 2;
    var eased = 1 - Math.pow(1 - slide, 3);
    var offset = (1 - eased) * rect.w * 0.25;
    ctx.globalAlpha = Math.max(0.05, eased);
    ctx.fillStyle = color;
    ctx.shadowColor = "rgba(0,0,0,0.8)";
    ctx.shadowBlur = 4;
    tokens.forEach(function (t, i) {
      var glyph = glyphs[t] !== undefined ? glyphs[t] : "?";
      ctx.fillText(glyph, startX + i * step - offset, midY - fontPx * 0.04);
    });
    ctx.restore();
  }

  // A small tag ("SPEAKS", "LEADS") in the seat's colour, pinned over the
  // cog.
  function drawTag(ctx, x, y, text, accent, scale) {
    ctx.save();
    ctx.font = "700 " + Math.round(10 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    var label = text.toUpperCase();
    var pad = 5 * scale;
    var bw = ctx.measureText(label).width + pad * 2;
    var bh = 15 * scale;
    ctx.fillStyle = "rgba(242, 232, 216, 0.95)";
    ctx.strokeStyle = accent;
    ctx.lineWidth = 2;
    roundRect(ctx, x - bw / 2, y - bh / 2, bw, bh, 4 * scale);
    ctx.fill();
    ctx.stroke();
    ctx.fillStyle = INK;
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillText(label, x, y + scale);
    ctx.restore();
  }

  function roundRect(ctx, x, y, w, h, r) {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.arcTo(x + w, y, x + w, y + h, r);
    ctx.arcTo(x + w, y + h, x, y + h, r);
    ctx.arcTo(x, y + h, x, y, r);
    ctx.arcTo(x, y, x + w, y, r);
    ctx.closePath();
  }

  // ---- Names ---------------------------------------------------------------

  // The agents only ever hear anonymous table names ("Sprocket", "Gizmo");
  // the payload carries the policy names separately, spectator-side only.
  // A name map swaps them in wherever a name is RENDERED while the
  // underlying events keep the aliases. Baseline fillers keep their alias.
  // The map also carries the canonical alphabet so feed lines can spell
  // messages the way the stage does.
  function isBaselineFiller(name) {
    return /^baseline(\s*\(\d+\))?$/i.test(name);
  }

  function makeNameMap(tableNames, policyNames, glyphs) {
    var table = tableNames || [];
    var alphabet = glyphs || [];
    var display = table.map(function (name, i) {
      var policy = policyNames && policyNames[i];
      return (policy && !isBaselineFiller(policy)) ? policy : name;
    });
    var byAlias = {};
    table.forEach(function (name, i) {
      if (name && display[i] && display[i] !== name) byAlias[name] = display[i];
    });
    var aliases = Object.keys(byAlias);
    var pattern = aliases.length ? new RegExp(
      "\\b(?:" + aliases.map(function (name) {
        return name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      }).join("|") + ")\\b", "g") : null;
    return {
      seat: function (i) { return display[i] || ("Seat " + i); },
      text: function (text) {
        if (!pattern) return text;
        return text.replace(pattern, function (match) {
          return byAlias[match];
        });
      },
      glyph: function (t) {
        return alphabet[t] !== undefined ? alphabet[t] : "?";
      }
    };
  }

  function applyNames(seats, nameMap) {
    return (seats || []).map(function (seat, i) {
      var copy = Object.assign({}, seat);
      copy.name = nameMap.seat(i);
      return copy;
    });
  }

  function clampName(name) {
    var n = name || "";
    return n.length > 24 ? n.slice(0, 23) + "…" : n;
  }

  // ---- Event feed ----------------------------------------------------------

  // Round numbers in events are 0-based per the sim; a payload that counts
  // from 1 is tolerated by reading the first round event.
  function roundBase(events) {
    for (var i = 0; i < events.length; i++) {
      if (events[i].kind === "round") return events[i].round === 1 ? 1 : 0;
    }
    return 0;
  }

  function spellTokens(tokens, nameMap) {
    return (tokens || []).map(function (t) { return nameMap.glyph(t); })
      .join(" ");
  }

  // `ctx` carries what a line needs from earlier events: the current
  // round's pairs (for lineups) and the running success tally.
  function describeEvent(event, nameMap, ctx) {
    function name(i) {
      return clampName(nameMap.seat(i));
    }
    switch (event.kind) {
      case "start":
        return "Table set — sixteen glyphs, no meanings.";
      case "round":
        return "Pairs: " + (event.pairs || []).map(function (p) {
          return name(p.speaker) + " → " + name(p.listener);
        }).join(" · ");
      case "speak":
        return name(event.seat) + " → " + name(event.other) + ": " +
          spellTokens(event.tokens, nameMap);
      case "pick":
        var pair = ctx.pairs && ctx.pairs[event.pair];
        var lineup = pair && pair.lineup || [];
        var chosen = lineup[event.pick];
        var letter = LETTERS[event.pick] || "?";
        var verdict = event.correct ? " — ✔" :
          " — ✘ it was " + (pair ? sceneText(pair.target) : "?");
        return name(event.seat) + " picks " + letter +
          (chosen !== undefined ? " (" + sceneText(chosen) + ")" : "") +
          verdict;
      case "end":
        return endText(event, ctx);
      default: return JSON.stringify(event);
    }
  }

  function endText(event, ctx) {
    var total = ctx.pairRounds || 0;
    var pct = total ? Math.round(ctx.successes / total * 100) : 0;
    return "Final — " + ctx.successes + "/" + total + " (" + pct + "%)" +
      (event.text === "deadline" ? " — episode deadline." : ".");
  }

  function blockHead(block) {
    return block < 0 ? "SETUP" : "ROUND " + (block + 1);
  }

  // Renders the full transcript grouped into one section per round.
  // currentIndex (replay) marks how far playback has reached; omit it for
  // live views.
  function renderFeed(element, events, nameMap, currentIndex) {
    var live = currentIndex === undefined;
    var limit = live ? events.length : currentIndex;
    var base = roundBase(events);
    var html = "";
    var lastBlock = null;
    var ctx = { pairs: null, successes: 0, pairRounds: 0 };
    var lastNotes = {};
    for (var i = 0; i < events.length; i++) {
      var event = events[i];
      var block = event.kind === "start" ? -1 :
        event.kind === "end" ? lastBlock : event.round - base;
      if (block !== lastBlock) {
        html += '<div class="feed-round-head">' + blockHead(block) +
          "</div>";
        lastBlock = block;
      }
      if (event.kind === "round") ctx.pairs = event.pairs || [];
      if (event.kind === "pick") {
        ctx.pairRounds += 1;
        if (event.correct) ctx.successes += 1;
      }
      var scored = event.kind === "pick" && event.correct;
      var cls = "feed-line feed-" + event.kind +
        (event.kind === "speak" ? " seat" + (event.seat % COLORS.length) :
          "") +
        (event.kind === "end" ? " feed-rwin" : "") +
        (scored ? " feed-score seat" + (event.seat % COLORS.length) : "") +
        (i >= limit ? " feed-future" : "");
      html += '<div class="' + cls + '">' +
        escapeHtml(describeEvent(event, nameMap, ctx)) + "</div>";
      // Notes: say-styled, only when the seat's notes changed.
      if ((event.kind === "speak" || event.kind === "pick") && event.text &&
          event.text !== lastNotes[event.seat]) {
        lastNotes[event.seat] = event.text;
        html += '<div class="feed-line feed-say' +
          (i >= limit ? " feed-future" : "") + '">' +
          escapeHtml(clampName(nameMap.seat(event.seat)) + " notes: " +
            nameMap.text(event.text)) + "</div>";
      }
    }
    element.innerHTML = html;

    if (live || limit >= events.length) {
      element.scrollTop = element.scrollHeight;
      return;
    }
    // Keep the playhead's neighbourhood in view while scrubbing.
    var lines = element.querySelectorAll(".feed-line");
    var target = null;
    for (var l = 0; l < lines.length; l++) {
      if (!lines[l].classList.contains("feed-future")) target = lines[l];
    }
    if (target && element.dataset.anchor !== String(limit)) {
      element.dataset.anchor = String(limit);
      element.scrollTo({
        top: Math.max(target.offsetTop - element.offsetTop -
          element.clientHeight * 0.6, 0)
      });
    }
  }

  function escapeHtml(text) {
    return text.replace(/[&<>"]/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c];
    });
  }

  // ---- Animation bookkeeping ----------------------------------------------

  // Turns a monotonically-growing event list into transient view effects:
  // per pair, when its message landed (the ribbon slides in from it) and
  // when its pick landed (the verdict flash fades from it).
  function makeEffects() {
    var seen = 0;
    var speakAt = [null, null];
    var pickAt = [null, null];
    return {
      // `quiet` (a scrub jump): the whole prefix lands at once, so only
      // the newest events get to animate — replaying every historical
      // verdict as a fresh flash would strobe the table.
      absorb: function (events, quiet) {
        var now = Date.now();
        for (; seen < events.length; seen++) {
          var event = events[seen];
          var animate = !quiet || seen >= events.length - 1;
          if (event.kind === "round") {
            speakAt = [null, null];
            pickAt = [null, null];
          } else if (event.kind === "speak") {
            speakAt[event.pair] = animate ? now : null;
          } else if (event.kind === "pick") {
            pickAt[event.pair] = animate ? now : null;
          }
        }
      },
      reset: function () {
        seen = 0; speakAt = [null, null]; pickAt = [null, null];
      },
      view: function () {
        return { effects: { speakAt: speakAt.slice(), pickAt: pickAt.slice() } };
      }
    };
  }

  // ---- Scorebug, header, endscreen ----------------------------------------

  function phaseText(state, nameMap) {
    var m = /^(speak|pick)([01])$/.exec(state.phase || "");
    var pairs = state.pairs || [];
    if (!m || !pairs[Number(m[2])]) return "";
    var pair = pairs[Number(m[2])];
    var seat = m[1] === "speak" ? pair.speaker : pair.listener;
    var who = nameMap ? nameMap.seat(seat) :
      (state.seats && state.seats[seat] || {}).name || ("Seat " + seat);
    return clampName(who).toUpperCase() +
      (m[1] === "speak" ? " SPEAKS" : " LISTENS");
  }

  function matchHeader(state, config, nameMap) {
    var parts = [];
    if (state) {
      var played = state.roundsPlayed || 0;
      var inRound = /^(speak|pick)[01]$/.test(state.phase || "");
      var total = state.rounds || (config && config.rounds) || 0;
      parts.push("ROUND " + (played + (inRound ? 1 : 0)) +
        (total ? " / " + total : ""));
      if (state.gameDone || state.done) {
        parts.push("FINAL");
      } else {
        var phase = phaseText(state, nameMap);
        if (phase) parts.push(phase);
      }
    }
    return parts.join(" · ");
  }

  function updateScorebug(container, state, nameMap) {
    if (!container || !state || !state.seats) return;
    var pending = pendingSeat(state.phase, state.pairs || []);
    var html = "";
    state.seats.forEach(function (seat, index) {
      var pips = "";
      for (var p = 0; p < Math.min(seat.asSpeaker || 0, 12); p++) {
        pips += '<span class="plate-pip"></span>';
      }
      for (var q = 0; q < Math.min(seat.asListener || 0, 12); q++) {
        pips += '<span class="plate-pip hollow"></span>';
      }
      var plateName = nameMap ? nameMap.seat(index) : seat.name;
      html += '<div class="plate ' + seatColor(index) + '">' +
        '<span class="plate-name">' + escapeHtml(clampName(plateName)) +
        "</span>" +
        (pending === index && !state.gameDone ?
          '<span class="plate-it">▶</span>' : "") +
        '<span class="plate-score">' + (seat.correct || 0) + "</span>" +
        '<span class="plate-label">correct</span>' +
        '<span class="plate-pips">' + pips + "</span>" +
        "</div>";
    });
    if (container.dataset.html !== html) {
      container.dataset.html = html;
      container.innerHTML = html;
    }
  }

  function reasonLine(results) {
    switch (results.reason) {
      case "deadline":
        return "episode deadline: scored on " + (results.rounds || 0) +
          " of " + (results.maxRounds || results.rounds || 0) + " rounds";
      default: return "";
    }
  }

  // Final standings overlay: verdict up top, ranked rows below.
  function updateEndscreen(container, results, show, nameMap) {
    if (!container) return;
    container.classList.toggle("show", !!show);
    if (!show || !results || container.dataset.built === "yes") return;
    container.dataset.built = "yes";
    var names = (results.names || []).map(function (name, i) {
      return nameMap ? nameMap.seat(i) : name;
    });
    var scores = results.scores || [];
    var correct = results.correct || [];
    var order = names.map(function (_, i) { return i; });
    order.sort(function (a, b) {
      var byScore = (scores[b] || 0) - (scores[a] || 0);
      if (byScore) return byScore;
      return (correct[b] || 0) - (correct[a] || 0);
    });
    var topIndex = order.length ? order[0] : -1;
    var level = order.every(function (i) {
      return (scores[i] || 0) === (scores[topIndex] || 0);
    });
    var verdictColor = !level && topIndex >= 0 ? seatColor(topIndex) : "";
    var verdict = !level && topIndex >= 0 ?
      escapeHtml(names[topIndex]) + " LEADS THE TABLE" : "ALL LEVEL";
    var reason = reasonLine(results);
    var html = '<div class="end-panel">' +
      '<div class="end-title">FINAL — ' + (results.rounds || 0) + " ROUND" +
      ((results.rounds || 0) === 1 ? "" : "S") + "</div>" +
      '<div class="end-verdict ' + verdictColor + '">' + verdict + "</div>" +
      (reason ? '<div class="end-reason">' + escapeHtml(reason) + "</div>" :
        "") +
      '<div class="end-rows">' +
      '<span class="end-head"></span><span class="end-head"></span>' +
      '<span class="end-head">score</span>' +
      '<span class="end-head">correct</span>' +
      '<span class="end-head">as speaker</span>' +
      '<span class="end-head">as listener</span>';
    order.forEach(function (i, rank) {
      var leader = !level && i === topIndex;
      var cell = function (value) {
        return '<span class="end-cell' + (leader ? " end-row-winner" : "") +
          '">' + value + "</span>";
      };
      html += '<span class="end-cell rank' +
        (leader ? " end-row-winner" : "") + '">' + (rank + 1) + "</span>" +
        '<span class="end-cell name ' + seatColor(i) +
        (leader ? " end-row-winner" : "") + '">' + escapeHtml(names[i]) +
        "</span>" +
        cell((scores[i] || 0).toFixed(2)) +
        cell(correct[i] || 0) +
        cell((results.asSpeaker || [])[i] || 0) +
        cell((results.asListener || [])[i] || 0);
    });
    html += "</div></div>";
    container.innerHTML = html;
  }

  function bindFeedToggle(button, startCollapsed) {
    if (!button) return;
    if (startCollapsed) {
      document.body.classList.add("feed-collapsed");
      requestAnimationFrame(function () {
        window.dispatchEvent(new Event("resize"));
      });
    }
    function refresh() {
      button.textContent =
        document.body.classList.contains("feed-collapsed") ?
          "« LOG" : "LOG »";
    }
    button.onclick = function () {
      document.body.classList.toggle("feed-collapsed");
      refresh();
      window.dispatchEvent(new Event("resize"));
    };
    refresh();
  }

  // ---- Drivers -------------------------------------------------------------

  function stateToView(state, nameMap, effects, extras) {
    var view = effects.view();
    view.seats = applyNames(state.seats, nameMap);
    view.pairs = state.pairs || [];
    view.glyphs = state.glyphs || [];
    view.phase = state.phase || "";
    view.roundsPlayed = state.roundsPlayed || 0;
    view.rounds = state.rounds || 0;
    view.now = Date.now();
    Object.assign(view, extras || {});
    return view;
  }

  function attachLive(options) {
    // options: {canvas, feed, status, clock, scorebug, endscreen,
    //           assetBase, wsPath, onFrame}
    makeRenderer(options.canvas, options.assetBase, function (renderer) {
      var latest = null;
      var slot = -1;
      // Player pages get no policyNames (they must not learn who is
      // behind a seat) and a redacted state (no pairs, no glyphs), so
      // their map degrades to the table aliases and empty booths.
      var nameMap = makeNameMap([], null, []);
      var effects = makeEffects();
      var scheme = location.protocol === "https:" ? "wss://" : "ws://";
      var url = scheme + location.host + options.wsPath;

      function setStatus(text, live) {
        if (!options.status) return;
        options.status.textContent = text;
        options.status.classList.toggle("live", !!live);
      }

      function connect() {
        var socket = new WebSocket(url);
        socket.onmessage = function (frame) {
          var data = JSON.parse(frame.data);
          if (data.type === "state" || data.type === "final") {
            if (data.type === "state") latest = data;
            if (latest) {
              if (typeof latest.slot === "number") slot = latest.slot;
              nameMap = makeNameMap(seatNames(latest), latest.policyNames,
                latest.glyphs);
              effects.absorb(latest.events || []);
              if (options.feed) {
                renderFeed(options.feed, latest.events || [], nameMap,
                  undefined);
              }
              if (options.clock) {
                options.clock.textContent =
                  matchHeader(latest, latest, nameMap);
              }
              updateScorebug(options.scorebug, latest, nameMap);
            }
            if (data.type === "final") {
              updateEndscreen(options.endscreen, data, true, nameMap);
            }
            if (latest && (latest.done || latest.gameDone)) {
              setStatus("final", false);
            }
          }
          if (options.onFrame) options.onFrame(data);
        };
        socket.onclose = function () {
          setStatus("disconnected", false);
          setTimeout(connect, 2000);
        };
        socket.onopen = function () {
          setStatus("live", true);
        };
      }
      connect();

      function seatNames(data) {
        return (data.seats || []).map(function (s) { return s.name; });
      }

      (function frame() {
        if (latest) {
          var view = stateToView(latest, nameMap, effects, {
            done: !!(latest.done || latest.gameDone)
          });
          if (slot >= 0 && view.seats[slot]) view.seats[slot].own = true;
          renderer.draw(view);
        }
        requestAnimationFrame(frame);
      })();
    });
  }

  // Scrubber: a click/drag-to-seek track with one span per round, a marker
  // per pick (coloured by the listener on success, a neutral ghost on
  // failure) and the end (taller).
  function buildScrub(container, events, onSeek) {
    container.innerHTML = "";
    var track = document.createElement("div");
    track.className = "scrub-track";
    container.appendChild(track);
    var fill = document.createElement("div");
    fill.className = "scrub-fill";
    container.appendChild(fill);
    var base = roundBase(events);
    var blockStarts = [];
    var lastBlock = null;
    events.forEach(function (event, i) {
      var block = event.kind === "start" ? -1 :
        event.kind === "end" ? lastBlock : event.round - base;
      if (block !== lastBlock) {
        blockStarts.push(i);
        lastBlock = block;
      }
    });
    blockStarts.forEach(function (startIdx, r) {
      var endIdx = r + 1 < blockStarts.length ?
        blockStarts[r + 1] : events.length;
      var span = document.createElement("div");
      span.className = "round-span" + (r % 2 ? " alt" : "");
      span.style.left = (startIdx / events.length * 100) + "%";
      span.style.width = ((endIdx - startIdx) / events.length * 100) + "%";
      container.appendChild(span);
      if (r > 0) {
        var sep = document.createElement("div");
        sep.className = "round-sep";
        sep.style.left = (startIdx / events.length * 100) + "%";
        container.appendChild(sep);
      }
    });
    events.forEach(function (event, i) {
      var kind = event.kind;
      if (kind !== "pick" && kind !== "end") return;
      var marker = document.createElement("div");
      marker.className = "beat-marker" +
        (kind === "pick" && event.correct ?
          " seat" + (event.seat % COLORS.length) : "") +
        (kind === "end" ? " death" : "");
      marker.style.left = ((i + 1) / events.length * 100) + "%";
      container.appendChild(marker);
    });
    var head = document.createElement("div");
    head.className = "scrub-head";
    container.appendChild(head);

    function seekFromEvent(evt) {
      var rect = container.getBoundingClientRect();
      if (!rect.width) return;   // hidden/unlaid-out page: nothing to seek
      var x = (evt.touches ? evt.touches[0].clientX : evt.clientX) -
        rect.left;
      var fraction = Math.max(0, Math.min(x / rect.width, 1));
      onSeek(Math.round(fraction * events.length));
    }
    var dragging = false;
    container.addEventListener("pointerdown", function (evt) {
      dragging = true;
      try { container.setPointerCapture(evt.pointerId); } catch (ignore) {}
      seekFromEvent(evt);
    });
    container.addEventListener("pointermove", function (evt) {
      if (dragging) seekFromEvent(evt);
    });
    container.addEventListener("pointerup", function () {
      dragging = false;
    });

    return {
      update: function (index) {
        var pct = events.length ? (index / events.length * 100) : 0;
        fill.style.width = pct + "%";
        head.style.left = pct + "%";
      }
    };
  }

  function attachReplay(options) {
    // options: {canvas, feed, scrub, playButton, label, clock, scorebug,
    //           endscreen, assetBase, payload}
    var payload = options.payload;
    var events = payload.events || [];
    var states = payload.states || [];
    var config = payload.config || {};
    var nameMap = makeNameMap(payload.names, payload.policyNames,
      config.glyphs);
    var index = 0;
    var playing = true;
    var lastStep = 0;
    var speed = 1;   // playback rate; the per-event dwell is stepMs / speed

    makeRenderer(options.canvas, options.assetBase, function (renderer) {
      var effects = makeEffects();
      var scrub = buildScrub(options.scrub, events, function (next) {
        playing = false;
        setIndex(next, true);
      });
      function togglePlay() {
        playing = !playing;
        if (playing && index >= events.length) setIndex(0, true);
      }
      if (options.playButton) {
        options.playButton.onclick = togglePlay;
        // Speed chips ride in the transport bar next to the play button.
        var chips = [];
        var row = document.createElement("span");
        row.className = "tspeed";
        [0.5, 1, 2].forEach(function (rate) {
          var chip = document.createElement("button");
          chip.type = "button";
          chip.className = "tchip" + (rate === speed ? " on" : "");
          chip.textContent = rate + "×";
          chip.onclick = function () {
            speed = rate;
            chips.forEach(function (c) {
              c.classList.toggle("on", c === chip);
            });
          };
          chips.push(chip);
          row.appendChild(chip);
        });
        options.playButton.parentNode.insertBefore(
          row, options.playButton.nextSibling);
      }
      // Space pauses/resumes, exactly like the play button — but never
      // while the viewer is typing somewhere.
      document.addEventListener("keydown", function (evt) {
        if (evt.code !== "Space" && evt.key !== " ") return;
        var t = evt.target;
        if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" ||
            t.tagName === "SELECT" || t.isContentEditable)) {
          return;
        }
        evt.preventDefault();   // no page scroll, no double button fire
        togglePlay();
      });

      function currentState() {
        var state = states[Math.min(index, states.length - 1)] ||
          { seats: [], pairs: [], phase: "", roundsPlayed: 0 };
        // The alphabet is per episode; frames may omit it, the config
        // never does.
        if (!state.glyphs && config.glyphs) {
          state = Object.assign({}, state, { glyphs: config.glyphs });
        }
        return state;
      }

      function setIndex(next, jumped) {
        index = Math.max(0, Math.min(next, events.length));
        scrub.update(index);
        if (jumped) {
          effects.reset();
        }
        effects.absorb(events.slice(0, index), jumped);
        if (options.feed) renderFeed(options.feed, events, nameMap, index);
        if (options.label) {
          options.label.textContent = index + " / " + events.length;
        }
        if (options.clock) {
          options.clock.textContent =
            matchHeader(currentState(), config, nameMap);
        }
        updateScorebug(options.scorebug, currentState(), nameMap);
        updateEndscreen(options.endscreen, payload.results,
          index >= events.length && events.length > 0, nameMap);
      }
      setIndex(0, true);

      (function frame(timestamp) {
        // Dwell on what the viewer is currently looking at — the event
        // just absorbed — so the message gets read and the verdict gets
        // seen before the next beat.
        var shown = index > 0 ? events[index - 1] : null;
        var stepMs = shown && shown.kind === "speak" ? 1600 :
          shown && shown.kind === "pick" ? 2000 :
          shown && shown.kind === "round" ? 800 :
          shown && shown.kind === "end" ? 1500 :
          600;
        if (playing && index < events.length &&
            timestamp - lastStep > stepMs / speed) {
          lastStep = timestamp;
          setIndex(index + 1, false);
        }
        if (options.playButton) {
          var running = playing && index < events.length;
          options.playButton.textContent = running ? "❚❚" : "▶";
          options.playButton.classList.toggle("on", running);
        }
        var view = stateToView(currentState(), nameMap, effects, {
          done: index >= events.length && events.length > 0
        });
        renderer.draw(view);
        requestAnimationFrame(frame);
      })(0);

      document.documentElement.setAttribute("data-replay-loaded", "true");
    });
  }

  window.BabelRenderer = {
    attachLive: attachLive,
    attachReplay: attachReplay,
    renderFeed: renderFeed,
    bindFeedToggle: bindFeedToggle
  };
})();
