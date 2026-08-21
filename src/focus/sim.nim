## Pure game rules for Focus (Domination). No IO, no networking, no LLM —
## the server, the tests, and the wasm replay viewer all drive this same
## module.
##
## A `Sim` is one whole game: the 52-square board of piece stacks, each
## side's reserve and captures, whose turn it is, and the append-only event
## log. Focus has no hidden information and no randomness once the first
## mover is drawn, so a replay is exactly the recorded moves re-applied
## through these rules.

import std/[json, random, strutils], types

export types

const
  ## An episode's whole model-call allowance (one call per ply). A hosted
  ## episode is killed if it outlives the platform's artifact timeout, so
  ## `maxPlies` is capped to this at sample time.
  EpisodeCallBudget* = 240
  MinPlies* = 2
  ## Total spectator-pacing sleep an episode may spend, in milliseconds.
  PacingBudgetMs* = 120_000
  Seats* = 2
  PiecesPerSide* = 18
  StackCap* = 5
  Cells* = 64

type
  MoveKind* = enum
    mkMove = "move"
    mkPlace = "place"

  Move* = object
    kind*: MoveKind
    fromCell*: int   ## move: origin
    toCell*: int     ## destination
    count*: int      ## move: pieces carried (== squares travelled)
    dir*: Direction  ## move

  Sim* = object
    config*: GameConfig
    names*: seq[string]            ## anonymous table aliases per seat
    board*: array[Cells, seq[int]] ## owner per piece, bottom -> top
    reserve*: array[Seats, int]
    captured*: array[Seats, int]   ## enemy pieces this seat has taken
    first*: int                    ## seat that moved first
    turn*: int                     ## seat to move; -1 once done
    ply*: int                      ## plies played so far
    done*: bool
    winner*: int                   ## -1 for a draw (or while live)
    reason*: string                ## "no-moves" | "cap" | "deadline"
    events*: seq[GameEvent]

const CogNames* = [
  "Sprocket", "Gizmo", "Ratchet", "Widget", "Bolt",
  "Piston", "Flywheel", "Rivet", "Tinker", "Gasket"
]

# ---- Board geometry ---------------------------------------------------------

proc cellIndex*(file, rank: int): int = rank * 8 + file
proc fileOf*(cell: int): int = cell mod 8
proc rankOf*(cell: int): int = cell div 8

proc validCell*(cell: int): bool =
  ## The three squares in each corner of the 8x8 are not part of the board.
  if cell < 0 or cell >= Cells:
    return false
  let f = fileOf(cell)
  let r = rankOf(cell)
  let edgeF = f == 0 or f == 7
  let edgeR = r == 0 or r == 7
  if edgeF and edgeR:
    return false                    # the corner itself
  if edgeF and (r == 1 or r == 6):
    return false                    # beside the corner along the file
  if edgeR and (f == 1 or f == 6):
    return false                    # beside the corner along the rank
  true

proc cellName*(cell: int): string =
  if cell < 0:
    return "-"
  $chr(ord('a') + fileOf(cell)) & $(rankOf(cell) + 1)

proc parseCell*(text: string): int =
  ## "e4" -> cell index; raises on anything that is not a playable square.
  let t = text.strip().toLowerAscii()
  if t.len != 2 or t[0] < 'a' or t[0] > 'h' or t[1] < '1' or t[1] > '8':
    raise newException(FocusError, "bad square: " & text)
  result = cellIndex(ord(t[0]) - ord('a'), ord(t[1]) - ord('1'))
  if not validCell(result):
    raise newException(FocusError, "not a playable square: " & text)

proc step*(cell: int, dir: Direction, distance: int): int =
  ## The cell `distance` squares from `cell` in `dir`, or -1 off the board.
  var f = fileOf(cell)
  var r = rankOf(cell)
  case dir
  of dirN: r += distance
  of dirS: r -= distance
  of dirE: f += distance
  of dirW: f -= distance
  if f < 0 or f > 7 or r < 0 or r > 7:
    return -1
  result = cellIndex(f, r)
  if not validCell(result):
    result = -1

proc parseDirection*(text: string): Direction =
  case text.strip().toUpperAscii()
  of "N", "NORTH", "UP": dirN
  of "S", "SOUTH", "DOWN": dirS
  of "E", "EAST", "RIGHT": dirE
  of "W", "WEST", "LEFT": dirW
  else: raise newException(FocusError, "bad direction: " & text)

# ---- Setup ------------------------------------------------------------------

proc tableNames*(players: seq[PlayerConfig], seed: int): seq[string] =
  ## Policy display names never reach the table: every seat plays under an
  ## anonymous cog name, drawn deterministically from the seed so replays
  ## and the live table agree.
  var rng = initRand(int64(seed) * 6779 + 31)
  var pool = @CogNames
  rng.shuffle(pool)
  for index in 0 ..< players.len:
    if index < pool.len:
      result.add(pool[index])
    else:
      result.add("Cog " & $(index + 1))

proc sampleEpisode*(config: GameConfig): GameConfig =
  ## Fits the ply cap into one episode's call budget. Idempotent: a config
  ## that already carries the cap (a replay being re-read) is untouched.
  result = config
  if result.sampled:
    return
  result.maxPlies = max(min(config.maxPlies, EpisodeCallBudget), MinPlies)
  result.turnDelayMs =
    min(config.turnDelayMs, PacingBudgetMs div max(result.maxPlies, 1))
  result.sampled = true

proc addEvent(sim: var Sim, event: GameEvent) =
  var e = event
  e.ply = sim.ply
  sim.events.add(e)

proc initialBoard*(): array[Cells, seq[int]] =
  ## The 6x6 centre in alternating pairs: ranks 7/5/3 read R R G G R R,
  ## ranks 6/4/2 read G G R R G G (seat 0 = R, seat 1 = G): 18 each.
  for r in 1 .. 6:
    for f in 1 .. 6:
      let p = f - 1
      let outer = p in {0, 1, 4, 5}
      let owner =
        if r mod 2 == 0: (if outer: 0 else: 1)
        else: (if outer: 1 else: 0)
      result[cellIndex(f, r)] = @[owner]

proc initSim*(config: GameConfig): Sim =
  if config.players.len != Seats:
    raise newException(FocusError, "focus needs exactly " & $Seats & " players")
  result = Sim(config: config, names: tableNames(config.players, config.seed))
  result.board = initialBoard()
  result.first = ((config.seed mod Seats) + Seats) mod Seats
  result.turn = result.first
  result.winner = -1
  result.addEvent(GameEvent(kind: evStart, seat: result.first,
    fromCell: -1, toCell: -1, reserveAfter: -1,
    text: result.names[result.first]))

# ---- Queries ----------------------------------------------------------------

proc topOwner*(sim: Sim, cell: int): int =
  ## Owner of the top piece, or -1 for an empty square.
  if sim.board[cell].len == 0: -1 else: sim.board[cell][^1]

proc controls*(sim: Sim, seat, cell: int): bool =
  sim.topOwner(cell) == seat

proc controlledStacks*(sim: Sim, seat: int): int =
  for cell in 0 ..< Cells:
    if sim.controls(seat, cell):
      inc result

proc material*(sim: Sim, seat: int): int =
  ## Pieces in the stacks this seat controls, plus its reserve: what the
  ## seat can still put into play. Decides a capped or deadlined game.
  for cell in 0 ..< Cells:
    if sim.controls(seat, cell):
      result += sim.board[cell].len
  result += sim.reserve[seat]

proc ownPieces*(sim: Sim, seat: int): int =
  ## The seat's own pieces still anywhere on the board or in reserve.
  for cell in 0 ..< Cells:
    for owner in sim.board[cell]:
      if owner == seat:
        inc result
  result += sim.reserve[seat]

proc canMove*(sim: Sim, seat: int): bool =
  ## Any controlled stack has a legal move (every playable square has an
  ## on-board neighbour), and a reserve piece can always be placed.
  if sim.reserve[seat] > 0:
    return true
  for cell in 0 ..< Cells:
    if sim.controls(seat, cell):
      return true
  false

proc legalMoves*(sim: Sim, seat: int): seq[Move] =
  ## Every legal move for `seat`: for each controlled stack, every carry
  ## size in every direction that lands on the board; then every drop.
  for cell in 0 ..< Cells:
    if not sim.controls(seat, cell):
      continue
    let height = sim.board[cell].len
    for count in 1 .. height:
      for dir in Direction:
        let dest = step(cell, dir, count)
        if dest >= 0:
          result.add(Move(kind: mkMove, fromCell: cell, toCell: dest,
            count: count, dir: dir))
  if sim.reserve[seat] > 0:
    for cell in 0 ..< Cells:
      if validCell(cell):
        result.add(Move(kind: mkPlace, fromCell: -1, toCell: cell))

proc moveText*(move: Move): string =
  case move.kind
  of mkMove:
    cellName(move.fromCell) & " x" & $move.count & " " & $move.dir & " -> " &
      cellName(move.toCell)
  of mkPlace:
    "drop @ " & cellName(move.toCell)

# ---- Play -------------------------------------------------------------------

proc settle(sim: var Sim, reason: string) =
  ## Ends the game on material (cap / deadline).
  sim.done = true
  sim.reason = reason
  sim.turn = -1
  let a = sim.material(0)
  let b = sim.material(1)
  sim.winner = if a > b: 0 elif b > a: 1 else: -1
  sim.addEvent(GameEvent(kind: evEnd, seat: sim.winner, fromCell: -1,
    toCell: -1, reserveAfter: -1, text: reason))

proc afterPly(sim: var Sim) =
  ## Passes the turn and checks the end conditions.
  inc sim.ply
  let next = 1 - sim.turn
  if not sim.canMove(next):
    sim.done = true
    sim.reason = "no-moves"
    sim.winner = sim.turn
    sim.turn = -1
    sim.addEvent(GameEvent(kind: evEnd, seat: sim.winner, fromCell: -1,
      toCell: -1, reserveAfter: -1, text: "no-moves"))
    return
  sim.turn = next
  if sim.ply >= sim.config.maxPlies:
    sim.settle("cap")

proc overflow(sim: var Sim, seat, cell: int, captured, reserved: var int) =
  ## Strips the destination back down to the cap from the bottom: own
  ## pieces to the reserve, enemy pieces captured.
  while sim.board[cell].len > StackCap:
    let bottom = sim.board[cell][0]
    sim.board[cell].delete(0)
    if bottom == seat:
      inc sim.reserve[seat]
      inc reserved
    else:
      inc sim.captured[seat]
      inc captured

proc applyMove*(sim: var Sim, seat: int, move: Move) =
  ## One turn. Raises FocusError on anything illegal; the game server falls
  ## back to the scripted baseline on a rejection.
  if sim.done:
    raise newException(FocusError, "the game is over")
  if seat != sim.turn:
    raise newException(FocusError, "not this seat's turn")
  var captured = 0
  var reserved = 0
  case move.kind
  of mkMove:
    if move.fromCell < 0 or move.fromCell >= Cells or
        not validCell(move.fromCell):
      raise newException(FocusError, "no such square")
    if not sim.controls(seat, move.fromCell):
      raise newException(FocusError,
        "you do not control the stack on " & cellName(move.fromCell))
    let height = sim.board[move.fromCell].len
    if move.count < 1 or move.count > height:
      raise newException(FocusError,
        "can carry 1.." & $height & " pieces from " & cellName(move.fromCell))
    let dest = step(move.fromCell, move.dir, move.count)
    if dest < 0:
      raise newException(FocusError,
        $move.count & " " & $move.dir & " from " & cellName(move.fromCell) &
        " leaves the board")
    let carried = sim.board[move.fromCell][height - move.count ..< height]
    sim.board[move.fromCell].setLen(height - move.count)
    sim.board[dest].add(carried)
    sim.overflow(seat, dest, captured, reserved)
    sim.addEvent(GameEvent(kind: evMove, seat: seat,
      fromCell: move.fromCell, toCell: dest, count: move.count,
      dir: move.dir, carried: carried, stackAfter: sim.board[dest],
      captured: captured, reserved: reserved,
      reserveAfter: sim.reserve[seat]))
  of mkPlace:
    if sim.reserve[seat] <= 0:
      raise newException(FocusError, "no reserve piece to place")
    if move.toCell < 0 or move.toCell >= Cells or not validCell(move.toCell):
      raise newException(FocusError, "no such square")
    dec sim.reserve[seat]
    sim.board[move.toCell].add(seat)
    sim.overflow(seat, move.toCell, captured, reserved)
    sim.addEvent(GameEvent(kind: evPlace, seat: seat, fromCell: -1,
      toCell: move.toCell, stackAfter: sim.board[move.toCell],
      captured: captured, reserved: reserved,
      reserveAfter: sim.reserve[seat]))
  sim.afterPly()

proc recordSay*(sim: var Sim, seat: int, text: string) =
  if text.len == 0:
    return
  sim.addEvent(GameEvent(kind: evSay, seat: seat, fromCell: -1, toCell: -1,
    reserveAfter: -1, text: text))

proc endEarly*(sim: var Sim) =
  ## Stop now on material. The hosted platform kills an episode that
  ## outlives its timeout and keeps NOTHING, so a short honest game always
  ## beats a long one that never lands.
  if sim.done:
    return
  sim.settle("deadline")

# ---- Results ----------------------------------------------------------------

proc resultsJson*(sim: Sim): JsonNode =
  var names = newJArray()
  var scoresNode = newJArray()
  var winNode = newJArray()
  var materialNode = newJArray()
  var reserveNode = newJArray()
  var capturedNode = newJArray()
  var piecesNode = newJArray()
  for seat in 0 ..< Seats:
    ## Results are platform-facing: the league attributes scores by POLICY
    ## name, not by the anonymous alias the seat played under.
    names.add(%sim.config.players[seat].name)
    let score =
      if not sim.done: 0.0
      elif sim.winner < 0: 0.5
      elif sim.winner == seat: 1.0
      else: 0.0
    scoresNode.add(%score)
    winNode.add(%(sim.done and sim.winner == seat))
    materialNode.add(%sim.material(seat))
    reserveNode.add(%sim.reserve[seat])
    capturedNode.add(%sim.captured[seat])
    piecesNode.add(%sim.ownPieces(seat))
  %*{
    "names": names,
    "scores": scoresNode,
    "win": winNode,
    "material": materialNode,
    "reserve": reserveNode,
    "captured": capturedNode,
    "pieces": piecesNode,
    "plies": sim.ply,
    "maxPlies": sim.config.maxPlies,
    "first": sim.first,
    "reason": (if sim.done: sim.reason else: "")
  }

# ---- Viewer state -----------------------------------------------------------

proc boardJson*(sim: Sim): JsonNode =
  ## 64 entries (row-major, a1 first); unplayable and empty squares are [].
  result = newJArray()
  for cell in 0 ..< Cells:
    var stack = newJArray()
    for owner in sim.board[cell]:
      stack.add(%owner)
    result.add(stack)

proc lastMoveIndex(sim: Sim): int =
  for index in countdown(sim.events.high, 0):
    if sim.events[index].kind in {evMove, evPlace}:
      return index
  -1

proc tableStateJson*(sim: Sim): JsonNode =
  var seats = newJArray()
  for seat in 0 ..< Seats:
    seats.add(%*{
      "name": sim.names[seat],
      "reserve": sim.reserve[seat],
      "captured": sim.captured[seat],
      "material": sim.material(seat),
      "stacks": sim.controlledStacks(seat),
      "acting": seat == sim.turn
    })
  var last = newJNull()
  let lastAt = sim.lastMoveIndex()
  if lastAt >= 0:
    let event = sim.events[lastAt]
    last = %*{
      "kind": $event.kind,
      "seat": event.seat,
      "from": event.fromCell,
      "to": event.toCell,
      "count": event.count
    }
  %*{
    "seats": seats,
    "board": sim.boardJson(),
    "turn": sim.turn,
    "ply": sim.ply,
    "first": sim.first,
    "gameDone": sim.done,
    "winner": sim.winner,
    "reason": sim.reason,
    "lastMove": last
  }

# ---- Replay -----------------------------------------------------------------

proc replayMatch*(config: GameConfig, events: seq[GameEvent]): seq[Sim] =
  ## Re-derives the state timeline from a recorded event log by replaying
  ## the moves through the rules (Focus is deterministic). frames[i] =
  ## state after events[0..<i]; the replayed sim's own event log mirrors
  ## the prefix so lastMove and the feed line up.
  var sim = initSim(config)
  ## initSim already logged the start event; the recorded log's first
  ## event is that same start.
  sim.events = @[]
  result.add(sim)
  for event in events:
    case event.kind
    of evStart:
      sim.events.add(event)
    of evSay:
      sim.events.add(event)
    of evMove:
      sim.applyMove(event.seat, Move(kind: mkMove, fromCell: event.fromCell,
        toCell: event.toCell, count: event.count, dir: event.dir))
    of evPlace:
      sim.applyMove(event.seat, Move(kind: mkPlace, fromCell: -1,
        toCell: event.toCell))
    of evEnd:
      if not sim.done:
        ## A deadline stop is not derivable from the moves alone.
        sim.settle(event.text)
    result.add(sim)

# ---- Event JSON -------------------------------------------------------------

proc eventToJson*(event: GameEvent): JsonNode =
  result = %*{
    "kind": $event.kind,
    "ply": event.ply,
    "seat": event.seat
  }
  if event.fromCell >= 0:
    result["from"] = %event.fromCell
  if event.toCell >= 0:
    result["to"] = %event.toCell
  if event.kind == evMove:
    result["count"] = %event.count
    result["dir"] = %($event.dir)
    var carried = newJArray()
    for owner in event.carried:
      carried.add(%owner)
    result["carried"] = carried
  if event.kind in {evMove, evPlace}:
    var stack = newJArray()
    for owner in event.stackAfter:
      stack.add(%owner)
    result["stack"] = stack
    if event.captured > 0:
      result["captured"] = %event.captured
    if event.reserved > 0:
      result["reserved"] = %event.reserved
  if event.reserveAfter >= 0:
    result["reserveAfter"] = %event.reserveAfter
  if event.text.len > 0:
    result["text"] = %event.text

proc eventFromJson*(node: JsonNode): GameEvent =
  result = GameEvent(
    kind: parseEnum[EventKind](node["kind"].getStr()),
    ply: node{"ply"}.getInt(0),
    seat: node{"seat"}.getInt(-1),
    fromCell: node{"from"}.getInt(-1),
    toCell: node{"to"}.getInt(-1),
    count: node{"count"}.getInt(0),
    captured: node{"captured"}.getInt(0),
    reserved: node{"reserved"}.getInt(0),
    reserveAfter: node{"reserveAfter"}.getInt(-1),
    text: node{"text"}.getStr("")
  )
  if node.hasKey("dir"):
    result.dir = parseEnum[Direction](node["dir"].getStr())
  if node.hasKey("carried"):
    for owner in node["carried"]:
      result.carried.add(owner.getInt())
  if node.hasKey("stack"):
    for owner in node["stack"]:
      result.stackAfter.add(owner.getInt())
