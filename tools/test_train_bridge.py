"""Play complete matches through numeric and production language actions."""

import json
import random
import subprocess
import sys
from pathlib import Path


def play(binary: Path, teacher: bool, language: bool, invalid: str | None = None) -> None:
    manifest = Path(__file__).resolve().parent.parent / "coworld_manifest_template.json"
    process = subprocess.Popen(
        [str(binary), str(manifest), *(["--language"] if language else [])],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    assert process.stdin is not None and process.stdout is not None
    rng = random.Random(17)

    def request(payload: dict) -> dict:
        process.stdin.write(json.dumps(payload) + "\n")
        process.stdin.flush()
        return json.loads(process.stdout.readline())

    try:
        observation = request({"kind": "reset", "seed": f"babel-{teacher}", "players": 4})
        widths = set()
        decisions = 0
        notes = {}
        while observation["kind"] == "decision":
            assert observation["inference_mode"] == ("text_action" if language else None)
            if invalid is not None and decisions == 0:
                rejected = request({"kind": "step", "decision_id": observation["decision_id"], "response": invalid})
                assert rejected["kind"] == "consumed_rejection" and rejected["reason"]
                assert all(glyph in observation["semantic_view"]["alphabet"] for glyph in rejected["action"]["tokens"])
                observation = rejected["observation"]
                decisions += 1
                continue
            encoding = request({"kind": "encode"})
            assert encoding["decision_id"] == observation["decision_id"]
            widths.add(len(encoding["values"]))
            heads = encoding["action_heads"]
            assert [len(head["choices"]) for head in heads] == [8] + [16] * 8 + [4]
            if not language:
                for head in heads:
                    assert observation["action_schema"]["properties"][head["name"]]["enum"] == head["choices"]
            view = observation["semantic_view"]
            if view["role"] == "speaker":
                assert view["target"] in range(64)
                assert "lineup" not in view and "message" not in view
            else:
                assert "target" not in view and "target_scene" not in view
                assert len(view["lineup"]) == 4
                assert 1 <= len(view["message"]) <= 8
            if language:
                properties = observation["action_schema"]["properties"]
                assert set(properties) == {"notes", "tokens" if view["role"] == "speaker" else "pick"}
                user = observation["messages"][1]["content"]
                assert "Build a shared glyph code from feedback." in user
                seat = observation["seat"]
                if seat in notes:
                    assert notes[seat] in user
            if teacher:
                action = json.loads(request({"kind": "teacher"})["response"])
            elif language:
                action = ({"tokens": [rng.choice(view["alphabet"]) for _ in range(rng.randint(1, 8))]}
                          if view["role"] == "speaker" else {"pick": rng.choice([0, 1, 2, 3])})
            else:
                action = {head["name"]: rng.choice(head["choices"]) for head in heads}
            if language:
                action["notes"] = f"seat-{seat}-decision-{decisions}"
                notes[seat] = action["notes"]
            result = request(
                {"kind": "step", "decision_id": observation["decision_id"], "response": json.dumps(action)}
            )
            assert result["kind"] == "accepted" and result["action"] == action
            observation = result["observation"]
            decisions += 1
            assert decisions <= 96
        assert decisions == 96
        assert set(observation["scores"]) == {"0", "1", "2", "3"}
        assert all(0 <= score <= 1 for score in observation["scores"].values())
        assert len(widths) == 1
        print("language" if language else "numeric", "teacher" if teacher else "random", decisions, widths.pop(), "features")
    finally:
        process.stdin.close()
        process.stdout.close()
        assert process.wait(timeout=5) == 0


if __name__ == "__main__":
    binary = Path(sys.argv[1]).resolve()
    for language in (False, True):
        for teacher in (True, False):
            play(binary, teacher, language)
    play(binary, True, True, "not a JSON action")
    play(binary, True, True, json.dumps({"tokens": ["outside-alphabet"]}))
