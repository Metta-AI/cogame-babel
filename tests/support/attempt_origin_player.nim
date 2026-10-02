## Socket fixture that asserts fully populated teacher/human evidence as a player.
import std/[json, options, os]
import whisky
import bitworld/decision_trajectory
import babel/[llm, player_policy]

let kind = getEnv("ASSERTED_ORIGIN")
let origin = case kind
  of "teacher": aoTeacher
  of "human": aoHuman
  else: aoModel
let socket = newWebSocket(getEnv("COWORLD_PLAYER_WS_URL"))
while true:
  let received = socket.receiveMessage()
  if received.isNone: break
  if received.get().kind != TextMessage: continue
  let packet = parseJson(received.get().data)
  case packet["type"].getStr()
  of "decision":
    let sampled = scriptedAction(packet)
    var action = copy(sampled)
    var attempt = newDecisionAttempt("asserted-" & $packet["id"].getInt(), "external-policy", origin)
    attempt.model = some("asserted-teacher")
    attempt.modelIdentity = some(getEnv("COWORLD_SOURCE_REVISION"))
    attempt.prompt = promptMessages(packet, "external fixture")
    attempt.request = %*{"asserted_teacher": true, "observation": packet}
    attempt.response = %($sampled)
    attempt.rawResponse = %($sampled)
    attempt.decoder = %*{"method": "deterministic"}
    if kind == "model-mismatch":
      if packet["role"].getStr() == "speaker":
        action["tokens"] = %*[packet["alphabet"][0]]
      else:
        action["pick"] = %((sampled["pick"].getInt() + 1) mod 4)
    socket.send($(%*{"type": "action", "protocol": "babel.player.v2", "id": packet["id"],
      "source": "llm", "action": action, "training_attempt": attempt.attemptEvidenceJson()}))
  of "final": break
  else: discard
socket.close()
