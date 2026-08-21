import std/[json, strutils]

type
  FocusError* = object of CatchableError

  PlayerConfig* = object
    name*: string

  GameConfig* = object
    tokens*: seq[string]
    players*: seq[PlayerConfig]
    seed*: int
    maxPlies*: int        ## ply cap for the episode (material decides)
    episodeTimeoutSeconds*: int ## assumed platform kill time when the env is silent
    sampled*: bool        ## true once the budget cap has been applied
    turnDelayMs*: int
    playerConnectTimeoutSeconds*: float
    model*: string
    maxOutputTokens*: int
    llmTimeoutSeconds*: int

  Direction* = enum
    dirN = "N"
    dirS = "S"
    dirE = "E"
    dirW = "W"

  EventKind* = enum
    evStart = "start"
    evSay = "say"
    evMove = "move"
    evPlace = "place"
    evEnd = "end"

  GameEvent* = object
    kind*: EventKind
    ply*: int           ## 0-based ply the event belongs to
    seat*: int          ## acting seat; -1 for end
    fromCell*: int      ## move: origin cell (0..63); -1 otherwise
    toCell*: int        ## move/place: destination cell; -1 otherwise
    count*: int         ## move: pieces carried
    dir*: Direction     ## move only
    carried*: seq[int]  ## move: owners of the carried pieces, bottom->top
    stackAfter*: seq[int] ## move/place: destination stack after, bottom->top
    captured*: int      ## enemy pieces stripped off the bottom
    reserved*: int      ## own pieces stripped to the reserve
    reserveAfter*: int  ## actor's reserve after the event; -1 otherwise
    text*: string       ## say text; end reason; start: first seat alias

proc defaultGameConfig*(): GameConfig =
  GameConfig(
    seed: 0,
    maxPlies: 120,
    episodeTimeoutSeconds: 1200,
    turnDelayMs: 300,
    playerConnectTimeoutSeconds: 180,
    model: "claude-sonnet-5",
    maxOutputTokens: 400,
    llmTimeoutSeconds: 45
  )

proc update*(config: var GameConfig, configJson: string) =
  ## Applies a runtime JSON config on top of the defaults.
  if configJson.strip().len == 0:
    return
  let node = parseJson(configJson)
  if node.kind != JObject:
    raise newException(FocusError, "config must be a JSON object")
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
  if node.hasKey("maxPlies"):
    config.maxPlies = node["maxPlies"].getInt()
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
  if config.maxPlies < 2:
    raise newException(FocusError, "maxPlies must be at least 2")
