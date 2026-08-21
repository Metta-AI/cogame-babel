// Focus shared renderer + drivers.
//
// One canvas scene (the 52-square Focus board, stacked discs, two cogs with
// their reserve/captured tallies, speech bubbles) fed by three drivers:
// live /global websocket, live /player websocket, and replay (from the
// game's /replay websocket or the static wasm bundle). All state derivation
// happens server-side / wasm-side; this file only draws state objects:
//   {seats:[{name,reserve,captured,material,stacks,acting}, {…}],
//    board:[[owners bottom→top] × 64], turn, ply, first, gameDone, winner,
//    reason, lastMove:{kind,seat,from,to,count}|null}
(function () {
  "use strict";

  // Ink & Print palette, matching the coworld-ctf broadcast chrome. Focus
  // is a two-player game: seat 0 is red, seat 1 is blue. The extra colours
  // stay so the chrome's seatN classes keep lining up with the CSS.
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
  var SQUARE_A = "#3a4a3f";
  var SQUARE_B = "#2d3b32";
  var SQUARE_EDGE = "rgba(242, 232, 216, 0.14)";
  var BUBBLE_MS = 5200;
  // The last-move arrow / drop ring holds for a beat, then fades out.
  var LAST_MOVE_HOLD_MS = 2500;
  var LAST_MOVE_FADE_MS = 700;

  var FILES = "abcdefgh";
  var DIRS = { N: "N", S: "S", E: "E", W: "W" };

  // The three squares in every corner are not part of the board.
  function playable(cell) {
    var f = cell & 7;
    var r = cell >> 3;
    var edgeF = f === 0 || f === 7;
    var edgeR = r === 0 || r === 7;
    if (edgeF && edgeR) return false;
    if (edgeF && (r === 1 || r === 6)) return false;
    if (edgeR && (f === 1 || f === 6)) return false;
    return true;
  }

  function cellName(cell) {
    if (typeof cell !== "number" || cell < 0 || cell > 63) return "?";
    return FILES[cell & 7] + ((cell >> 3) + 1);
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

  // Colour helpers for the disc rims / highlights.
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

  // Nominal cog size; everything around a cog is measured as a multiple of
  // it so the whole seat block scales as one unit.
  var SEAT_BASE = 84;
  var BUBBLE_MAX_W = 220, BUBBLE_LINES = 4, BUBBLE_LINE_H = 16;
  var BUBBLE_PAD = 8, BUBBLE_TAIL = 8, BUBBLE_RISE = 0.69;
  var LABEL_GUTTER = 22;

  function bubbleHeight(lines) {
    return lines * BUBBLE_LINE_H + BUBBLE_PAD * 2 - 4;
  }

  function seatBlock(size) {
    // The seat block: cog, name, RESERVE / TAKEN / MATERIAL rows below it,
    // and speech-bubble headroom above. Bubble headroom is reserved at its
    // WORST case (four lines) even while nobody is talking: bubbles are
    // transient and arrive without warning.
    var scale = size / SEAT_BASE;
    return {
      w: size * 1.9,
      above: size * BUBBLE_RISE + bubbleHeight(BUBBLE_LINES) * scale,
      cogHalf: size / 2,
      below: size * 0.62 + 72 * scale
    };
  }

  function computeLayout(width, height) {
    // The board is a square grid centred in whatever is left after the two
    // seat blocks: beside it when the canvas is wide, above/below it when
    // it is narrow. Callers embed this viewer at wildly different sizes,
    // so the fit is solved per frame rather than assumed.
    var margin = 10;
    var size = Math.min(SEAT_BASE, width / 4, height / 4);
    var layout = null;
    for (var attempt = 0; attempt < 40; attempt++) {
      var b = seatBlock(size);
      var scale = size / SEAT_BASE;
      var gutter = LABEL_GUTTER * Math.max(scale, 0.6);
      // Horizontal: seats left and right of the board.
      var hAvailW = width - 2 * margin - 2 * b.w - gutter;
      var hAvailH = height - 2 * margin - gutter;
      var sqH = Math.min(hAvailW, hAvailH);
      // Vertical: seat 1 above the board, seat 0 below.
      var vAvailW = width - 2 * margin - gutter;
      var vAvailH = height - 2 * margin - gutter -
        (b.above + b.below) - (b.cogHalf + b.below);
      var sqV = Math.min(vAvailW, vAvailH);
      var horizontal = sqH >= sqV;
      // Never negative: a not-yet-laid-out canvas still gets a valid frame.
      var sq = Math.max(horizontal ? sqH : sqV, 8);
      if (horizontal) {
        var bx = margin + b.w + gutter + Math.max(hAvailW - sq, 0) / 2;
        var by = margin + Math.max(hAvailH - sq, 0) / 2;
        var seatY = Math.min(Math.max(by + sq / 2 - 24 * scale,
          margin + b.above), height - margin - b.below);
        layout = {
          size: size, scale: scale, sq: sq, cs: sq / 8, bx: bx, by: by,
          gutter: gutter,
          seats: [
            { x: margin + b.w / 2, y: seatY },
            { x: width - margin - b.w / 2, y: seatY }
          ]
        };
      } else {
        var vbx = margin + gutter + Math.max(vAvailW - sq, 0) / 2;
        var topY = margin + b.above;
        var vby = topY + b.below + Math.max(vAvailH - sq, 0) / 2;
        layout = {
          size: size, scale: scale, sq: sq, cs: sq / 8, bx: vbx, by: vby,
          gutter: gutter,
          seats: [
            { x: width / 2, y: vby + sq + gutter + b.cogHalf },
            { x: width / 2, y: topY }
          ]
        };
      }
      if (sq >= Math.min(width, height) * 0.55 || size < 28) break;
      size *= 0.92;
    }
    return layout;
  }

  function cellRect(layout, cell) {
    var f = cell & 7;
    var r = cell >> 3;
    return {
      x: layout.bx + f * layout.cs,
      y: layout.by + (7 - r) * layout.cs,
      w: layout.cs,
      h: layout.cs
    };
  }

  function cellCenter(layout, cell) {
    var rect = cellRect(layout, cell);
    return { x: rect.x + rect.w / 2, y: rect.y + rect.h / 2 };
  }

  function draw(ctx, canvas, images, view) {
    var w = canvas.width;
    var h = canvas.height;
    var seats = view.seats || [];
    var now = view.now || Date.now();
    var layout = computeLayout(w, h);
    var cs = layout.cs;
    var scale = layout.scale;

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

    // The board: 52 playable squares; the corners stay transparent so the
    // octagon-ish outline reads.
    var board = view.board || [];
    var acting = view.turn;
    ctx.save();
    for (var cell = 0; cell < 64; cell++) {
      if (!playable(cell)) continue;
      var rect = cellRect(layout, cell);
      var f = cell & 7;
      var r = cell >> 3;
      ctx.fillStyle = ((f + r) & 1) ? SQUARE_A : SQUARE_B;
      ctx.fillRect(rect.x, rect.y, rect.w, rect.h);
      ctx.strokeStyle = SQUARE_EDGE;
      ctx.lineWidth = 1;
      ctx.strokeRect(rect.x + 0.5, rect.y + 0.5, rect.w - 1, rect.h - 1);
      if (view.showControl && acting >= 0) {
        var stack = board[cell] || [];
        if (stack.length && stack[stack.length - 1] === acting) {
          ctx.strokeStyle = AMBER;
          ctx.lineWidth = 2;
          ctx.strokeRect(rect.x + 2, rect.y + 2, rect.w - 4, rect.h - 4);
        }
      }
    }
    ctx.restore();

    // File letters under the bottom row, rank numbers left of the board.
    ctx.save();
    ctx.fillStyle = GHOST;
    ctx.font = "600 " + Math.round(Math.max(9, cs * 0.22)) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.textAlign = "center";
    ctx.textBaseline = "top";
    for (var file = 0; file < 8; file++) {
      ctx.fillText(FILES[file], layout.bx + file * cs + cs / 2,
        layout.by + layout.sq + 3 * scale);
    }
    ctx.textAlign = "right";
    ctx.textBaseline = "middle";
    for (var rank = 0; rank < 8; rank++) {
      ctx.fillText("" + (rank + 1), layout.bx - 4 * scale,
        layout.by + (7 - rank) * cs + cs / 2);
    }
    ctx.restore();

    // Stacks: discs bottom first, coloured by owner; the top disc gets the
    // highlight and a height numeral when there is more than one piece.
    for (var sc = 0; sc < 64; sc++) {
      var pieces = board[sc];
      if (!pieces || !pieces.length) continue;
      drawStack(ctx, layout, sc, pieces);
    }

    // Last move: an arrow for a slide, a dashed ring for a drop.
    var lastMove = view.lastMove;
    if (lastMove && typeof view.lastMoveAt === "number") {
      var age = now - view.lastMoveAt;
      var alpha = age < LAST_MOVE_HOLD_MS ? 1 :
        Math.max(0, 1 - (age - LAST_MOVE_HOLD_MS) / LAST_MOVE_FADE_MS);
      if (alpha > 0) drawLastMove(ctx, layout, lastMove, alpha * 0.9);
    }

    // Seats: cog, halo, name and tallies.
    seats.forEach(function (seat, index) {
      if (index >= layout.seats.length) return;
      var pos = layout.seats[index];
      var color = seatColor(index);
      var sprite = images["soldier_" + color + "_front.png"];
      var size = layout.size;
      var loser = view.done && view.winner >= 0 && view.winner !== index;

      ctx.save();
      ctx.translate(pos.x, pos.y);
      if (loser) ctx.globalAlpha = 0.4;
      if (sprite && sprite.width) {
        ctx.imageSmoothingEnabled = false;
        ctx.drawImage(sprite, -size / 2, -size / 2, size, size);
      } else {
        ctx.fillStyle = COLOR_HEX[color];
        ctx.fillRect(-size / 3, -size / 3, size / 1.5, size / 1.5);
      }
      ctx.restore();

      // Acting halo.
      if (seat.acting && !view.done) {
        ctx.save();
        ctx.strokeStyle = AMBER;
        ctx.lineWidth = 3;
        ctx.setLineDash([6, 5]);
        ctx.beginPath();
        ctx.arc(pos.x, pos.y, size * 0.62, 0, Math.PI * 2);
        ctx.stroke();
        ctx.restore();
      }

      // Verdict tag over the cog once the game is decided.
      if (view.done) {
        var tag = view.winner < 0 ? "DRAW" :
          view.winner === index ? "WINNER" : null;
        if (tag) {
          drawTag(ctx, pos.x, pos.y - size * 0.42, tag, COLOR_HEX[color],
            scale);
        }
      }

      // Name.
      ctx.save();
      ctx.font = "600 " + Math.round(13 * scale) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.textAlign = "center";
      ctx.textBaseline = "alphabetic";
      ctx.fillStyle = loser ? GHOST : PAPER;
      ctx.shadowColor = "rgba(0,0,0,0.8)";
      ctx.shadowBlur = 4;
      ctx.fillText(ellipsize(ctx, seat.name, size * 1.6), pos.x,
        pos.y + size * 0.62 + 14 * scale);
      ctx.restore();

      // Tallies: RESERVE (own-colour discs), TAKEN (ghost discs), MATERIAL.
      var bw = size * 1.9;
      var left = pos.x - bw / 2 + 4 * scale;
      var right = pos.x + bw / 2 - 4 * scale;
      var rowY = pos.y + size * 0.62 + 30 * scale;
      drawTally(ctx, left, right, rowY, "RESERVE", seat.reserve || 0,
        COLOR_HEX[color], scale);
      drawTally(ctx, left, right, rowY + 16 * scale, "TAKEN",
        seat.captured || 0, GHOST, scale);
      ctx.save();
      ctx.font = "700 " + Math.round(10 * scale) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.textAlign = "left";
      ctx.textBaseline = "middle";
      ctx.fillStyle = GHOST;
      ctx.fillText("MATERIAL", left, rowY + 33 * scale);
      ctx.font = "700 " + Math.round(14 * scale) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.textAlign = "right";
      ctx.fillStyle = AMBER;
      ctx.shadowColor = "rgba(0,0,0,0.8)";
      ctx.shadowBlur = 3;
      ctx.fillText("" + (seat.material || 0), right, rowY + 33 * scale);
      ctx.restore();
    });

    // Speech bubbles (drawn last, on top).
    (view.bubbles || []).forEach(function (bubble) {
      var age = now - bubble.at;
      if (age > BUBBLE_MS) return;
      var pos = layout.seats[bubble.seat];
      if (!pos) return;
      var alpha = age > BUBBLE_MS - 600 ? (BUBBLE_MS - age) / 600 : 1;
      drawBubble(ctx, w, pos.x, pos.y - layout.size * BUBBLE_RISE,
        bubble.text, alpha, layout.scale);
    });
  }

  function drawTally(ctx, left, right, y, label, count, color, scale) {
    ctx.save();
    ctx.font = "700 " + Math.round(10 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.textAlign = "left";
    ctx.textBaseline = "middle";
    ctx.fillStyle = GHOST;
    ctx.fillText(label, left, y);
    var labelW = ctx.measureText("RESERVE").width;
    // Numeral pinned to the right edge; discs fill the room between.
    ctx.font = "700 " + Math.round(12 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.textAlign = "right";
    ctx.fillStyle = PAPER;
    ctx.shadowColor = "rgba(0,0,0,0.8)";
    ctx.shadowBlur = 3;
    ctx.fillText("" + count, right, y);
    ctx.shadowBlur = 0;
    var numW = ctx.measureText("00").width;
    var start = left + labelW + 8 * scale;
    var end = right - numW - 6 * scale;
    var shown = Math.min(count, 12);
    if (shown > 0 && end > start) {
      var radius = 3 * scale;
      var spacing = Math.min(8 * scale, (end - start) / 12);
      for (var i = 0; i < shown; i++) {
        ctx.beginPath();
        ctx.arc(start + radius + i * spacing, y, radius, 0, Math.PI * 2);
        ctx.fillStyle = color;
        ctx.fill();
        ctx.strokeStyle = "rgba(0,0,0,0.5)";
        ctx.lineWidth = 1;
        ctx.stroke();
      }
    }
    ctx.restore();
  }

  function drawStack(ctx, layout, cell, pieces) {
    var cs = layout.cs;
    var rect = cellRect(layout, cell);
    var rx = cs * 0.34;
    var ry = rx * 0.55;
    var lift = cs * 0.16;
    var cx = rect.x + cs / 2;
    // The bottom disc sits a touch below centre so a tall stack reads
    // centred in its square.
    var baseY = rect.y + cs / 2 + cs * 0.14;
    ctx.save();
    for (var i = 0; i < pieces.length; i++) {
      var owner = pieces[i];
      var color = COLOR_HEX[seatColor(owner)] || GHOST;
      var y = baseY - i * lift;
      // Side wall of the disc, then its face.
      ctx.beginPath();
      ctx.ellipse(cx, y + lift * 0.55, rx, ry, 0, 0, Math.PI * 2);
      ctx.fillStyle = shade(color, 0.55);
      ctx.fill();
      ctx.beginPath();
      ctx.ellipse(cx, y, rx, ry, 0, 0, Math.PI * 2);
      ctx.fillStyle = color;
      ctx.fill();
      ctx.strokeStyle = shade(color, 0.45);
      ctx.lineWidth = Math.max(1, cs * 0.025);
      ctx.stroke();
      if (i === pieces.length - 1) {
        // Highlight on the top disc.
        ctx.beginPath();
        ctx.ellipse(cx - rx * 0.25, y - ry * 0.3, rx * 0.5, ry * 0.4, 0, 0,
          Math.PI * 2);
        ctx.fillStyle = "rgba(242, 232, 216, 0.35)";
        ctx.fill();
      }
    }
    if (pieces.length >= 2) {
      ctx.font = "700 " + Math.round(cs * 0.28) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.textAlign = "right";
      ctx.textBaseline = "top";
      ctx.fillStyle = PAPER;
      ctx.shadowColor = INK;
      ctx.shadowBlur = 0;
      ctx.shadowOffsetX = 1;
      ctx.shadowOffsetY = 1;
      ctx.fillText("" + pieces.length, rect.x + cs - 3, rect.y + 2);
    }
    ctx.restore();
  }

  function drawLastMove(ctx, layout, move, alpha) {
    var cs = layout.cs;
    ctx.save();
    ctx.globalAlpha = alpha;
    ctx.strokeStyle = AMBER;
    ctx.fillStyle = AMBER;
    if (move.kind === "move" && move.from >= 0 && move.to >= 0) {
      var a = cellCenter(layout, move.from);
      var b = cellCenter(layout, move.to);
      var dx = b.x - a.x;
      var dy = b.y - a.y;
      var len = Math.sqrt(dx * dx + dy * dy) || 1;
      var ux = dx / len;
      var uy = dy / len;
      var startX = a.x + ux * cs * 0.25;
      var startY = a.y + uy * cs * 0.25;
      var head = cs * 0.32;
      var endX = b.x - ux * cs * 0.3;
      var endY = b.y - uy * cs * 0.3;
      var shaftX = endX - ux * head * 0.8;
      var shaftY = endY - uy * head * 0.8;
      ctx.lineWidth = Math.max(3, cs * 0.12);
      ctx.lineCap = "round";
      ctx.beginPath();
      ctx.moveTo(startX, startY);
      ctx.lineTo(shaftX, shaftY);
      ctx.stroke();
      ctx.beginPath();
      ctx.moveTo(endX, endY);
      ctx.lineTo(endX - ux * head - uy * head * 0.55,
        endY - uy * head + ux * head * 0.55);
      ctx.lineTo(endX - ux * head + uy * head * 0.55,
        endY - uy * head - ux * head * 0.55);
      ctx.closePath();
      ctx.fill();
    } else if (move.to >= 0) {
      var c = cellCenter(layout, move.to);
      var rect = cellRect(layout, move.to);
      ctx.lineWidth = Math.max(2, cs * 0.06);
      ctx.setLineDash([cs * 0.12, cs * 0.09]);
      ctx.beginPath();
      ctx.arc(c.x, c.y, cs * 0.42, 0, Math.PI * 2);
      ctx.stroke();
      ctx.setLineDash([]);
      ctx.font = "700 " + Math.round(cs * 0.26) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.textAlign = "left";
      ctx.textBaseline = "top";
      ctx.shadowColor = INK;
      ctx.shadowOffsetX = 1;
      ctx.shadowOffsetY = 1;
      ctx.fillText("+1", rect.x + 3, rect.y + 2);
    }
    ctx.restore();
  }

  // A small tag ("WINNER") in the seat's colour, pinned over the cog.
  function drawTag(ctx, x, y, text, accent, scale) {
    ctx.save();
    ctx.font = "700 " + Math.round(11 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    var label = text.toUpperCase();
    var pad = 6 * scale;
    var bw = ctx.measureText(label).width + pad * 2;
    var bh = 17 * scale;
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

  function drawBubble(ctx, canvasWidth, x, y, text, alpha, scale) {
    var s = scale || 1;
    ctx.save();
    ctx.globalAlpha = alpha;
    ctx.font = Math.round(13 * s) + "px 'rajdhani', system-ui, sans-serif";
    var maxWidth = BUBBLE_MAX_W * s;
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
    var overflow = lines.length > BUBBLE_LINES;
    lines = lines.slice(0, BUBBLE_LINES);
    if (overflow && lines.length) {
      lines[lines.length - 1] += "…";
    }
    var widest = 0;
    lines.forEach(function (l) {
      widest = Math.max(widest, ctx.measureText(l).width);
    });
    var pad = BUBBLE_PAD * s;
    var lineH = BUBBLE_LINE_H * s;
    var bw = widest + pad * 2;
    var bh = lines.length * lineH + pad * 2 - 4 * s;
    var bx = Math.max(6, Math.min(x - bw / 2, canvasWidth - bw - 6));
    var by = y - bh;

    ctx.fillStyle = "rgba(242, 232, 216, 0.96)";
    ctx.strokeStyle = "rgba(42, 31, 22, 0.9)";
    ctx.lineWidth = 1.5;
    roundRect(ctx, bx, by, bw, bh, 8 * s);
    ctx.fill();
    ctx.stroke();
    ctx.beginPath();
    ctx.moveTo(x - 6 * s, by + bh);
    ctx.lineTo(x + 6 * s, by + bh);
    ctx.lineTo(x, by + bh + BUBBLE_TAIL * s);
    ctx.closePath();
    ctx.fill();

    ctx.fillStyle = INK;
    lines.forEach(function (l, i) {
      ctx.fillText(l, bx + pad, by + pad + 11 * s + i * lineH);
    });
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

  // The agents only ever hear anonymous board names ("Tinker", "Gasket");
  // the payload carries the policy names separately, spectator-side only.
  // A name map swaps them in wherever a name is RENDERED while the
  // underlying events keep the aliases. Baseline fillers keep their alias.
  function isBaselineFiller(name) {
    return /^baseline(\s*\(\d+\))?$/i.test(name);
  }

  function makeNameMap(tableNames, policyNames) {
    var table = tableNames || [];
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

  function renameBubbles(bubbles, nameMap) {
    return (bubbles || []).map(function (bubble) {
      return { seat: bubble.seat, text: nameMap.text(bubble.text),
        at: bubble.at };
    });
  }

  function clampName(name) {
    var n = name || "";
    return n.length > 24 ? n.slice(0, 23) + "…" : n;
  }

  // ---- Event feed ----------------------------------------------------------

  function shedSuffix(event) {
    var parts = [];
    if (event.captured > 0) parts.push("captures " + event.captured);
    if (event.reserved > 0) {
      parts.push("banks " + event.reserved + " to reserve");
    }
    return parts.length ? " — " + parts.join(", ") : "";
  }

  function describeEvent(event, nameMap) {
    function name(i) {
      return clampName(nameMap.seat(i));
    }
    switch (event.kind) {
      case "start":
        return "Pieces set — " + name(event.seat) + " moves first.";
      case "say":
        return name(event.seat) + ": “" + nameMap.text(event.text) + "”";
      case "move":
        var stack = event.stack || [];
        var height = stack.length;
        var landed = "";
        if (height > event.count) {
          // The old top of the destination is just under the carried pieces
          // (shedding only ever removes from the bottom).
          var oldTop = stack[height - 1 - event.count];
          landed = oldTop === event.seat ?
            " (grows a stack of " + height + ")" :
            " (takes control of a stack of " + height + ")";
        }
        return name(event.seat) + ": " + cellName(event.from) + " ×" +
          event.count + " " + (DIRS[event.dir] || event.dir || "") + " → " +
          cellName(event.to) + landed + shedSuffix(event) + ".";
      case "place":
        var placed = event.stack || [];
        return name(event.seat) + " drops a reserve piece on " +
          cellName(event.to) +
          (placed.length > 1 ? " (now a stack of " + placed.length + ")" :
            "") + shedSuffix(event) + ".";
      case "end":
        return endText(event.seat, event.text, name);
      default: return JSON.stringify(event);
    }
  }

  function endText(winner, reason, name) {
    var loser = winner >= 0 ? 1 - winner : -1;
    if (reason === "no-moves" && winner >= 0) {
      return name(winner) + " wins — " + name(loser) + " cannot move.";
    }
    if (winner < 0) {
      return (reason === "deadline" ? "Episode deadline — " :
        "Ply cap reached — ") + "draw on material.";
    }
    return (reason === "deadline" ? "Episode deadline — " :
      reason === "cap" ? "Ply cap reached — " : "") +
      name(winner) + " wins on material.";
  }

  function plyBlock(event) {
    return Math.floor((event.ply || 0) / 10);
  }

  function blockHead(block) {
    return "PLIES " + (block * 10 + 1) + "–" + (block * 10 + 10);
  }

  // Renders the full transcript grouped into one section per ten plies.
  // currentIndex (replay) marks how far playback has reached; omit it for
  // live views.
  function renderFeed(element, events, nameMap, currentIndex) {
    var live = currentIndex === undefined;
    var limit = live ? events.length : currentIndex;
    var html = "";
    var lastBlock = null;
    for (var i = 0; i < events.length; i++) {
      var event = events[i];
      var block = plyBlock(event);
      if (block !== lastBlock) {
        html += '<div class="feed-round-head">' + blockHead(block) +
          "</div>";
        lastBlock = block;
      }
      var took = (event.kind === "move" || event.kind === "place") &&
        event.captured > 0;
      var cls = "feed-line feed-" + event.kind +
        (event.kind === "end" ? " feed-rwin" : "") +
        (took ? " feed-score seat" + (event.seat % COLORS.length) : "") +
        (i >= limit ? " feed-future" : "");
      html += '<div class="' + cls + '">' +
        escapeHtml(describeEvent(event, nameMap)) + "</div>";
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
  // speech bubbles, and the timestamp of the newest move (the arrow fades
  // from it).
  function makeEffects() {
    var seen = 0;
    var bubbles = [];
    var lastMoveAt = null;
    return {
      // `quiet` (a scrub jump): the whole prefix lands at once, so only
      // the newest events get to animate — replaying every historical
      // shout as a fresh bubble would paper the board.
      absorb: function (events, quiet) {
        var now = Date.now();
        for (; seen < events.length; seen++) {
          var event = events[seen];
          var animate = !quiet || seen >= events.length - 2;
          if (event.kind === "move" || event.kind === "place") {
            lastMoveAt = now;
          } else if (event.kind === "say") {
            if (!animate) continue;
            bubbles = bubbles.filter(function (b) {
              return b.seat !== event.seat;
            });
            bubbles.push({ seat: event.seat, text: event.text, at: now });
          }
        }
        var cutoff = now - BUBBLE_MS;
        bubbles = bubbles.filter(function (b) { return b.at > cutoff; });
      },
      reset: function () {
        seen = 0; bubbles = []; lastMoveAt = null;
      },
      view: function () {
        return { bubbles: bubbles, lastMoveAt: lastMoveAt };
      }
    };
  }

  // ---- Scorebug, header, endscreen ----------------------------------------

  function matchHeader(state, config, nameMap) {
    var parts = [];
    if (state) {
      parts.push("PLY " + (state.ply || 0) +
        (config && config.maxPlies ? " / " + config.maxPlies : ""));
      if (state.gameDone) {
        parts.push("FINAL");
      } else if (typeof state.turn === "number" && state.turn >= 0) {
        var mover = nameMap ? nameMap.seat(state.turn) :
          (state.seats && state.seats[state.turn] || {}).name ||
          ("Seat " + state.turn);
        parts.push(clampName(mover).toUpperCase() + " TO MOVE");
      }
    }
    return parts.join(" · ");
  }

  function updateScorebug(container, state, nameMap) {
    if (!container || !state || !state.seats) return;
    var html = "";
    state.seats.forEach(function (seat, index) {
      var pips = "";
      for (var p = 0; p < Math.min(seat.captured || 0, 12); p++) {
        pips += '<span class="plate-pip"></span>';
      }
      var plateName = nameMap ? nameMap.seat(index) : seat.name;
      html += '<div class="plate ' + seatColor(index) + '">' +
        '<span class="plate-name">' + escapeHtml(clampName(plateName)) +
        "</span>" +
        (seat.acting && !state.gameDone ?
          '<span class="plate-it">▶</span>' : "") +
        '<span class="plate-score">' + (seat.material || 0) + "</span>" +
        '<span class="plate-label">material</span>' +
        '<span class="plate-pips">' + pips + "</span>" +
        "</div>";
    });
    if (container.dataset.html !== html) {
      container.dataset.html = html;
      container.innerHTML = html;
    }
  }

  function reasonLine(results) {
    var winner = results.win ? results.win.indexOf(true) : -1;
    switch (results.reason) {
      case "no-moves": return "opponent could not move";
      case "cap":
        return winner >= 0 ? "ply cap: won on material" :
          "ply cap: level on material";
      case "deadline":
        return winner >= 0 ? "episode deadline: won on material" :
          "episode deadline: level on material";
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
    var order = names.map(function (_, i) { return i; });
    order.sort(function (a, b) {
      var byScore = ((results.scores || [])[b] || 0) -
        ((results.scores || [])[a] || 0);
      if (byScore) return byScore;
      return ((results.material || [])[b] || 0) -
        ((results.material || [])[a] || 0);
    });
    var winnerIndex = results.win ? results.win.indexOf(true) : -1;
    var verdictColor = winnerIndex >= 0 ? seatColor(winnerIndex) : "";
    var verdict = winnerIndex >= 0 ?
      escapeHtml(names[winnerIndex]) + " WINS" : "DRAW";
    var reason = reasonLine(results);
    var html = '<div class="end-panel">' +
      '<div class="end-title">FINAL — ' + (results.plies || 0) + " PL" +
      ((results.plies || 0) === 1 ? "Y" : "IES") + "</div>" +
      '<div class="end-verdict ' + verdictColor + '">' + verdict + "</div>" +
      (reason ? '<div class="end-reason">' + escapeHtml(reason) + "</div>" :
        "") +
      '<div class="end-rows">' +
      '<span class="end-head"></span><span class="end-head"></span>' +
      '<span class="end-head">material</span>' +
      '<span class="end-head">reserve</span>' +
      '<span class="end-head">captured</span>' +
      '<span class="end-head">score</span>';
    order.forEach(function (i, rank) {
      var winner = results.win && results.win[i];
      var cell = function (value) {
        return '<span class="end-cell' + (winner ? " end-row-winner" : "") +
          '">' + value + "</span>";
      };
      html += '<span class="end-cell rank' +
        (winner ? " end-row-winner" : "") + '">' + (rank + 1) + "</span>" +
        '<span class="end-cell name ' + seatColor(i) +
        (winner ? " end-row-winner" : "") + '">' + escapeHtml(names[i]) +
        "</span>" +
        cell((results.material || [])[i] || 0) +
        cell((results.reserve || [])[i] || 0) +
        cell((results.captured || [])[i] || 0) +
        cell(((results.scores || [])[i] || 0).toFixed(2));
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
    view.bubbles = renameBubbles(view.bubbles, nameMap);
    view.board = state.board || [];
    view.turn = typeof state.turn === "number" ? state.turn : -1;
    view.ply = state.ply;
    view.lastMove = state.lastMove || null;
    view.winner = typeof state.winner === "number" ? state.winner : -1;
    view.showControl = false;
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
      // behind a seat), so their map degrades to the board aliases.
      var nameMap = makeNameMap([], null);
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
              nameMap = makeNameMap(seatNames(latest), latest.policyNames);
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
            if (latest && latest.done) setStatus("final", false);
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

  // Scrubber: a click/drag-to-seek track with one span per ten plies, a
  // marker per capturing move (colored by the mover) and the end (taller).
  function buildScrub(container, events, onSeek) {
    container.innerHTML = "";
    var track = document.createElement("div");
    track.className = "scrub-track";
    container.appendChild(track);
    var fill = document.createElement("div");
    fill.className = "scrub-fill";
    container.appendChild(fill);
    var blockStarts = [];
    var lastBlock = null;
    events.forEach(function (event, i) {
      var block = plyBlock(event);
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
      var took = (kind === "move" || kind === "place") && event.captured > 0;
      if (!took && kind !== "end") return;
      var seat = kind === "end" ? Math.max(event.seat, 0) : event.seat;
      var marker = document.createElement("div");
      marker.className = "beat-marker seat" + (seat % COLORS.length) +
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
    var nameMap = makeNameMap(payload.names, payload.policyNames);
    var index = 0;
    var playing = true;
    var lastStep = 0;

    makeRenderer(options.canvas, options.assetBase, function (renderer) {
      var effects = makeEffects();
      var scrub = buildScrub(options.scrub, events, function (next) {
        playing = false;
        setIndex(next, true);
      });
      if (options.playButton) {
        options.playButton.onclick = function () {
          playing = !playing;
          if (playing && index >= events.length) setIndex(0, true);
        };
      }

      function currentState() {
        return states[Math.min(index, states.length - 1)] ||
          { seats: [], board: [], turn: -1, ply: 0 };
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
            matchHeader(currentState(), payload.config, nameMap);
        }
        updateScorebug(options.scorebug, currentState(), nameMap);
        updateEndscreen(options.endscreen, payload.results,
          index >= events.length && events.length > 0, nameMap);
      }
      setIndex(0, true);

      (function frame(timestamp) {
        // Dwell on what the viewer is currently looking at — the event
        // just absorbed — so bubbles get read and the move arrow gets
        // seen before the next beat.
        var shown = index > 0 ? events[index - 1] : null;
        var stepMs = shown && shown.kind === "say" ? 1500 :
          shown && (shown.kind === "move" || shown.kind === "place") ? 900 :
          shown && shown.kind === "end" ? 1500 :
          500;
        if (playing && index < events.length &&
            timestamp - lastStep > stepMs) {
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

  window.FocusRenderer = {
    attachLive: attachLive,
    attachReplay: attachReplay,
    renderFeed: renderFeed,
    bindFeedToggle: bindFeedToggle
  };
})();
