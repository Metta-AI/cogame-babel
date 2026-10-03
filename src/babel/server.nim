## Babel game server: implements the Coworld game contract.
##
## Endpoints:
##   GET /healthz                    - liveness
##   GET /client/global              - spectator page
##   GET /client/player              - player page
##   GET /client/replay              - replay page (replay mode)
##   GET /client/renderer.js         - shared stage renderer
##   GET /client/assets/<name>       - sprites and fonts
##   WS  /player?slot=N&token=T      - player observation/action protocol
##   WS  /global                     - spectator snapshots
##   WS  /replay                     - replay payload (replay mode)
##
## Player transport (babel.player.v3), all JSON text frames.
## The unchanged canonical private observation uses babel.player.v2:
##   game -> player: {"type":"welcome","slot":N,"name":...}
##                   {"type":"decision",...} with one private task
##                   {"type":"state",...} after every event
##                   {"type":"final","scores":[...],"correct":[...]}
##   player -> game: {"type":"action","decision_id":"babel-N","action":{...}}
##   stop/stopped frames acknowledge joined player-owned inference before sealing.
##   Budgets live in the transport envelope, outside canonical observations.

import
  std/[json, locks, math, monotimes, options, os, sets, strutils, sysrand, tables, times],
  bitworld/runtime,
  bitworld/[artifact_runtime, decision_trajectory, native_stop],
  mummy,
  mummy/routers,
  game_policy,
  player_view,
  player_policy,
  sim

const
  ReplayVersion = 1

type
  StagedDecision = object
    id, seat: string
    observation, executedAction: JsonNode
    attempts: seq[DecisionAttempt]
    selected: Option[string]
    status: ActionStatus
    fallbackOrigin: Option[string]
    terminal: bool
  GameState = object
    config: GameConfig
    sim: Sim
    pendingActions: Table[string, tuple[payload: JsonNode, receivedAt: MonoTime]]
    pendingAttempts: Table[string, JsonNode]
    completedAttempts: Table[string, JsonNode]
    decisionSeats: Table[string, int]
    decisionIssuedAt: Table[string, MonoTime]
    decisionObservations: Table[string, JsonNode]
    latestDecisions: Table[int, string]
    stoppedSlots: HashSet[int]
    registeredSlots: HashSet[int]
    staged: seq[StagedDecision]
    episodeDeadline: MonoTime
    episodeTimeoutSeconds: float
    playerSockets: Table[int, WebSocket]
    socketSlots: Table[WebSocket, int]
    globalSockets: HashSet[WebSocket]
    started: bool
    stopping: bool
    stopId: string
    stopIssuedAt, acknowledgementDeadline: MonoTime
    finished: bool
    trajectory: Option[DecisionTrajectory]

var
  stateLock: Lock
  state: GameState
  gameServer: Server
  runtimeConfigGlobal: RuntimeConfig
  replayPayloadGlobal: string

initLock(stateLock)

proc clientDir(): string =
  let appDir = getAppDir()
  for candidate in [appDir / "client", appDir / ".." / "client", "client"]:
    if dirExists(candidate):
      return candidate
  "client"

proc dataDir(): string =
  let appDir = getAppDir()
  for candidate in [appDir / "data", appDir / ".." / "data", "data"]:
    if dirExists(candidate):
      return candidate
  "data"

proc policyNamesJson(gs: GameState): JsonNode =
  ## Seats play under anonymous table names; the policy names ride alongside
  ## for the SPECTATOR views only, which render them in place of the aliases.
  result = newJArray()
  for player in gs.config.players:
    result.add(%player.name)

proc snapshotJson(gs: GameState): JsonNode =
  var events = newJArray()
  for event in gs.sim.events:
    events.add(event.publicEventJson())
  var connected = newJArray()
  for slot in 0 ..< gs.config.tokens.len:
    connected.add(%gs.playerSockets.hasKey(slot))
  result = gs.sim.tableStateJson()
  result["type"] = %"state"
  result["game"] = %"babel"
  result["policyNames"] = gs.policyNamesJson()
  result["events"] = events
  result["started"] = %gs.started
  result["done"] = %gs.sim.done
  result["connected"] = connected

proc playerStateJson(gs: GameState, slot: int): JsonNode =
  ## Babel has hidden information (targets, lineups, notes, and the other
  ## pair's traffic are not for the seats), so a state update contains only
  ## this seat's tallies. The separate decision frame carries its private task.
  %*{
    "type": "state",
    "slot": slot,
    "name": gs.sim.names[slot],
    "seat": {
      "score": gs.sim.score(slot),
      "correct": gs.sim.correct[slot],
      "asSpeaker": gs.sim.asSpeaker[slot],
      "asListener": gs.sim.asListener[slot],
      "roundsPlayed": gs.sim.seatRounds[slot]
    },
    "round": gs.sim.round,
    "rounds": gs.config.rounds,
    "roundsPlayed": gs.sim.roundsPlayed,
    "started": gs.started,
    "done": gs.sim.done,
    "reason": gs.sim.reason
  }

proc broadcastLocked(gs: GameState) =
  ## Callers hold stateLock. Spectators get the whole table; players get
  ## the redacted per-seat state.
  let payload = $gs.snapshotJson()
  for socket in gs.globalSockets:
    socket.send(payload)
  for slot, socket in gs.playerSockets:
    socket.send($gs.playerStateJson(slot))

proc writeArtifact(uri, data, contentType, methodEnv: string, deadline: MonoTime) =
  if uri.len == 0: return
  let methodName = getEnv(methodEnv, "PUT").toUpperAscii()
  let httpMethod = case methodName
    of "PUT": ahPut
    of "POST": ahPost
    else: raise newException(ValueError, "artifact method must be PUT or POST")
  writeCogameArtifact(uri, data, contentType, methodEnv, deadline, httpMethod)

proc alphabetConfigJson(sim: Sim): (JsonNode, JsonNode) =
  ## The alphabet and per-seat views are derivable from the seed; they ride
  ## in the replay config for the viewer's convenience.
  var glyphs = newJArray()
  for glyph in sim.glyphs:
    glyphs.add(%glyph)
  var perm = newJArray()
  for seat in 0 ..< Seats:
    var view = newJArray()
    for index in sim.perm[seat]:
      view.add(%index)
    perm.add(view)
  (glyphs, perm)

proc replayPayload(gs: GameState, results: JsonNode): string =
  var names = newJArray()
  for name in gs.sim.names:
    names.add(%name)
  var events = newJArray()
  for event in gs.sim.events:
    events.add(event.publicEventJson())
  let (glyphs, perm) = gs.sim.alphabetConfigJson()
  $ %*{
    "protocol": "babel.replay.v" & $ReplayVersion,
    "names": names,
    "policyNames": gs.policyNamesJson(),
    "config": {
      "rounds": gs.config.rounds,
      "seed": gs.config.seed,
      "sampled": true,
      "glyphs": glyphs,
      "perm": perm
    },
    "events": events,
    "results": results
  }

proc statesFromEvents(config: GameConfig, events: seq[GameEvent]): JsonNode =
  ## One table-state object per event prefix, for scrubbing replays.
  result = newJArray()
  for frame in replayMatch(config, events):
    result.add(frame.tableStateJson())

proc finishEpisode(runtimeConfig: RuntimeConfig, status: EpisodeStatus) =
  ## One owner seals after bounded stop acknowledgements; no remote join is assumed.
  let cleanupDeadline = min(state.episodeDeadline, getMonoTime() + initDuration(seconds = 5))
  var targets: seq[int]
  withLock stateLock:
    if state.finished: return
    state.stopping = true
    var stopToken: array[16, byte]
    doAssert urandom(stopToken), "OS entropy unavailable for stop identity"
    for value in stopToken: state.stopId.add(value.toHex(2))
    state.stopIssuedAt = getMonoTime()
    state.acknowledgementDeadline = cleanupDeadline - initDuration(seconds = 1)
    for slot in state.registeredSlots:
      targets.add(slot)
      if not state.playerSockets.hasKey(slot): continue
      let socket = state.playerSockets[slot]
      let id = if state.latestDecisions.hasKey(slot): %state.latestDecisions[slot] else: newJNull()
      socket.send($(%*{"type": "stop", "decision_id": id, "stop_id": state.stopId,
        "reason": (if interruptionRequested(): "interrupted" elif status == esCompleted: "terminal" else: "episode_deadline"),
        "cleanup_budget_ms": max(0, (state.acknowledgementDeadline - getMonoTime()).inMilliseconds)}))
  let acknowledgementDeadline = cleanupDeadline - initDuration(seconds = 1)
  while getMonoTime() < acknowledgementDeadline:
    var acknowledged = true
    withLock stateLock:
      for slot in targets:
        if slot notin state.stoppedSlots: acknowledged = false
    if acknowledged: break
    sleep(10)

  var results: JsonNode
  var replayData: string
  var finalStatus = status
  var allAcknowledged = true
  withLock stateLock:
    state.finished = true
    results = state.sim.resultsJson()
    var cleanup = newJObject()
    for slot in targets:
      cleanup[$slot] = %(if slot in state.stoppedSlots: "acknowledged" else: "unresolved")
      if slot notin state.stoppedSlots:
        finalStatus = esTruncated
        allAcknowledged = false
    let privateOutcome = copy(results)
    privateOutcome["player_cleanup"] = cleanup
    replayData = state.replayPayload(results)
    if state.trajectory.isSome:
      for staged in state.staged:
        var attempts = staged.attempts
        # Accepted evidence is frozen at engine selection. Later messages cannot rewrite it.
        if staged.selected.isNone and state.completedAttempts.hasKey(staged.id):
          var received = readAttemptEvidence(state.completedAttempts[staged.id])
          if received.origin in {aoTeacher, aoHuman}: received.origin = aoUnknown
          if attempts.len > 0:
            received.accepted = attempts[0].accepted
            received.parsedAction = attempts[0].parsedAction
            received.rejectionReason = attempts[0].rejectionReason
          else:
            received.rejectionReason = some("late native evidence after engine decision")
          attempts = @[received]
        state.trajectory.get().recordDecision(staged.id, staged.seat, staged.observation,
          attempts, staged.selected, staged.executedAction, staged.status,
          terminal = staged.terminal, fallbackOrigin = staged.fallbackOrigin)
      var outcomes = newJObject()
      for seat in 0 ..< Seats: outcomes[$seat] = results["scores"][seat]
      if interruptionRequested(): finalStatus = esTruncated
      state.trajectory.get().finish(finalStatus, privateOutcome,
        if finalStatus != esCompleted: newJNull() else: outcomes)
    var names = newJArray()
    for name in state.sim.names: names.add(%name)
    let final = %*{"type": "final", "done": true, "scores": results["scores"],
      "correct": results["correct"], "asSpeaker": results["asSpeaker"],
      "asListener": results["asListener"], "names": names,
      "rounds": results["rounds"], "reason": results["reason"]}
    if allAcknowledged and not interruptionRequested() and status != esFailed:
      for slot, socket in state.playerSockets: socket.send($final)
      state.broadcastLocked()
  if state.trajectory.isSome:
    let methodName = getEnv("COGAME_SAVE_TRAJECTORY_METHOD", "PUT")
    let httpMethod = case methodName
      of "PUT": ahPut
      of "POST": ahPost
      else: raise newException(ValueError, "trajectory method must be PUT or POST")
    state.trajectory.get().writeTrajectoryArtifact(getEnv(CogameSaveTrajectoryUriEnv), cleanupDeadline, httpMethod)
  if not interruptionRequested() and status != esFailed and allAcknowledged:
    writeArtifact(runtimeConfig.resultsUri, $results, "application/json", "COGAME_RESULTS_METHOD", cleanupDeadline)
    writeArtifact(runtimeConfig.replayUri, replayData, "application/octet-stream", "COGAME_SAVE_REPLAY_METHOD", cleanupDeadline)
    if getMonoTime() + initDuration(milliseconds = 500) < cleanupDeadline: sleep(500)

const PlayBudgetFraction* = 0.6
  ## Share of the platform's episode timeout spent playing. The rest covers
  ## container start, player connects, and writing the artifacts — the part
  ## that must never be the thing that runs out of time.

proc decisionText(sim: Sim, call: Call, decision: Decision): string =
  case call.kind
  of ckSpeak:
    sim.names[call.seat] & " -> " & sim.names[sim.plan.listeners[call.pair]] &
      ": " & sim.messageText(call.seat, decision.tokens) & " " &
      $decision.tokens
  of ckPick:
    sim.names[call.seat] & " picks " & lineupLetter(decision.pick)
  else:
    ""

proc runGame(runtimeConfig: RuntimeConfig) {.gcsafe.} =
  {.gcsafe.}:
    let config = state.config
    let gameStart = getMonoTime()
    var ownerStatus = esFailed
    defer:
      gameServer.close()
    defer:
      finishEpisode(runtimeConfig, ownerStatus)
    # Player connection waits share the play budget; cleanup retains its remainder.
    let timeoutSeconds = state.episodeTimeoutSeconds
    let playDeadline = min(state.episodeDeadline, gameStart + initDuration(milliseconds =
      int64(timeoutSeconds * PlayBudgetFraction * 1000)))
    let deadline = min(playDeadline, gameStart + initDuration(nanoseconds =
      int64(config.playerConnectTimeoutSeconds * 1_000_000_000)))

    while getMonoTime() < deadline and not interruptionRequested():
      var allConnected = false
      withLock stateLock:
        allConnected = state.playerSockets.len >= config.tokens.len
      if allConnected:
        break
      sleep(200)

    withLock stateLock:
      state.started = true
      echo "babel: starting with ", state.playerSockets.len, "/",
        config.tokens.len, " players connected"
      state.broadcastLocked()

    let fallbackClient = newScriptedPolicy(config.seed)

    while not interruptionRequested():
      var simCopy: Sim
      var call: Call
      var playerSocket: WebSocket
      var hasSocket: bool
      var pastDeadline: bool
      withLock stateLock:
        if state.sim.done:
          break
        call = state.sim.currentCall()
        pastDeadline = timeoutSeconds > 0.0 and getMonoTime() > playDeadline
        if call.kind == ckRound:
          if pastDeadline:
            ## The platform kills an episode that outruns its timeout and
            ## keeps nothing at all, so give up rounds rather than the
            ## whole result: stop here, between rounds.
            echo "babel: episode deadline reached after ",
              state.sim.roundsPlayed, "/", config.rounds,
              " rounds; ending early"
            state.sim.endEarly()
            state.broadcastLocked()
            break
          state.sim.beginRound()
          echo "babel: round ", state.sim.round + 1, " of ", config.rounds,
            " at ", (getMonoTime() - gameStart).inSeconds, "s"
          state.broadcastLocked()
          continue
        simCopy = state.sim
        hasSocket = state.playerSockets.hasKey(call.seat)
        if hasSocket:
          playerSocket = state.playerSockets[call.seat]

      let view = simCopy.decisionView(call)
      let decisionId = "babel-" & $view["id"].getInt()
      let decisionDeadline = min(playDeadline, getMonoTime() + initDuration(nanoseconds = int64(config.decisionTimeoutSeconds * 1_000_000_000)))
      if hasSocket and not pastDeadline:
        withLock stateLock:
          state.decisionSeats[decisionId] = call.seat
          state.decisionIssuedAt[decisionId] = getMonoTime()
          state.decisionObservations[decisionId] = copy(view)
          state.latestDecisions[call.seat] = decisionId
        try:
          playerSocket.send($(%*{"type": "decision", "decision_id": decisionId,
            "observation": view, "transport": {
              "budget_ms": max(1, (decisionDeadline - getMonoTime()).inMilliseconds),
              "cleanup_budget_ms": 5000}}))
        except CatchableError as error:
          echo "babel: could not send decision to seat ", call.seat
          hasSocket = false
      var response: JsonNode
      var lateResponse: JsonNode
      while hasSocket and not pastDeadline and not interruptionRequested():
        withLock stateLock:
          if state.pendingActions.hasKey(decisionId):
            let candidate = state.pendingActions[decisionId]
            state.pendingActions.del(decisionId)
            if candidate.payload["decision_id"].getStr() == decisionId:
              if candidate.receivedAt <= decisionDeadline:
                response = candidate.payload
              else:
                lateResponse = candidate.payload
        if response != nil or lateResponse != nil or getMonoTime() >= decisionDeadline:
          break
        sleep(10)

      if interruptionRequested():
        withLock stateLock:
          var attempts: seq[DecisionAttempt]
          if state.pendingAttempts.hasKey(decisionId):
            var attempt = readAttemptEvidence(state.pendingAttempts[decisionId])
            if attempt.origin in {aoTeacher, aoHuman}: attempt.origin = aoUnknown
            attempt.rejectionReason = some("interrupted before engine selection")
            attempts.add(attempt)
          state.staged.add(StagedDecision(id: decisionId, seat: $call.seat,
            observation: view, executedAction: newJNull(), attempts: attempts,
            selected: none(string), status: asMissing, terminal: true))
        break
      var decision: Decision
      var fellBack = response == nil or response{"source"}.getStr() == "fallback"
      var rejection = ""
      var fallbackPolicy = if response == nil: "game-scripted" else: "player-scripted"
      var proposedAction = newJNull()
      withLock stateLock:
        if response != nil:
          let playerFallback = response["source"].getStr() == "fallback"
          var modelResponse = none(string)
          if response.hasKey("training_attempt") and response["training_attempt"].kind == JObject:
            let evidence = readAttemptEvidence(response["training_attempt"])
            if evidence.origin == aoModel and not playerFallback:
              modelResponse = some(if evidence.response.kind == JString:
                evidence.response.getStr() else: "")
          let resolution = state.sim.resolveAction(call, $response["action"], view,
            response{"source"}.getStr() != "llm", fallbackClient, modelResponse)
          proposedAction = if playerFallback: newJNull() else: resolution.proposedAction
          decision = resolution.decision
          if not resolution.accepted:
            fellBack = true
            rejection = resolution.rejection
            fallbackPolicy = resolution.fallbackOrigin
            echo "babel: player action rejected; using scripted fallback"
        else:
          decision = fallbackClient.scriptedAction(state.sim, call)
          if call.kind == ckSpeak:
            state.sim.applySpeak(call.pair, decision.tokens, decision.notes, true)
          else:
            state.sim.applyPick(call.pair, decision.pick, decision.notes, true)
        echo "babel: round ", simCopy.round + 1, " pair ", call.pair, " ",
          decisionText(state.sim, call, decision), " at ",
          (getMonoTime() - gameStart).inSeconds, "s"
        if state.trajectory.isSome:
          let actualAction = state.sim.actionJson(call, decision)
          var attempts: seq[DecisionAttempt]
          var selected = none(string)
          var privateEvidence = newJNull()
          if response != nil and response.hasKey("training_attempt") and
              response["training_attempt"].kind == JObject:
            privateEvidence = response["training_attempt"]
          elif lateResponse != nil and lateResponse.hasKey("training_attempt") and
              lateResponse["training_attempt"].kind == JObject:
            privateEvidence = lateResponse["training_attempt"]
          elif state.pendingAttempts.hasKey(decisionId):
            privateEvidence = state.pendingAttempts[decisionId]
          if privateEvidence.kind == JObject:
            var attempt = readAttemptEvidence(privateEvidence)
            if attempt.origin in {aoTeacher, aoHuman}: attempt.origin = aoUnknown
            attempt.accepted = not fellBack
            attempt.parsedAction = proposedAction
            if rejection.len > 0:
              attempt.rejectionReason = some(rejection)
            elif response == nil:
              attempt.rejectionReason = some(if lateResponse != nil:
                "late player response after game decision deadline"
                else: "game decision timeout before player response")
            attempts.add(attempt)
            if not fellBack:
              selected = some(attempt.attemptId)
          elif not fellBack:
            let attemptId = "babel-" & $view["id"].getInt() & "-external"
            var external = newDecisionAttempt(attemptId, "external-babel", aoUnknown)
            external.response = response["action"]
            external.parsedAction = actualAction
            external.accepted = true
            attempts.add(external)
            selected = some(attemptId)
          state.staged.add(StagedDecision(id: decisionId, seat: $call.seat,
            observation: view, attempts: attempts, selected: selected,
            executedAction: actualAction, status: (if fellBack: asFallback else: asAccepted),
            terminal: state.sim.done, fallbackOrigin: (if fellBack: some(fallbackPolicy) else: none(string))))
        state.broadcastLocked()

      ## Pace between rounds: after the pick that closes a round.
      if config.turnDelayMs > 0 and call.kind == ckPick and call.pair == 1:
        sleep(config.turnDelayMs)

    ## Let the verdict land before the final frame.
    if config.turnDelayMs > 0:
      sleep(config.turnDelayMs)
    ownerStatus = if interruptionRequested() or state.sim.reason != "complete": esTruncated else: esCompleted

var gameThread: Thread[RuntimeConfig]

proc serveFile(request: Request, path, contentType: string) =
  if fileExists(path):
    var headers: HttpHeaders
    headers["Content-Type"] = contentType
    request.respond(200, headers, readFile(path))
  else:
    request.respond(404)

proc htmlHandler(name: string): RequestHandler =
  proc handler(request: Request) {.gcsafe.} =
    {.gcsafe.}:
      serveFile(request, clientDir() / name, "text/html; charset=utf-8")
  handler

proc assetHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let name = request.pathParams["name"]
    if "/" in name or "\\" in name or name.startsWith("."):
      request.respond(404)
      return
    let contentType =
      if name.endsWith(".png"): "image/png"
      elif name.endsWith(".ttf"): "font/ttf"
      else: "application/octet-stream"
    serveFile(request, dataDir() / name, contentType)

proc rendererHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    serveFile(
      request, clientDir() / "renderer.js",
      "application/javascript; charset=utf-8"
    )

proc chromeCssHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    serveFile(
      request, clientDir() / "chrome.css",
      "text/css; charset=utf-8"
    )

proc healthzHandler(request: Request) {.gcsafe.} =
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  request.respond(200, headers, """{"ok": true}""")

proc playerUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let slotText = request.queryParams["slot"]
    let token = request.queryParams["token"]
    var slot = -1
    try:
      slot = parseInt(slotText)
    except ValueError:
      discard
    var authorized = false
    withLock stateLock:
      authorized = slot >= 0 and slot < state.config.tokens.len and
        state.config.tokens[slot] == token
    if not authorized:
      request.respond(401)
      return
    withLock stateLock:
      if state.started or state.stopping or state.finished or slot in state.registeredSlots:
        request.respond(409)
        return
      let websocket = request.upgradeToWebSocket()
      state.registeredSlots.incl(slot)
      state.playerSockets[slot] = websocket
      state.socketSlots[websocket] = slot
      echo "babel: player slot ", slot, " connected (",
        state.playerSockets.len, "/", state.config.tokens.len, ")"
      websocket.send($ %*{
        "type": "welcome",
        "protocol": "babel.player.v3",
        "slot": slot,
        "name": state.sim.names[slot],
        "rounds": state.config.rounds
      })

proc globalUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      state.globalSockets.incl(websocket)
      websocket.send($state.snapshotJson())

proc replayUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    if replayPayloadGlobal.len > 0:
      websocket.send(replayPayloadGlobal)

proc websocketHandler(
  websocket: WebSocket,
  event: WebSocketEvent,
  message: Message
) {.gcsafe.} =
  {.gcsafe.}:
    case event
    of OpenEvent:
      discard
    of MessageEvent:
      let receivedAt = getMonoTime()
      ## mummy hands Ping frames to the application instead of answering
      ## them itself; the platform's certifier pings /global to check the
      ## game is alive, so an unanswered ping fails certification.
      if message.kind == Ping:
        websocket.send(message.data, Pong)
        return
      if message.kind != TextMessage:
        return
      var slot = -1
      withLock stateLock:
        slot = state.socketSlots.getOrDefault(websocket, -1)
      if slot < 0:
        return
      try:
        let payload = parseJson(message.data)
        let frameType = payload["type"].getStr()
        if frameType in ["attempt_started", "action"]:
          let id = payload["decision_id"].getStr()
          var evidence = newJNull()
          if payload["training_attempt"].kind != JNull:
            evidence = payload["training_attempt"]
            let attempt = readAttemptEvidence(evidence)
            if attempt.attemptId != id & "-model":
              raise newException(ValueError, "attempt identity differs from issued decision")
          withLock stateLock:
            if state.finished: return
            if not state.decisionSeats.hasKey(id) or state.decisionSeats[id] != slot:
              raise newException(ValueError, "decision does not belong to authenticated seat")
            if receivedAt < state.decisionIssuedAt[id]:
              raise newException(ValueError, "player frame preceded issued decision")
            if evidence.kind == JObject:
              if frameType == "action" and readAttemptEvidence(evidence).origin == aoModel and
                  not state.pendingAttempts.hasKey(id):
                raise newException(ValueError, "native completion has no recorded request start")
              if state.pendingAttempts.hasKey(id):
                for key in ["prompt", "request", "decoder", "policy"]:
                  if evidence[key] != state.pendingAttempts[id][key]:
                    raise newException(ValueError, "completion changed started request evidence")
              if frameType == "attempt_started":
                let attempt = readAttemptEvidence(evidence)
                if attempt.origin == aoModel:
                  let view = state.decisionObservations[id]
                  let emptyGuidance = promptMessages(view, "")
                  let prefix = "Your private observation:\n" & $view & "\nOperator guidance:\n"
                  let suffix = emptyGuidance[1]["content"].getStr()[prefix.len .. ^1]
                  let user = attempt.request["messages"][0]["content"].getStr()
                  if not user.startsWith(prefix) or not user.endsWith(suffix) or
                      user.len < prefix.len + suffix.len:
                    raise newException(ValueError, "native request differs from issued private observation")
                  let guidance = user[prefix.len ..< user.len - suffix.len]
                  let expected = promptMessages(view, guidance)
                  if attempt.prompt != expected or
                      attempt.request["system"] != expected[0]["content"] or
                      attempt.request["messages"] != %*[{"role": "user", "content": user}]:
                    raise newException(ValueError, "native prompt differs from production renderer")
                state.pendingAttempts[id] = evidence
              else:
                if state.completedAttempts.hasKey(id) and state.completedAttempts[id] != evidence:
                  raise newException(ValueError, "completion evidence is immutable")
                state.completedAttempts[id] = evidence
            if frameType == "action":
              let source = payload["source"].getStr()
              if source notin ["llm", "scripted", "fallback"]:
                raise newException(ValueError, "unknown action source")
              if source == "llm" and evidence.kind == JNull:
                raise newException(ValueError, "native action has no attempt evidence")
              if evidence.kind == JObject and source != "fallback":
                let attempt = readAttemptEvidence(evidence)
                if attempt.origin == aoModel:
                  if attempt.responseComplete != some(true) or
                      attempt.responseReaderJoined != some(true) or
                      attempt.httpStatus != some(200) or attempt.rejectionReason.isSome:
                    raise newException(ValueError, "native completion is not complete and joined")
                  let body = parseJson(attempt.rawResponse.getStr())
                  var text = ""
                  for contentBlock in body["content"]:
                    if contentBlock["type"].getStr() == "text": text.add(contentBlock["text"].getStr())
                  if attempt.response != %text or attempt.model != some(body["model"].getStr()):
                    raise newException(ValueError, "native body differs from completion response or model")
              state.pendingActions[id] = (payload: payload, receivedAt: receivedAt)
        elif frameType == "stopped":
          if payload["worker_status"].getStr() notin ["joined", "no_active_call"]:
            raise newException(ValueError, "unknown stopped worker status")
          if payload["attempts"].kind != JArray:
            raise newException(ValueError, "stop attempts must be an array")
          withLock stateLock:
            if state.finished: return
            let expected = if state.latestDecisions.hasKey(slot):
              %state.latestDecisions[slot] else: newJNull()
            if payload["decision_id"].kind != JNull:
              let id = payload["decision_id"].getStr()
              if not state.decisionSeats.hasKey(id) or state.decisionSeats[id] != slot:
                raise newException(ValueError, "stop acknowledgement belongs to another seat")
              for evidence in payload["attempts"]:
                let attempt = readAttemptEvidence(evidence)
                if attempt.attemptId != id & "-model":
                  raise newException(ValueError, "acknowledged attempt belongs to another decision")
                if receivedAt < state.decisionIssuedAt[id]:
                  raise newException(ValueError, "joined evidence preceded issued decision")
                if attempt.origin == aoModel and not state.pendingAttempts.hasKey(id):
                  raise newException(ValueError, "joined native evidence has no recorded request start")
                if state.pendingAttempts.hasKey(id):
                  for key in ["prompt", "request", "decoder", "policy"]:
                    if evidence[key] != state.pendingAttempts[id][key]:
                      raise newException(ValueError, "stop changed started request evidence")
                if state.completedAttempts.hasKey(id) and state.completedAttempts[id] != evidence:
                  raise newException(ValueError, "stop changed completed evidence")
                state.completedAttempts[id] = evidence
            elif payload["attempts"].len != 0:
              raise newException(ValueError, "no-active-call acknowledgement has attempt evidence")
            # Preserve genuine joined transport facts even when the player stops first.
            # They do not grant acknowledgement credit before this engine's stop window.
            if payload["decision_id"] != expected:
              raise newException(ValueError, "stop acknowledgement differs from latest decision")
            if not state.stopping:
              raise newException(ValueError, "stop acknowledgement preceded engine stop")
            if receivedAt < state.stopIssuedAt or receivedAt > state.acknowledgementDeadline:
              raise newException(ValueError, "stop acknowledgement is outside cleanup window")
            if not payload.hasKey("stop_id") or payload["stop_id"] != %state.stopId:
              raise newException(ValueError, "stop acknowledgement differs from engine stop identity")
            for evidence in payload["attempts"]:
              if readAttemptEvidence(evidence).responseReaderJoined == some(false):
                raise newException(ValueError, "stop retains an unjoined native response reader")
            state.stoppedSlots.incl(slot)
        else:
          raise newException(ValueError, "unknown player frame")
      except CatchableError as error:
        echo "babel: ignoring invalid player frame"
    of ErrorEvent:
      discard
    of CloseEvent:
      withLock stateLock:
        if websocket in state.socketSlots:
          let slot = state.socketSlots[websocket]
          # Parallel callbacks may dispatch an already-received final frame after close.
          # Keep its authenticated owner binding until this episode seals.
          if state.playerSockets.getOrDefault(slot) == websocket:
            state.playerSockets.del(slot)
        state.globalSockets.excl(websocket)

proc buildRouter(replayMode: bool): Router =
  result.get("/healthz", healthzHandler)
  result.get("/client/global", htmlHandler("global.html"))
  result.get("/client/player", htmlHandler("player.html"))
  result.get("/client/replay", htmlHandler("replay.html"))
  result.get("/client/renderer.js", rendererHandler)
  result.get("/client/chrome.css", chromeCssHandler)
  result.get("/client/assets/@name", assetHandler)
  result.get("/global", globalUpgradeHandler)
  result.get("/replay", replayUpgradeHandler)
  if not replayMode:
    result.get("/player", playerUpgradeHandler)

proc configFromReplay*(payload: JsonNode): GameConfig =
  result = defaultGameConfig()
  result.rounds = payload["config"]{"rounds"}.getInt(24)
  result.seed = payload["config"]{"seed"}.getInt(0)
  ## The replay carries the episode's fitted cap; never re-fit it. The
  ## alphabet and views it carries are re-derived from the seed.
  result.sampled = true
  for name in payload["names"]:
    result.players.add(PlayerConfig(name: name.getStr()))

proc runReplayServer*(runtimeConfig: RuntimeConfig) =
  ## Replay mode: parse the recorded replay, precompute the scrub states,
  ## and serve the viewer until the platform tears the container down.
  let payload = parseJson(runtimeConfig.replay)
  let config = configFromReplay(payload)
  var events: seq[GameEvent]
  for node in payload["events"]:
    events.add(eventFromJson(node))
  var enriched = %*{
    "type": "replay",
    "protocol": payload{"protocol"}.getStr("babel.replay.v1"),
    "names": payload["names"],
    "policyNames": payload{"policyNames"},
    "config": payload["config"],
    "events": payload["events"],
    "results": payload{"results"},
    "states": statesFromEvents(config, events)
  }
  replayPayloadGlobal = $enriched

  let router = buildRouter(replayMode = true)
  gameServer = newServer(router, websocketHandler, workerThreads = 4)
  echo "babel: replay mode on ", runtimeConfig.host, ":", runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)

proc runGameServer*(config: GameConfig, runtimeConfig: RuntimeConfig) =
  if config.tokens.len != config.players.len:
    raise newException(BabelError, "tokens and players must align")
  let episodeSeconds = getEnv("COWORLD_TIMEOUT_SECONDS", $config.episodeTimeoutSeconds).parseFloat()
  if classify(episodeSeconds) in {fcNan, fcInf, fcNegInf} or episodeSeconds <= 0:
    raise newException(ValueError, "episode timeout must be finite and positive")
  state.episodeTimeoutSeconds = episodeSeconds
  state.episodeDeadline = getMonoTime() + initDuration(milliseconds = int64(episodeSeconds * 1000))
  state.config = config
  state.sim = initSim(config)
  if getEnv(CogameSaveTrajectoryUriEnv).len > 0:
    state.trajectory = some(newDecisionTrajectory(getEnv("COWORLD_EPISODE_ID"),
      "babel-" & $config.seed, "babel", getEnv("COWORLD_GAME_VERSION"),
      getEnv("COWORLD_SOURCE_REVISION")))
  state.pendingActions.clear()
  state.pendingAttempts.clear()
  runtimeConfigGlobal = runtimeConfig

  let router = buildRouter(replayMode = false)
  installNativeStopHandlers()
  gameServer = newServer(router, websocketHandler, workerThreads = 4)
  var ownerCreated = false
  echo "babel: serving on ", runtimeConfig.host, ":", runtimeConfig.port
  try:
    gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host,
      onReady = proc(server: Server) {.gcsafe.} =
        {.gcsafe.}:
          createThread(gameThread, runGame, runtimeConfig)
          ownerCreated = true)
  finally:
    requestNativeStop()
    if ownerCreated: joinThread(gameThread)
    else:
      finishEpisode(runtimeConfig, esFailed)
