## Scripted and prompt policies over Babel's ordinary private decision view.

import std/json
import llm, sim

proc tokenIndex(alphabet: JsonNode, glyph: string): int =
  for index in 0 ..< alphabet.len:
    if alphabet[index].getStr() == glyph:
      return index
  raise newException(BabelError, "glyph outside this seat's alphabet")

proc scriptedAction*(view: JsonNode): JsonNode =
  let alphabet = view["alphabet"]
  if view["role"].getStr() == "speaker":
    let scene = sceneOf(view["target"].getInt())
    return %*{"tokens": [
      alphabet[scene.shape],
      alphabet[4 + scene.colour],
      alphabet[8 + scene.count]
    ], "notes": ""}

  var associations: array[Tokens, array[12, int]]
  for round in view["history"]:
    let scene = sceneOf(round["target"].getInt())
    for glyph in round["message"]:
      let token = tokenIndex(alphabet, glyph.getStr())
      inc associations[token][scene.shape]
      inc associations[token][4 + scene.colour]
      inc associations[token][8 + scene.count]
  var best = int.low
  var pick = 0
  for index in 0 ..< view["lineup"].len:
    let scene = sceneOf(view["lineup"][index].getInt())
    var score = 0
    for glyph in view["message"]:
      let token = tokenIndex(alphabet, glyph.getStr())
      score += associations[token][scene.shape]
      score += associations[token][4 + scene.colour]
      score += associations[token][8 + scene.count]
    if score > best:
      best = score
      pick = index
  %*{"pick": pick, "notes": ""}

proc promptAction*(client: LlmClient, view: JsonNode,
    operatorPrompt: string): JsonNode =
  let system = "You play Babel. Each speaker sends 1 to 8 glyphs from its " &
    "private alphabet. Each listener picks one of four scenes. Partners see " &
    "the same tokens under different glyphs. Learn a convention from your " &
    "own feedback. Reply with one JSON action and optional private notes."
  let task =
    if view["role"].getStr() == "speaker":
      "Send {\"tokens\":[\"glyph\",...],\"notes\":\"...\"}."
    else:
      "Send {\"pick\":0..3,\"notes\":\"...\"}."
  let user = "Your private observation:\n" & $view & "\n" &
    "Operator guidance:\n" & operatorPrompt & "\n" & task
  extractJsonObject(client.completeText(system, user))
