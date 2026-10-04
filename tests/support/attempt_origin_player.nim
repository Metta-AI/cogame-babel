## Socket fixture that asserts fully populated teacher/human evidence as a player.
import std/[json, monotimes, options, os, times]
import bitworld/[decision_trajectory, native_websocket]
import babel/[llm, player_policy]

let kind = getEnv("ASSERTED_ORIGIN")
let origin = case kind
  of "teacher": aoTeacher
  of "human": aoHuman
  of "model-mismatch", "model-body-mismatch", "scripted-model-body-mismatch", "first-finished-start": aoModel
  else: aoUnknown
let deadline = getMonoTime() + initDuration(seconds = 30)
let connected = connectNativeWebSocket(getEnv("COWORLD_PLAYER_WS_URL"), deadline, 16 * 1024 * 1024)
doAssert connected.kind == wsReady
let socket = connected.socket
while true:
  let received = socket.receiveNativeText(deadline)
  if received.kind == wsClosed: break
  doAssert received.kind == wsMessage
  let packet = parseJson(received.data)
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
    if kind in ["model-mismatch", "model-body-mismatch", "scripted-model-body-mismatch", "first-finished-start"]:
      attempt.request = %*{"system": attempt.prompt[0]["content"],
        "messages": [{"role": "user", "content": attempt.prompt[1]["content"]}],
        "model": "asserted-teacher", "temperature": 0, "max_tokens": 900}
      attempt.decoder = %*{"temperature": 0, "max_tokens": 900}
      var started = newDecisionAttempt(attempt.attemptId, attempt.policy, aoModel)
      started.model = attempt.model
      started.prompt = copy(attempt.prompt)
      started.request = copy(attempt.request)
      started.decoder = copy(attempt.decoder)
      if kind != "first-finished-start":
        doAssert socket.sendNativeText($(%*{"type": "attempt_started", "decision_id": packet["decision_id"],
          "training_attempt": started.attemptEvidenceJson()}), deadline).kind == wsReady
      attempt.rawResponse = %($(%*{"model": "asserted-teacher",
        "content": [{"type": "text", "text": $sampled}]}))
      if kind in ["model-body-mismatch", "scripted-model-body-mismatch"]:
        attempt.rawResponse = %($(%*{"model": "asserted-teacher",
          "content": [{"type": "text", "text": "different native completion"}]}))
      attempt.httpStatus = some(200)
      attempt.responseComplete = some(true)
      attempt.responseReaderJoined = some(true)
      if kind == "first-finished-start":
        doAssert socket.sendNativeText($(%*{"type": "attempt_started", "decision_id": packet["decision_id"],
          "training_attempt": attempt.attemptEvidenceJson()}), deadline).kind == wsReady
    if kind == "premature-stop":
      doAssert socket.sendNativeText($(%*{"type": "stopped", "decision_id": packet["decision_id"], "stop_id": newJNull(),
        "worker_status": "no_active_call", "attempts": []}), deadline).kind == wsReady
    doAssert socket.sendNativeText($(%*{"type": "action", "decision_id": packet["decision_id"],
      "source": (if kind == "scripted-model-body-mismatch": "scripted" else: "llm"), "action": action, "training_attempt": attempt.attemptEvidenceJson()}), deadline).kind == wsReady
  of "stop":
    if kind == "premature-stop": break
    let stoppedId = if kind == "stale-stop": %(packet["decision_id"].getStr() & "-stale") else: packet["decision_id"]
    doAssert socket.sendNativeText($(%*{"type": "stopped", "decision_id": stoppedId, "stop_id": packet["stop_id"],
      "worker_status": "no_active_call", "attempts": []}), deadline).kind == wsReady
    if kind == "stale-stop": break
  of "final": break
  else: discard
closeNativeWebSocket(socket)
