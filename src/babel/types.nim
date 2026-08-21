import std/[json, strutils]

type
  BabelError* = object of CatchableError

  PlayerConfig* = object
    name*: string

  GameConfig* = object
    tokens*: seq[string]
    players*: seq[PlayerConfig]
    seed*: int
    rounds*: int          ## rounds in the episode (every seat plays every round)
    episodeTimeoutSeconds*: int ## assumed platform kill time when the env is silent
    sampled*: bool        ## true once the budget cap has been applied
    turnDelayMs*: int
    playerConnectTimeoutSeconds*: float
    model*: string
    maxOutputTokens*: int
    llmTimeoutSeconds*: int

  Scene* = object
    shape*: int   ## 0..3: circle, square, triangle, star
    colour*: int  ## 0..3: red, blue, green, yellow
    count*: int   ## 0..3 meaning 1..4 copies

  EventKind* = enum
    evStart = "start"
    evRound = "round"
    evSpeak = "speak"
    evPick = "pick"
    evEnd = "end"

  GameEvent* = object
    kind*: EventKind
    round*: int          ## 0-based round; end: rounds played; start: -1
    pair*: int           ## speak/pick: 0 or 1; -1 otherwise
    seat*: int           ## speak: speaker; pick: listener; -1 otherwise
    other*: int          ## speak: listener; pick: speaker; -1 otherwise
    tokens*: seq[int]    ## speak: the message, token ids 0..15
    pick*: int           ## pick: 0..3 (A-D); -1 otherwise
    correct*: bool       ## pick: the listener chose the target
    scripted*: bool      ## speak/pick: decided by the scripted baseline
    text*: string        ## speak/pick: the actor's notes after the reply; end: reason
    speakers*: seq[int]  ## round: speaker per pair
    listeners*: seq[int] ## round: listener per pair
    targets*: seq[int]   ## round: target scene id per pair
    lineups*: seq[seq[int]] ## round: the four candidate scene ids per pair

proc defaultGameConfig*(): GameConfig =
  GameConfig(
    seed: 0,
    rounds: 24,
    episodeTimeoutSeconds: 1200,
    turnDelayMs: 300,
    playerConnectTimeoutSeconds: 180,
    model: "claude-sonnet-5",
    maxOutputTokens: 900,
    llmTimeoutSeconds: 45
  )

proc update*(config: var GameConfig, configJson: string) =
  ## Applies a runtime JSON config on top of the defaults.
  if configJson.strip().len == 0:
    return
  let node = parseJson(configJson)
  if node.kind != JObject:
    raise newException(BabelError, "config must be a JSON object")
  if node.hasKey("tokens"):
    config.tokens = @[]
    for token in node["tokens"]:
      config.tokens.add(token.getStr())
  if node.hasKey("players"):
    config.players = @[]
    for player in node["players"]:
      config.players.add(PlayerConfig(name: player["name"].getStr()))
  if node.hasKey("seed"):
    config.seed = node["seed"].getInt()
  if node.hasKey("rounds"):
    config.rounds = node["rounds"].getInt()
  if node.hasKey("episodeTimeoutSeconds"):
    config.episodeTimeoutSeconds = node["episodeTimeoutSeconds"].getInt()
  if node.hasKey("sampled"):
    config.sampled = node["sampled"].getBool()
  if node.hasKey("turnDelayMs"):
    config.turnDelayMs = node["turnDelayMs"].getInt()
  if node.hasKey("player_connect_timeout_seconds"):
    config.playerConnectTimeoutSeconds =
      node["player_connect_timeout_seconds"].getFloat()
  if node.hasKey("model"):
    config.model = node["model"].getStr()
  if node.hasKey("maxOutputTokens"):
    config.maxOutputTokens = node["maxOutputTokens"].getInt()
  if node.hasKey("llmTimeoutSeconds"):
    config.llmTimeoutSeconds = node["llmTimeoutSeconds"].getInt()
  if config.rounds < 2:
    raise newException(BabelError, "rounds must be at least 2")
