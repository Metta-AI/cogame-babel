## Game-owned action parsing and scripted fallback. No model transport.

import std/[json, random, strutils, tables, unicode]
import sim

const MaxNotesLen* = 600

type
  Decision* = object
    tokens*: seq[int]
    pick*: int
    notes*: string

  ScriptedPolicy* = ref object
    rand: Rand

proc newScriptedPolicy*(seed: int): ScriptedPolicy =
  ScriptedPolicy(rand: initRand(seed xor 0x5EED))

# ---- Scripted baseline ------------------------------------------------------

const
  ## Attribute-value slots for the decoder's association counts: shapes
  ## 0..3, colours 4..7, counts 8..11.
  AttributeSlots = 12

proc attributeSlots(scene: Scene): array[3, int] =
  [scene.shape, 4 + scene.colour, 8 + scene.count]

proc scriptedMessage*(target: int): seq[int] =
  ## The fixed compositional code on token ids: shape, then 4 + colour,
  ## then 8 + count.
  let slots = attributeSlots(sceneOf(target))
  @[slots[0], slots[1], slots[2]]

proc associations(sim: Sim, seat: int):
    array[Tokens, array[AttributeSlots, int]] =
  ## assoc[token][attribute value] counts from this seat's own feedback:
  ## every completed round it was in (either role, any partner) credits
  ## the revealed target's three values to every token of that round's
  ## message. Evidence is pooled across partners rather than keyed per
  ## partner alias: a seat meets each partner only twice per six rounds,
  ## and per-partner tables were measured to reach only ~0.58 success by
  ## round 12 against the ~0.89 of the pooled table.
  var messages: Table[(int, int), seq[int]]
  for event in sim.events:
    case event.kind
    of evSpeak:
      messages[(event.round, event.pair)] = event.tokens
    of evPick:
      if seat != event.seat and seat != event.other:
        continue
      let target = sim.schedule[event.round].targets[event.pair]
      let message = messages.getOrDefault((event.round, event.pair))
      for token in message:
        for slot in attributeSlots(sceneOf(target)):
          inc result[token][slot]
    else:
      discard

proc scriptedPick*(policy: ScriptedPolicy, sim: Sim, pair: int): int =
  ## Count-based decoder: scores each candidate by the summed association
  ## of the message's tokens with the candidate's three values; ties
  ## (including the no-evidence start) break by the seeded RNG.
  let plan = sim.plan
  let assoc = sim.associations(plan.listeners[pair])
  var best = int.low
  var bestPicks: seq[int]
  for index in 0 ..< LineupSize:
    var score = 0
    for token in sim.tokens[pair]:
      for slot in attributeSlots(sceneOf(plan.lineups[pair][index])):
        score += assoc[token][slot]
    if score > best:
      best = score
      bestPicks = @[index]
    elif score == best:
      bestPicks.add(index)
  bestPicks[policy.rand.rand(bestPicks.high)]

proc scriptedAction*(policy: ScriptedPolicy, sim: Sim, call: Call): Decision =
  ## Rule-based baseline: the fixed code as speaker, the count decoder as
  ## listener. Always legal; never produces notes.
  case call.kind
  of ckSpeak:
    result.tokens = scriptedMessage(sim.plan.targets[call.pair])
  of ckPick:
    result.pick = policy.scriptedPick(sim, call.pair)
  else:
    raise newException(BabelError, "no decision is due")


proc cleanNotes*(text: string): string =
  ## Notes over the cap are cut at a rune boundary with the cut marked.
  result = strutils.strip(text)
  if result.runeLen <= MaxNotesLen:
    return
  result = result.runeSubStr(0, MaxNotesLen - 1) & "…"

proc parseSpeak*(sim: Sim, seat: int, payload: JsonNode): Decision =
  ## Maps the model's JSON onto token ids through the seat's own view:
  ## "tokens" is an array of single glyphs, or one string of glyphs
  ## separated by spaces. Any glyph outside the alphabet is an invalid
  ## reply. Length is checked by applySpeak.
  result.notes = cleanNotes(payload{"notes"}.getStr())
  let node = payload{"tokens"}
  var glyphs: seq[string]
  if node.isNil:
    raise newException(BabelError, "no tokens in response")
  case node.kind
  of JArray:
    for entry in node:
      if entry.kind != JString:
        raise newException(BabelError, "tokens must be glyph strings")
      glyphs.add(strutils.strip(entry.getStr()))
  of JString:
    for part in strutils.splitWhitespace(node.getStr()):
      glyphs.add(part)
  else:
    raise newException(BabelError, "tokens must be an array of glyphs")
  for glyph in glyphs:
    if glyph.runeLen != 1:
      raise newException(BabelError,
        "each token must be exactly one glyph: " & glyph)
    result.tokens.add(sim.tokenOf(seat, glyph))

proc parsePick*(payload: JsonNode): Decision =
  ## "pick" is a letter A-D (any case, trailing text tolerated), or an
  ## integer: 0..3 as an index, 4 as the 1-based D.
  result.notes = cleanNotes(payload{"notes"}.getStr())
  let node = payload{"pick"}
  if node.isNil:
    raise newException(BabelError, "no pick in response")
  var pick = -1
  case node.kind
  of JInt:
    pick = node.getInt()
    if pick == LineupSize:
      pick = LineupSize - 1
  of JString:
    let text = strutils.strip(node.getStr())
    if text.len == 0:
      raise newException(BabelError, "empty pick")
    let head = text[0].toUpperAscii()
    if head in 'A' .. 'D':
      pick = ord(head) - ord('A')
    elif head in '0' .. '9':
      pick = ord(head) - ord('0')
      if pick == LineupSize:
        pick = LineupSize - 1
  else:
    discard
  if pick < 0 or pick >= LineupSize:
    raise newException(BabelError, "pick must be A-D: " & $node)
  result.pick = pick
