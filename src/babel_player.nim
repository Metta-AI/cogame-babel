## Babel player: scripted or prompt policy over one private decision view.
##
## To field your own policy, reuse this image and set PLAYER_PROMPT:
##   coworld upload-policy <babel-image> --name my-babel \
##     --run /bin/babel-player --secret-env PLAYER_PROMPT="<your strategy>"

import std/[atomics, json, locks, monotimes, options, os, strutils, times]
import whisky
import bitworld/[decision_trajectory, native_stop]
import babel/[llm, player_policy]

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

type PlayerCall = object
  socket: WebSocket
  decisionId, observation, prompt: string
  deadline: MonoTime
  scripted: bool

var
  worker: Thread[PlayerCall]
  workerCreated = false
  workerFinished: Atomic[bool]
  evidenceLock: Lock
  workerEvidence: string

initLock(evidenceLock)

proc joinWorker() =
  if workerCreated:
    joinThread(worker)
    workerCreated = false

proc runDecision(call: PlayerCall) {.gcsafe.} =
  defer: workerFinished.store(true)
  let observation = parseJson(call.observation)
  var action: JsonNode
  var source = "scripted"
  var attempt = newJNull()
  var failure = ""
  let client = if not call.scripted: newLlmClient() else: nil
  if call.scripted:
    action = scriptedAction(observation)
  elif client.disabled:
    action = scriptedAction(observation)
    source = "fallback"
  else:
    client.beforeCall = proc(evidence: LlmCallEvidence) {.gcsafe.} =
      let started = evidence.privateAttempt(call.decisionId & "-model").attemptEvidenceJson()
      {.gcsafe.}:
        withLock evidenceLock: workerEvidence = $started
      call.socket.send($(%*{"type": "attempt_started", "decision_id": call.decisionId,
        "training_attempt": started}))
    try:
      action = promptAction(client, observation, call.prompt, call.deadline)
      source = "llm"
    except CatchableError as error:
      failure = error.msg
      echo "babel player: model call failed; using scripted fallback"
      action = scriptedAction(observation)
      source = "fallback"
    attempt = client.lastCall.privateAttempt(call.decisionId & "-model", failure).attemptEvidenceJson()
    {.gcsafe.}:
      withLock evidenceLock: workerEvidence = $attempt
  if not interruptionRequested():
    call.socket.send($(%*{"type": "action", "decision_id": call.decisionId,
      "action": action, "source": source, "training_attempt": attempt}))

proc stopAndAcknowledge(socket: WebSocket, decisionId: JsonNode) =
  ## Acknowledgement proves this owned worker joined, never a platform receipt.
  requestNativeStop()
  let hadWorker = workerCreated
  joinWorker()
  var attempts = newJArray()
  withLock evidenceLock:
    if workerEvidence.len > 0: attempts.add(parseJson(workerEvidence))
  socket.send($(%*{"type": "stopped", "decision_id": decisionId,
    "worker_status": (if hadWorker: "joined" else: "no_active_call"),
    "attempts": attempts}))

when isMainModule:
  installNativeStopHandlers()
  let url = getEnv("COWORLD_PLAYER_WS_URL")
  if url.len == 0: quit("COWORLD_PLAYER_WS_URL is not set", 1)
  let prompt = getEnv("PLAYER_PROMPT", DefaultPrompt)
  let scripted = getEnv("PLAYER_SCRIPTED").strip() in ["1", "true", "yes"]
  let socket = newWebSocket(url)
  var decisionId = newJNull()
  var acknowledged = false
  var finalDeadline: MonoTime
  try:
    while true:
      if workerCreated and workerFinished.load(): joinWorker()
      if interruptionRequested() and not acknowledged:
        stopAndAcknowledge(socket, decisionId)
        acknowledged = true
        break
      if acknowledged and getMonoTime() >= finalDeadline: break
      let received = socket.receiveMessage(timeout = 50)
      if received.isNone: continue
      let message = received.get()
      if message.kind != TextMessage: continue
      let payload = parseJson(message.data)
      case payload["type"].getStr()
      of "welcome":
        echo "babel player: seated at slot ", payload["slot"].getInt()
      of "decision":
        if acknowledged: raise newException(ValueError, "decision received after stop")
        let receivedAt = getMonoTime()
        let budget = payload["transport"]["budget_ms"].getInt()
        if budget <= 0: raise newException(ValueError, "decision transport budget must be positive")
        decisionId = payload["decision_id"]
        if decisionId.kind != JString or decisionId.getStr().len == 0:
          raise newException(ValueError, "decision identity must be a nonempty string")
        joinWorker()
        withLock evidenceLock: workerEvidence.setLen(0)
        workerFinished.store(false)
        createThread(worker, runDecision, PlayerCall(socket: socket,
          decisionId: decisionId.getStr(), observation: $payload["observation"],
          prompt: prompt, scripted: scripted,
          deadline: receivedAt + initDuration(milliseconds = budget)))
        workerCreated = true
      of "stop":
        finalDeadline = getMonoTime() + initDuration(milliseconds = payload["cleanup_budget_ms"].getInt())
        stopAndAcknowledge(socket, payload["decision_id"])
        acknowledged = true
      of "final":
        if not acknowledged:
          stopAndAcknowledge(socket, decisionId)
          acknowledged = true
        break
      of "state": discard
      else: raise newException(ValueError, "unknown player frame")
  finally:
    let interrupted = interruptionRequested()
    requestNativeStop()
    joinWorker()
    if interrupted and not acknowledged:
      stopAndAcknowledge(socket, decisionId)
    socket.close()
