"""Play complete Babel matches through the numeric training protocol."""

import json
import random
import subprocess
import sys
from pathlib import Path


def play(binary: Path, teacher: bool) -> None:
    manifest = Path(__file__).resolve().parent.parent / "coworld_manifest_template.json"
    process = subprocess.Popen(
        [str(binary), str(manifest)],
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
        while observation["kind"] == "decision":
            encoding = request({"kind": "encode"})
            assert encoding["decision_id"] == observation["decision_id"]
            widths.add(len(encoding["values"]))
            heads = encoding["action_heads"]
            assert [len(head["choices"]) for head in heads] == [8] + [16] * 8 + [4]
            for head in heads:
                assert observation["action_schema"]["properties"][head["name"]]["enum"] == head["choices"]
            view = observation["semantic_view"]
            if view["role"] == "speaker":
                assert view["target"] in range(64)
                assert view["lineup"] == view["message"] == []
            else:
                assert view["target"] == -1
                assert len(view["lineup"]) == 4
                assert 1 <= len(view["message"]) <= 8
            if teacher:
                action = json.loads(request({"kind": "teacher"})["response"])
            else:
                action = {head["name"]: rng.choice(head["choices"]) for head in heads}
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
        print("teacher" if teacher else "random", decisions, widths.pop(), "features")
    finally:
        process.stdin.close()
        process.stdout.close()
        assert process.wait(timeout=5) == 0


if __name__ == "__main__":
    binary = Path(sys.argv[1]).resolve()
    play(binary, True)
    play(binary, False)
