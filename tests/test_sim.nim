import std/[json, unittest]
import focus/sim

proc fixtureConfig(maxPlies = 160, seed = 0): GameConfig =
  result = defaultGameConfig()
  result.maxPlies = maxPlies
  result.seed = seed
  ## Pinned, so these tests exercise the rules rather than the budget cap.
  result.sampled = true
  for index in 0 ..< 2:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("token-" & $index)

proc c(name: string): int = parseCell(name)

proc mv(sim: var Sim, fromName: string, count: int, dir: Direction) =
  sim.applyMove(sim.turn, Move(kind: mkMove, fromCell: c(fromName),
    count: count, dir: dir))

proc drop(sim: var Sim, name: string) =
  sim.applyMove(sim.turn, Move(kind: mkPlace, fromCell: -1, toCell: c(name)))

proc totalPieces(sim: Sim): int =
  for cell in 0 ..< Cells:
    result += sim.board[cell].len
  result += sim.reserve[0] + sim.reserve[1] + sim.captured[0] +
    sim.captured[1]

suite "board geometry":
  test "52 playable squares, three per corner removed":
    var playable = 0
    for cell in 0 ..< Cells:
      if validCell(cell):
        inc playable
    check playable == 52
    for name in ["a1", "b1", "a2", "g1", "h1", "h2", "a8", "b8", "a7",
        "g8", "h8", "h7"]:
      expect FocusError:
        discard parseCell(name)
    for name in ["c1", "a3", "a6", "h3", "h6", "c8", "f8", "d4"]:
      check validCell(parseCell(name))

  test "cell names round-trip":
    check cellName(parseCell("e4")) == "e4"
    check cellName(parseCell("h5")) == "h5"
    check step(parseCell("e4"), dirN, 2) == parseCell("e6")
    check step(parseCell("e4"), dirW, 4) == parseCell("a4")
    check step(parseCell("e4"), dirW, 5) == -1
    check step(parseCell("b2"), dirW, 1) == -1   # a2 is off the board

  test "every playable square has an on-board neighbour":
    for cell in 0 ..< Cells:
      if not validCell(cell):
        continue
      var any = false
      for dir in Direction:
        if step(cell, dir, 1) >= 0:
          any = true
      check any

suite "setup":
  test "18 pieces each in the alternating-pair pattern":
    let sim = initSim(fixtureConfig())
    check sim.ownPieces(0) == 18
    check sim.ownPieces(1) == 18
    check sim.totalPieces() == 36
    ## Rank 7 reads R R G G R R; rank 6 reads G G R R G G.
    check sim.topOwner(c("b7")) == 0
    check sim.topOwner(c("d7")) == 1
    check sim.topOwner(c("g7")) == 0
    check sim.topOwner(c("b6")) == 1
    check sim.topOwner(c("d6")) == 0
    check sim.topOwner(c("g2")) == 1
    check sim.topOwner(c("a4")) == -1
    check sim.events.len == 1
    check sim.events[0].kind == evStart

  test "the seed picks the first mover and the aliases":
    check initSim(fixtureConfig(seed = 0)).first == 0
    check initSim(fixtureConfig(seed = 1)).first == 1
    check initSim(fixtureConfig(seed = 7)).turn == 1
    check initSim(fixtureConfig(seed = 3)).names !=
      initSim(fixtureConfig(seed = 4)).names

suite "movement":
  test "a single piece moves one square and stacks":
    var sim = initSim(fixtureConfig(seed = 0))
    ## Seat 0 controls b7; move it east onto c7 (also seat 0).
    sim.mv("b7", 1, dirE)
    check sim.board[c("b7")].len == 0
    check sim.board[c("c7")] == @[0, 0]
    check sim.turn == 1
    check sim.ply == 1
    check sim.events[^1].kind == evMove
    check sim.events[^1].carried == @[0]

  test "moving onto an enemy piece takes control":
    var sim = initSim(fixtureConfig(seed = 0))
    sim.mv("c7", 1, dirE)         # onto d7 (seat 1) -> [1,0]
    check sim.board[c("d7")] == @[1, 0]
    check sim.controls(0, c("d7"))
    check sim.material(0) == 18 + 1
    check sim.material(1) == 17

  test "a stack moves as many squares as pieces carried, over anything":
    var sim = initSim(fixtureConfig(seed = 0))
    sim.mv("c7", 1, dirE)         # d7 = [1,0], seat 0 controls
    sim.mv("b6", 1, dirN)         # seat 1: b6 -> b7 (empty now)
    ## Seat 0: carry both from d7 two squares east, jumping e7, onto f7.
    sim.mv("d7", 2, dirE)
    check sim.board[c("d7")].len == 0
    check sim.board[c("f7")] == @[0, 1, 0]
    ## Partial carry: take only the top piece one square.
    sim.mv("b7", 1, dirE)         # seat 1: b7 -> c7
    sim.mv("f7", 1, dirS)         # seat 0: top of f7 -> f6
    check sim.board[c("f7")] == @[0, 1]
    check sim.board[c("f6")] == @[1, 0]

  test "illegal moves are rejected and change nothing":
    var sim = initSim(fixtureConfig(seed = 0))
    let before = sim.board
    expect FocusError:
      sim.mv("b6", 1, dirN)       # seat 1's stack, seat 0 to move
    expect FocusError:
      sim.mv("b7", 2, dirE)       # only one piece there
    expect FocusError:
      sim.mv("b7", 1, dirW)       # a7 is off the board
    expect FocusError:
      sim.applyMove(1, Move(kind: mkMove, fromCell: c("b6"), count: 1,
        dir: dirN))               # not seat 1's turn
    expect FocusError:
      sim.drop("d4")              # no reserve
    check sim.board == before
    check sim.ply == 0

suite "the cap":
  test "overflow strips the bottom: own to reserve, enemy captured":
    var sim = initSim(fixtureConfig(seed = 0))
    ## Build a tall stack on e4 by hand, then land on it.
    sim.board[c("e4")] = @[1, 0, 1, 1]
    sim.board[c("e6")] = @[0, 0]
    sim.mv("e6", 2, dirS)         # e4 becomes [1,0,1,1,0,0] -> cap 5
    check sim.board[c("e4")] == @[0, 1, 1, 0, 0]
    check sim.captured[0] == 1
    check sim.reserve[0] == 0
    check sim.events[^1].captured == 1
    check sim.events[^1].reserved == 0
    ## Now seat 1 lands one piece on it: [0,1,1,0,0,1] -> strips a 0.
    sim.board[c("e5")] = @[1]
    sim.mv("e5", 1, dirS)
    check sim.board[c("e4")] == @[1, 1, 0, 0, 1]
    check sim.captured[1] == 1
    ## And a further landing that strips its own piece goes to reserve.
    sim.board[c("e2")] = @[0, 0]
    sim.mv("e2", 2, dirN)         # seat 0: [1,1,0,0,1,0,0] -> strip 1,1
    check sim.board[c("e4")] == @[0, 0, 1, 0, 0]
    check sim.captured[0] == 3
    sim.board[c("e8")] = @[1, 1]
    sim.mv("e8", 2, dirS)         # seat 1 lands from e8? e8-2 = e6
    check sim.board[c("e6")] == @[1, 1]
    sim.board[c("e5")] = @[0, 0]
    sim.mv("e5", 1, dirS)         # seat 0: e4 = [0,0,1,0,0,0] -> strip own 0
    check sim.reserve[0] == 1
    check sim.events[^1].reserved == 1

suite "reserve":
  test "a reserve piece may be dropped anywhere, on top":
    var sim = initSim(fixtureConfig(seed = 0))
    sim.reserve[0] = 2
    sim.drop("a4")                # empty tab square
    check sim.board[c("a4")] == @[0]
    check sim.reserve[0] == 1
    check sim.events[^1].kind == evPlace
    check sim.events[^1].reserveAfter == 1
    sim.mv("b6", 1, dirW)         # seat 1: b6 -> a6
    sim.drop("d7")                # on top of an enemy piece
    check sim.board[c("d7")] == @[1, 0]
    check sim.reserve[0] == 0
    expect FocusError:
      sim.drop("h1")              # unplayable

  test "legal move enumeration matches the rules":
    var sim = initSim(fixtureConfig(seed = 0))
    let moves = sim.legalMoves(0)
    ## 18 singleton stacks, each with up to four one-square moves.
    var count = 0
    for cell in 0 ..< Cells:
      if sim.controls(0, cell):
        for dir in Direction:
          if step(cell, dir, 1) >= 0:
            inc count
    check moves.len == count
    for move in moves:
      var probe = sim
      probe.applyMove(0, move)     # every enumerated move is legal
    sim.reserve[0] = 1
    check sim.legalMoves(0).len == count + 52

suite "endings":
  test "a player with no controlled stack and no reserve loses":
    var sim = initSim(fixtureConfig(seed = 0))
    ## Wipe seat 1 off the board except one piece under a seat-0 piece.
    for cell in 0 ..< Cells:
      sim.board[cell] = @[]
    sim.board[c("d4")] = @[1]
    sim.board[c("b4")] = @[0]
    sim.board[c("f4")] = @[0]
    check sim.canMove(1)
    sim.mv("b4", 1, dirE)         # seat 0: b4 -> c4
    check not sim.done
    sim.mv("d4", 1, dirN)         # seat 1: d4 -> d5
    sim.mv("c4", 1, dirN)         # seat 0: c4 -> c5
    sim.mv("d5", 1, dirW)         # seat 1: d5 -> c5 = [0,1], seat 1 controls
    sim.mv("f4", 1, dirN)         # seat 0: f4 -> f5
    check not sim.done
    sim.mv("c5", 2, dirE)         # seat 1: c5 [0,1] -> e5
    sim.mv("f5", 1, dirW)         # seat 0: f5 -> e5 = [0,1,0]: seat 1 buried
    check sim.done
    check sim.winner == 0
    check sim.reason == "no-moves"
    check sim.turn == -1
    check sim.events[^1].kind == evEnd
    let results = sim.resultsJson()
    check results["scores"][0].getFloat() == 1.0
    check results["scores"][1].getFloat() == 0.0
    check results["win"][0].getBool()
    expect FocusError:
      sim.mv("e5", 1, dirN)

  test "the ply cap settles on material":
    var sim = initSim(fixtureConfig(maxPlies = 2, seed = 0))
    sim.mv("c7", 1, dirE)         # seat 0 takes d7: material 19 vs 17
    check not sim.done
    sim.mv("b6", 1, dirW)         # seat 1 to the a6 tab; ply 2 -> cap
    check sim.done
    check sim.reason == "cap"
    check sim.winner == 0
    var drawn = initSim(fixtureConfig(maxPlies = 2, seed = 0))
    drawn.mv("b7", 1, dirE)       # own on own: 18 vs 18
    drawn.mv("b6", 1, dirW)
    check drawn.done
    check drawn.winner == -1
    let results = drawn.resultsJson()
    check results["scores"][0].getFloat() == 0.5
    check results["scores"][1].getFloat() == 0.5
    check not results["win"][0].getBool()

  test "endEarly settles a live game on material":
    var sim = initSim(fixtureConfig(seed = 0))
    sim.mv("c7", 1, dirE)
    sim.endEarly()
    check sim.done
    check sim.reason == "deadline"
    check sim.winner == 0
    sim.endEarly()                # idempotent
    check sim.events[^1].kind == evEnd

suite "replay":
  test "re-deriving frames from the event log reproduces the game":
    var sim = initSim(fixtureConfig(maxPlies = 6, seed = 5))
    sim.recordSay(sim.turn, "hello")
    var rng = 11
    while not sim.done:
      let moves = sim.legalMoves(sim.turn)
      rng = (rng * 1103515245 + 12345) mod 2147483648
      sim.applyMove(sim.turn, moves[rng mod moves.len])
    var events: seq[GameEvent]
    for event in sim.events:
      events.add(eventFromJson(event.eventToJson()))
    let frames = replayMatch(sim.config, events)
    check frames.len == events.len + 1
    check frames[^1].board == sim.board
    check frames[^1].done
    check frames[^1].winner == sim.winner
    check frames[^1].reason == sim.reason
    check frames[^1].reserve == sim.reserve
    check frames[^1].captured == sim.captured
    check $frames[^1].tableStateJson() == $sim.tableStateJson()
    check frames[0].ply == 0
    ## Piece conservation across every frame.
    for frame in frames:
      check frame.totalPieces() == 36

  test "event JSON round-trips":
    var sim = initSim(fixtureConfig(seed = 0))
    sim.mv("c7", 1, dirE)
    let event = sim.events[^1]
    let back = eventFromJson(event.eventToJson())
    check back.kind == evMove
    check back.fromCell == event.fromCell
    check back.toCell == event.toCell
    check back.count == 1
    check back.dir == dirE
    check back.carried == @[0]
    check back.stackAfter == @[1, 0]
    check back.reserveAfter == 0
