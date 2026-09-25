## Babel player: scripted, prompt, or Jev policy over one private decision view.
##
## To field your own policy, reuse this image and set PLAYER_PROMPT:
##   coworld upload-policy <babel-image> --name my-babel \
##     --run /bin/babel-player --secret-env PLAYER_PROMPT="<your strategy>"

import std/[json, options, os, strutils]
import whisky
import babel/[jev_policy, llm, player_policy]

const DefaultPrompt = """
Invent a compositional code and stick to it: one glyph for each shape,
one for each colour, one for each count, always sent in the order
shape, colour, count. As speaker, be perfectly consistent from round one
and never reuse a glyph for two meanings; a partner can only learn a code
that does not move. As listener, treat every past round as evidence:
after each verdict, update a per-partner dictionary mapping each glyph
you received to the attribute values of the revealed target, and write
that dictionary into your notes every round so it survives. When the
message is ambiguous, prefer the lineup card that agrees with the most
glyphs, and between close candidates prefer the near miss that shares
two attributes with your best reading over a wild guess.
"""

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL")
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  var prompt = getEnv("PLAYER_PROMPT")
  if prompt.len == 0:
    prompt = DefaultPrompt
  let scripted = getEnv("PLAYER_SCRIPTED").strip() in ["1", "true", "yes"]
  let jev = getEnv("PLAYER_JEV") == "1"
  let client = if not scripted and not jev: newLlmClient() else: nil

  echo "babel player: connecting to game"
  let socket = newWebSocket(url)
  echo "babel player: policy=",
    (if scripted: "scripted" elif jev: "jev" else: "prompt")

  while true:
    let received = socket.receiveMessage()
    if received.isNone:
      echo "babel player: connection closed, exiting"
      break
    let message = received.get()
    if message.kind != TextMessage:
      continue
    let payload = parseJson(message.data)
    case payload{"type"}.getStr()
    of "welcome":
      echo "babel player: seated at slot ",
        payload["slot"].getInt(), " as ", payload["name"].getStr()
    of "decision":
      var action: JsonNode
      var source = "scripted"
      if scripted:
        action = scriptedAction(payload)
      elif jev and not jevConfigured():
        action = scriptedAction(payload)
        source = "fallback"
      elif not jev and client.disabled:
        action = scriptedAction(payload)
        source = "fallback"
      else:
        try:
          action = if jev: chooseJevAction(payload)
                   else: promptAction(client, payload, prompt)
          source = "llm"
        except CatchableError as error:
          echo "babel player: model call failed: ", error.msg
          action = scriptedAction(payload)
          source = "fallback"
      socket.send($(%*{
        "type": "action", "protocol": "babel.player.v2",
        "id": payload["id"], "action": action, "source": source
      }))
    of "final":
      echo "babel player: final scores ", payload["scores"]
      break
    else:
      discard
  socket.close()
