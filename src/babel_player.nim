## Babel player: a policy is just a prompt.
##
## Connects to the game, delivers its prompt (from PLAYER_PROMPT, or a
## default Babel strategy), then idles until the final frame. All of the
## actual decision making happens inside the game server, which sends this
## seat's prompt to Claude whenever the seat speaks or listens.
##
## PLAYER_SCRIPTED=1 registers the seat as the built-in code-and-decode
## baseline instead: the server plays it deterministically, no LLM.
##
## To field your own policy, reuse this image and set PLAYER_PROMPT:
##   coworld upload-policy <babel-image> --name my-babel \
##     --run /bin/babel-player --secret-env PLAYER_PROMPT="<your strategy>"

import
  std/[json, options, os, strutils],
  whisky

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

  proc promptFrame(): string =
    $ %*{"type": "prompt", "prompt": prompt, "scripted": scripted}

  echo "babel player: connecting to game"
  let socket = newWebSocket(url)
  socket.send(promptFrame())
  echo "babel player: prompt delivered (", prompt.len, " chars",
    (if scripted: ", scripted" else: ""), ")"

  while true:
    let received = socket.receiveMessage()
    if received.isNone:
      echo "babel player: connection closed, exiting"
      break
    let message = received.get()
    if message.kind != TextMessage:
      continue
    try:
      let payload = parseJson(message.data)
      case payload{"type"}.getStr()
      of "welcome":
        echo "babel player: seated at slot ",
          payload{"slot"}.getInt(), " as ", payload{"name"}.getStr()
        ## Re-deliver the prompt after the welcome, in case the first send
        ## raced the server's slot registration.
        socket.send(promptFrame())
      of "final":
        echo "babel player: final scores ", payload{"scores"}
        break
      else:
        discard
    except CatchableError as error:
      echo "babel player: ignoring bad frame: ", error.msg
  socket.close()
