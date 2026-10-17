## Game-owned wording selection. Kept outside simulation/replay configuration.
import std/[json, strutils]
import crunchy

type
  PromptVariant* = enum
    pvCanonical = "canonical"
    pvPlain = "plain"
    pvNumbered = "numbered"
    pvQuestions = "questions"
    pvReordered = "reordered"
    pvHeldoutBriefing = "heldout-briefing"
    pvHeldoutReference = "heldout-reference"
    pvMixed = "mixed"
  PromptSelection* = object
    variant*: PromptVariant
    seed*: int

const PromptBankVersion* = "babel-rules-v1"

proc promptSelection*(node: JsonNode): PromptSelection =
  if node.kind != JObject:
    raise newException(ValueError, "prompt configuration must be an object")
  if node.hasKey("promptVariant"):
    if node["promptVariant"].kind != JString:
      raise newException(ValueError, "promptVariant must be a string")
    result.variant = parseEnum[PromptVariant](node["promptVariant"].getStr())
  if node.hasKey("promptSeed"):
    if node["promptSeed"].kind != JInt:
      raise newException(ValueError, "promptSeed must be an integer")
    result.seed = node["promptSeed"].getInt()
  if result.seed < 0:
    raise newException(ValueError, "promptSeed must be nonnegative")
  if result.variant == pvMixed and not node.hasKey("promptSeed"):
    raise newException(ValueError, "mixed wording requires an explicit promptSeed")

proc selectedVariant*(selection: PromptSelection): PromptVariant =
  if selection.variant == pvMixed: PromptVariant(selection.seed mod 5)
  else: selection.variant

proc promptMetadata*(selection: PromptSelection, system, user: string): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed,
    "system_sha256": sha256(system).toHex, "user_sha256": sha256(user).toHex}

const CanonicalSystemPrompt* = "You play Babel. Each speaker sends 1 to 8 glyphs from its " &
  "private alphabet. Each listener picks one of four scenes. Partners see " &
  "the same tokens under different glyphs. Learn a convention from your " &
  "own feedback. Reply with one JSON action and optional private notes."

const Templates = [
  "You are playing Babel. A speaker sends between 1 and 8 glyphs from their private alphabet. " &
    "A listener selects one of four scenes. Partners see identical tokens represented by different glyphs. " &
    "Use your own feedback to learn a convention. Return one JSON action; private notes are optional.",
  "Babel rules:\n1. Speakers send 1 to 8 glyphs from their own private alphabet.\n" &
    "2. Listeners select one of four scenes.\n3. Partners see the same tokens through different glyphs.\n" &
    "4. Learn a convention using your own feedback.\n5. Reply with one JSON action and optional private notes.",
  "You play Babel. What does a speaker send? 1 to 8 glyphs from their private alphabet. " &
    "What does a listener choose? One of four scenes. How do partners see tokens? " &
    "The same tokens appear as different glyphs. How do you learn a convention? From your own feedback. " &
    "How do you respond? One JSON action, optionally including private notes.",
  "Reply with one JSON action and optional private notes. You play Babel. " &
    "Learn a convention from your own feedback. Partners see the same tokens under different glyphs. " &
    "Each listener picks one of four scenes. Each speaker sends 1 to 8 glyphs from its private alphabet.",
  "Babel briefing: communicate as speaker with 1 to 8 glyphs drawn from your private alphabet; " &
    "as listener, pick one of four scenes. Tokens are shared between partners but their visible glyphs differ. " &
    "Develop a convention from your own feedback. Your response is one JSON action, with private notes if desired.",
  "Babel reference. Speaker output: 1 to 8 glyphs from the speaker's private alphabet. " &
    "Listener choice: one of four scenes. Partner representation: the same tokens, different glyphs. " &
    "Learning: form a convention from your own feedback. Response: one JSON action with optional private notes."
]

proc systemPrompt*(selection: PromptSelection): string =
  if selection.selectedVariant == pvCanonical: CanonicalSystemPrompt
  else: Templates[ord(selection.selectedVariant) - 1]

proc selectionJson*(selection: PromptSelection): JsonNode =
  %*{"promptVariant": $selection.variant, "promptSeed": selection.seed}

proc selectionMetadata*(selection: PromptSelection): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed}
