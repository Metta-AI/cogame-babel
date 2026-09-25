## Jev ranks ordinary speaker glyphs or listener picks from one private view.

import std/[json, os, strutils]
import curly
import sim

proc jevConfigured*(): bool =
  getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip().len > 0 or
    (getEnv("METTA_CAPTURE_URL").strip().len > 0 and
      getEnv("METTA_CAPTURE_KEY").strip().len > 0) or
    getEnv("TYPESAFE_API_KEY").strip().len > 0

proc bestChoice(answer, criteria: JsonNode): string =
  if answer["type"].getStr() != "choice":
    raise newException(BabelError, "Jev returned a non-choice answer")
  let probabilities = answer["probabilities"]
  if probabilities.len != criteria.len:
    raise newException(BabelError, "Jev returned the wrong choice set")
  var best = -1.0
  var total = 0.0
  for choice, probability in probabilities.pairs:
    if not criteria.hasKey(choice):
      raise newException(BabelError, "Jev returned an unknown choice")
    let value = probability.getFloat()
    if value < 0 or value > 1:
      raise newException(BabelError, "Jev probability outside [0, 1]")
    total += value
    if value > best:
      best = value
      result = choice
  if abs(total - 1) > probabilities.len.float * 0.005 + 1e-6:
    raise newException(BabelError, "Jev probabilities do not sum to one")

proc chooseJevAction*(view: JsonNode): JsonNode =
  var questions = newJObject()
  let speaker = view["role"].getStr() == "speaker"
  if speaker:
    var lengthChoices = newJObject()
    for length in 1 .. MaxMessage:
      lengthChoices[$length] = %($length & " glyphs")
    questions["length"] = %*{
      "type": "choice", "instructions": "How many glyphs should this " &
        "speaker send? Choose 1 to 8.", "criteria": lengthChoices}
    var glyphChoices = newJObject()
    for index in 0 ..< view["alphabet"].len:
      glyphChoices[$index] = view["alphabet"][index]
    for position in 0 ..< MaxMessage:
      questions["glyph_" & $position] = %*{
        "type": "choice",
        "instructions": "Choose glyph position " & $(position + 1) &
          " if the message uses it. Each choice is one of this seat's " &
          "16 visible glyphs.",
        "criteria": glyphChoices}
  else:
    var picks = newJObject()
    for index in 0 ..< view["lineup"].len:
      picks[$index] = %sceneText(view["lineup"][index].getInt())
    questions["pick"] = %*{
      "type": "choice", "instructions": "Choose the target scene from " &
        "the listener's four visible candidates.", "criteria": picks}
  let notes = %*{
    "keep": view["notes"].getStr(),
    "clear": "",
    "remember": "Remember the glyph meanings inferred from feedback."
  }
  questions["notes"] = %*{
    "type": "choice", "instructions": "Choose private notes for your " &
      "next turn.", "criteria": notes}

  let sidecar = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let capture = getEnv("METTA_CAPTURE_URL").strip()
  let endpoint =
    if sidecar.len > 0: sidecar
    elif capture.len > 0: capture
    else: getEnv("TYPESAFE_BASE_URL", "https://api.typesafe.ai")
  let model =
    if sidecar.len > 0: "typesafe/jev-1.13"
    elif capture.len > 0: getEnv("METTA_CAPTURE_MODEL", "jev-latest")
    else: getEnv("TYPESAFE_DEFAULT_MODEL", "jev-latest")
  let key =
    if sidecar.len > 0: ""
    elif capture.len > 0: getEnv("METTA_CAPTURE_KEY").strip()
    else: getEnv("TYPESAFE_API_KEY").strip()
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if key.len > 0:
    headers["authorization"] = "Bearer " & key
  else:
    headers["x-coworld-player-slot"] = $view["slot"].getInt()
  let body = %*{
    "model": model,
    "state": "You play Babel. The speaker sends 1 to 8 glyphs; the listener " &
      "picks one of four scenes. Each seat sees token glyphs in its own " &
      "alphabet. Infer meaning only from this seat's feedback. Here is the " &
      "private observation:\n" & $view,
    "questions": questions
  }
  let response = newCurly().post(endpoint.strip(chars = {'/'},
    leading = false) & "/v1/systemone", headers, $body, 30)
  if response.code < 200 or response.code >= 300:
    raise newException(BabelError, "Jev HTTP " & $response.code)
  let payload = parseJson(response.body)
  let answers = payload["answers"]
  let noteChoice = bestChoice(answers["notes"], notes)
  if speaker:
    let length = parseInt(bestChoice(answers["length"],
      questions["length"]["criteria"]))
    var tokens = newJArray()
    for position in 0 ..< length:
      let name = "glyph_" & $position
      let choice = bestChoice(answers[name], questions[name]["criteria"])
      tokens.add(view["alphabet"][parseInt(choice)])
    return %*{"tokens": tokens, "notes": notes[noteChoice]}
  let pick = bestChoice(answers["pick"], questions["pick"]["criteria"])
  %*{"pick": parseInt(pick), "notes": notes[noteChoice]}
