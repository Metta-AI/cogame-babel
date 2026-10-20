"""Complete Babel games preserve private views and outcomes across rule wordings."""

import hashlib
import json
from pathlib import Path
import subprocess
import sys

binary = str(Path(sys.argv[1]).resolve())
manifest = str(Path(__file__).resolve().parents[1] / "coworld_manifest_template.json")
variants = [
    "canonical",
    "plain",
    "numbered",
    "questions",
    "reordered",
    "heldout-briefing",
    "heldout-reference",
]


def request(process, command):
    process.stdin.write(json.dumps(command) + "\n")
    process.stdin.flush()
    line = process.stdout.readline()
    assert line, process.poll()
    return json.loads(line)


completed = 0
with subprocess.Popen(
    [binary, manifest, "--language"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    text=True,
) as process:
    for seed in ("17",):
        canonical = None
        direct = []
        for choice, prompt_seed in [
            *((v, 0) for v in variants),
            ("mixed", 4),
        ]:
            observation = request(
                process,
                {
                    "kind": "reset",
                    "seed": seed,
                    "players": 4,
                    "promptVariant": choice,
                    "promptSeed": prompt_seed,
                    "split": "validation",
                },
            )
            transcript, systems, roles = [], set(), set()
            while observation["kind"] == "decision":
                view = observation["semantic_view"]
                metadata = view.pop("prompt_template")
                selected = variants[prompt_seed] if choice == "mixed" else choice
                assert (
                    metadata["bank"],
                    metadata["variant"],
                    metadata["selection"],
                    metadata["seed"],
                ) == ("babel-rules-v1", selected, choice, prompt_seed)
                messages = observation["messages"]
                for message in messages:
                    assert (
                        metadata[message["role"] + "_sha256"].lower()
                        == hashlib.sha256(message["content"].encode()).hexdigest()
                    )
                systems.add(messages[0]["content"])
                roles.add(view["role"])
                rendered_view = (
                    messages[1]["content"]
                    .split("Your private observation:\n", 1)[1]
                    .split("\nOperator guidance:", 1)[0]
                )
                assert json.loads(rendered_view) == view
                assert "prompt_template" not in messages[1]["content"]
                if view["role"] == "speaker":
                    assert (
                        "target" in view
                        and "lineup" not in view
                        and "message" not in view
                    )
                else:
                    assert "target" not in view and "target_scene" not in view
                    assert len(view["lineup"]) == 4 and 1 <= len(view["message"]) <= 8
                seat = observation["seat"]
                for other in range(4):
                    if other != seat:
                        assert f"PRIVATE-{other}" not in messages[1]["content"]
                action = json.loads(request(process, {"kind": "teacher"})["response"])
                action["notes"] = f"PRIVATE-{seat}"
                result = request(
                    process,
                    {
                        "kind": "step",
                        "decision_id": observation["decision_id"],
                        "response": json.dumps(action),
                    },
                )
                assert result["kind"] == "accepted" and result["action"] == action
                transcript.append((view, messages[1], action))
                observation = result["observation"]
                assert len(transcript) <= 96
            assert observation["kind"] == "terminal" and len(transcript) == 96
            assert roles == {"speaker", "listener"} and len(systems) == 1
            system = systems.pop()
            outcome = transcript, observation
            if choice == "canonical":
                canonical = outcome
            else:
                assert outcome == canonical, (
                    "Wording changed private views, actions, notes, or scores"
                )
            if choice == "mixed":
                assert system == direct[prompt_seed]
            else:
                direct.append(system)
            completed += 1
        assert len(set(direct)) == 7
    process.stdin.close()
    assert process.wait(timeout=5) == 0

for invalid in (
    {"promptVariant": "heldout-briefing"},
    {"promptVariant": "heldout-reference"},
    {"promptVariant": "mixed"},
    {"promptVariant": "unknown"},
    {"promptVariant": 1},
    {"promptVariant": "mixed", "promptSeed": -1},
    {"promptVariant": "mixed", "promptSeed": True},
    {"promptVariant": "mixed", "promptSeed": 1.5},
):
    result = subprocess.run(
        [binary, manifest, "--language"],
        text=True,
        capture_output=True,
        timeout=10,
        input=json.dumps({"kind": "reset", "seed": "17", "players": 4} | invalid)
        + "\n",
    )
    assert result.returncode != 0 and not result.stdout

print(json.dumps({"complete_language_games": completed}))
