## Babel player: scripted or prompt policy over one private decision view.
##
## To field your own policy, reuse this image and set PLAYER_PROMPT:
##   coworld upload-policy <babel-image> --name my-babel \
##     --run /bin/babel-player --secret-env PLAYER_PROMPT="<your strategy>"

import std/[atomics, json, locks, math, monotimes, options, os, strutils, times]
import bitworld/[decision_trajectory, native_stop, native_websocket]
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
  socket: ptr NativeWebSocket
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
      let sent = call.socket[].sendNativeText($(%*{"type": "attempt_started", "decision_id": call.decisionId,
        "training_attempt": started}), call.deadline)
      if sent.kind != wsReady:
        raise newException(ValueError, "native attempt start was not delivered")
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
    discard call.socket[].sendNativeText($(%*{"type": "action", "decision_id": call.decisionId,
      "action": action, "source": source, "training_attempt": attempt}), call.deadline)

proc stopAndAcknowledge(socket: NativeWebSocket, decisionId, stopId: JsonNode,
    cleanupDeadline: MonoTime): bool =
  ## Acknowledgement proves this owned worker joined, never a platform receipt.
  requestNativeStop()
  let hadWorker = workerCreated
  joinWorker()
  var attempts = newJArray()
  withLock evidenceLock:
    if workerEvidence.len > 0: attempts.add(parseJson(workerEvidence))
  let sent = socket.sendCleanupText($(%*{"type": "stopped", "decision_id": decisionId, "stop_id": stopId,
    "worker_status": (if hadWorker: "joined" else: "no_active_call"),
    "attempts": attempts}), cleanupDeadline)
  if sent.kind != wsReady: return false
  while getMonoTime() < cleanupDeadline:
    let received = socket.receiveCleanupText(cleanupDeadline)
    if received.kind != wsMessage: return false
    let frame = parseJson(received.data)
    if frame["type"].getStr() == "evidence_received" and
        frame["decision_id"] == decisionId and frame["stop_id"] == stopId:
      return true
  false

when isMainModule:
  installNativeStopHandlers()
  let url = getEnv("COWORLD_PLAYER_WS_URL")
  if url.len == 0: quit("COWORLD_PLAYER_WS_URL is not set", 1)
  let prompt = getEnv("PLAYER_PROMPT", DefaultPrompt)
  let scripted = getEnv("PLAYER_SCRIPTED").strip() in ["1", "true", "yes"]
  let timeout = parseFloat(getEnv("COWORLD_TIMEOUT_SECONDS", "1200"))
  if timeout <= 0 or classify(timeout) in {fcNan, fcInf, fcNegInf}:
    raise newException(ValueError, "player timeout must be finite and positive")
  let started = getMonoTime()
  let playerDeadline = started + initDuration(nanoseconds = int64(timeout * 1_000_000_000))
  let connection = connectNativeWebSocket(url,
    min(playerDeadline, started + initDuration(seconds = 30)), 16 * 1024 * 1024)
  case connection.kind
  of wsInterrupted, wsDeadline: quit(0)
  of wsReady: discard
  else: raise newException(ValueError, "native player connection failed")
  var socket = connection.socket
  var decisionId = newJNull()
  var acknowledged = false
  var finalDeadline: MonoTime
  var cleanupBudgetMs = 0
  var cleanupStarted = false
  try:
    while true:
      if workerCreated and workerFinished.load(): joinWorker()
      if interruptionRequested() and not acknowledged:
        finalDeadline = getMonoTime() + initDuration(milliseconds = cleanupBudgetMs)
        cleanupStarted = true
        acknowledged = stopAndAcknowledge(socket, decisionId, newJNull(), finalDeadline)
        break
      if getMonoTime() >= playerDeadline: break
      let received = socket.receiveNativeText(min(playerDeadline,
        getMonoTime() + initDuration(milliseconds = 50)))
      case received.kind
      of wsDeadline, wsInterrupted: continue
      of wsClosed: break
      of wsMessage: discard
      else: raise newException(ValueError, "native player socket failed")
      let payload = parseJson(received.data)
      case payload["type"].getStr()
      of "welcome":
        echo "babel player: seated at slot ", payload["slot"].getInt()
      of "decision":
        if acknowledged: raise newException(ValueError, "decision received after stop")
        let receivedAt = getMonoTime()
        let budget = payload["transport"]["budget_ms"].getInt()
        if budget <= 0: raise newException(ValueError, "decision transport budget must be positive")
        cleanupBudgetMs = payload["transport"]["cleanup_budget_ms"].getInt()
        if cleanupBudgetMs < 0: raise newException(ValueError, "cleanup budget cannot be negative")
        let issuedId = payload["decision_id"]
        if issuedId.kind != JString or issuedId.getStr().len == 0:
          raise newException(ValueError, "decision identity must be a nonempty string")
        joinWorker()
        # Preserve the previous operation's identity and final bytes when stop wins
        # while joining it. No new decision may clear that owned evidence.
        if interruptionRequested(): break
        decisionId = issuedId
        withLock evidenceLock: workerEvidence.setLen(0)
        workerFinished.store(false)
        createThread(worker, runDecision, PlayerCall(socket: socket.addr,
          decisionId: decisionId.getStr(), observation: $payload["observation"],
          prompt: prompt, scripted: scripted,
          deadline: min(playerDeadline, receivedAt + initDuration(milliseconds = budget))))
        workerCreated = true
      of "stop":
        finalDeadline = getMonoTime() + initDuration(milliseconds = payload["cleanup_budget_ms"].getInt())
        cleanupStarted = true
        acknowledged = stopAndAcknowledge(socket, payload["decision_id"], payload["stop_id"], finalDeadline)
        break  # Confirmed evidence delivery finishes this client's ownership.
      of "final":
        if not acknowledged:
          finalDeadline = getMonoTime() + initDuration(milliseconds = cleanupBudgetMs)
          cleanupStarted = true
          acknowledged = stopAndAcknowledge(socket, decisionId, newJNull(), finalDeadline)
        break
      of "state", "evidence_received": discard
      else: raise newException(ValueError, "unknown player frame")
  finally:
    requestNativeStop()
    joinWorker()
    if not cleanupStarted:
      finalDeadline = getMonoTime() + initDuration(milliseconds = cleanupBudgetMs)
      discard stopAndAcknowledge(socket, decisionId, newJNull(), finalDeadline)
    closeNativeWebSocket(socket)
