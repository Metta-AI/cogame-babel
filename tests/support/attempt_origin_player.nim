## Socket fixture that asserts fully populated teacher/human evidence as a player.
import std/[json, options, os]
import whisky
import bitworld/decision_trajectory
import babel/[llm, player_policy]

let kind = getEnv("ASSERTED_ORIGIN")
let origin = case kind
  of "teacher": aoTeacher
  of "human": aoHuman
  of "model-mismatch", "model-body-mismatch", "scripted-model-body-mismatch": aoModel
  else: aoUnknown
let socket = newWebSocket(getEnv("COWORLD_PLAYER_WS_URL"))
while true:
  let received = socket.receiveMessage()
  if received.isNone: break
  if received.get().kind != TextMessage: continue
  let packet = parseJson(received.get().data)
  case packet["type"].getStr()
  of "decision":
    let view = packet["observation"]
    let sampled = scriptedAction(view)
    var action = copy(sampled)
    var attempt = newDecisionAttempt(packet["decision_id"].getStr() & "-model", "external-policy", origin)
    attempt.model = some("asserted-teacher")
    attempt.modelIdentity = some(getEnv("COWORLD_SOURCE_REVISION"))
    attempt.prompt = promptMessages(view, "external fixture")
    attempt.request = %*{"asserted_teacher": true, "observation": view}
    attempt.response = %($sampled)
    attempt.rawResponse = %($sampled)
    attempt.decoder = %*{"method": "deterministic"}
    if kind == "model-mismatch":
      if view["role"].getStr() == "speaker":
        action["tokens"] = %*[view["alphabet"][0]]
      else:
        action["pick"] = %((sampled["pick"].getInt() + 1) mod 4)
    if kind in ["model-mismatch", "model-body-mismatch", "scripted-model-body-mismatch"]:
      attempt.request = %*{"system": attempt.prompt[0]["content"],
        "messages": [{"role": "user", "content": attempt.prompt[1]["content"]}],
        "model": "asserted-teacher", "temperature": 0, "max_tokens": 900}
      var started = attempt
      started.response = newJNull()
      started.rawResponse = newJNull()
      socket.send($(%*{"type": "attempt_started", "decision_id": packet["decision_id"],
        "training_attempt": started.attemptEvidenceJson()}))
      attempt.rawResponse = %($(%*{"model": "asserted-teacher",
        "content": [{"type": "text", "text": $sampled}]}))
      if kind in ["model-body-mismatch", "scripted-model-body-mismatch"]:
        attempt.rawResponse = %($(%*{"model": "asserted-teacher",
          "content": [{"type": "text", "text": "different native completion"}]}))
      attempt.httpStatus = some(200)
      attempt.responseComplete = some(true)
      attempt.responseReaderJoined = some(true)
    if kind == "premature-stop":
      socket.send($(%*{"type": "stopped", "decision_id": packet["decision_id"],
        "worker_status": "no_active_call", "attempts": []}))
    socket.send($(%*{"type": "action", "decision_id": packet["decision_id"],
      "source": (if kind == "scripted-model-body-mismatch": "scripted" else: "llm"), "action": action, "training_attempt": attempt.attemptEvidenceJson()}))
  of "stop":
    if kind == "premature-stop": break
    let stoppedId = if kind == "stale-stop": %(packet["decision_id"].getStr() & "-stale") else: packet["decision_id"]
    socket.send($(%*{"type": "stopped", "decision_id": stoppedId,
      "worker_status": "no_active_call", "attempts": []}))
    if kind == "stale-stop": break
  of "final": break
  else: discard
socket.close()
