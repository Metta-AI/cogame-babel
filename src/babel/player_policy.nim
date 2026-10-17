## Scripted and prompt policies over Babel's ordinary private decision view.

import std/[json, monotimes]
import llm, prompts

proc promptMessages*(view: JsonNode, operatorPrompt: string,
    selection: PromptSelection): JsonNode =
  let system = selection.systemPrompt()
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
    operatorPrompt: string, selection: PromptSelection, deadline: MonoTime): JsonNode =
  let messages = promptMessages(view, operatorPrompt, selection)
  extractJsonObject(client.completeText(messages[0]["content"].getStr(),
    messages[1]["content"].getStr(), view["slot"].getInt(), deadline))
