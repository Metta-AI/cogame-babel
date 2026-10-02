## Scripted and prompt policies over Babel's ordinary private decision view.

import std/json
import llm

proc promptMessages*(view: JsonNode, operatorPrompt: string): JsonNode =
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
  %*[
    {"role": "system", "content": system},
    {"role": "user", "content": user}
  ]

proc promptAction*(client: LlmClient, view: JsonNode,
    operatorPrompt: string): JsonNode =
  let messages = promptMessages(view, operatorPrompt)
  extractJsonObject(client.completeText(messages[0]["content"].getStr(),
    messages[1]["content"].getStr(), view["slot"].getInt()))
