"""Complete native-player Babel games preserve outcomes across rule wordings."""

import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time
import uuid

GAME, PLAYER, OUTPUT = (Path(value).resolve() for value in sys.argv[1:4])
SOURCE = sys.argv[4]
ROOT = Path(__file__).resolve().parents[1]
variants = [
    "canonical",
    "plain",
    "numbered",
    "questions",
    "reordered",
    "heldout-briefing",
    "heldout-reference",
]
manifest = json.loads((ROOT / "coworld_manifest_template.json").read_text())
canonical = None
direct = {}

for choice, prompt_seed in [
    *((v, 0) for v in variants),
    *(("mixed", i) for i in range(5)),
]:
    output = OUTPUT / f"{choice}-{prompt_seed}"
    output.mkdir(parents=True, exist_ok=False)
    config = dict(manifest["variants"][0]["game_config"])
    config.update(
        tokens=[f"t{seat}" for seat in range(4)],
        seed=17,
        promptVariant=choice,
        promptSeed=prompt_seed,
    )
    assert config["rounds"] == 24 and config["turnDelayMs"] == 300
    (output / "config.json").write_text(json.dumps(config))
    with socket.socket() as reserve:
        reserve.bind(("127.0.0.1", 0))
        port = reserve.getsockname()[1]
    # Keep a bound, non-listening socket for deterministic connection refusal.
    with socket.socket() as closed_endpoint:
        closed_endpoint.bind(("127.0.0.1", 0))
        endpoint = f"http://127.0.0.1:{closed_endpoint.getsockname()[1]}"
        env = {
            **os.environ,
            "COGAME_HOST": "127.0.0.1",
            "COGAME_PORT": str(port),
            "COGAME_CONFIG_URI": (output / "config.json").as_uri(),
            "COGAME_RESULTS_URI": (output / "results.json").as_uri(),
            "COGAME_SAVE_REPLAY_URI": (output / "replay.json").as_uri(),
            "COGAME_SAVE_TRAJECTORY_URI": (output / "trajectory.jsonl").as_uri(),
            "COWORLD_EPISODE_ID": str(uuid.uuid4()),
            "COWORLD_GAME_VERSION": "prompt-panel",
            "COWORLD_SOURCE_REVISION": SOURCE,
        }
        processes, logs = [], []
        try:
            log = (output / "game.log").open("w")
            logs.append(log)
            game = subprocess.Popen(
                [str(GAME)], cwd=ROOT, env=env, stdout=log, stderr=log
            )
            processes.append(game)
            ready_deadline = time.monotonic() + 15
            while True:
                with socket.socket() as probe:
                    ready = probe.connect_ex(("127.0.0.1", port)) == 0
                if ready:
                    break
                assert game.poll() is None and time.monotonic() < ready_deadline
                time.sleep(0.02)
            for seat in range(4):
                player_env = {
                    **env,
                    "COWORLD_PLAYER_WS_URL": f"ws://127.0.0.1:{port}/player?slot={seat}&token=t{seat}",
                    "COWORLD_LLM_ENDPOINT": endpoint,
                    "PLAYER_SCRIPTED": "",
                    "PLAYER_PROMPT": f"PRIVATE-OPERATOR-{seat}: play using your own feedback.",
                }
                log = (output / f"player-{seat}.log").open("w")
                logs.append(log)
                processes.append(
                    subprocess.Popen(
                        [str(PLAYER)], cwd=ROOT, env=player_env, stdout=log, stderr=log
                    )
                )
            deadline = time.monotonic() + 120
            for process in processes:
                assert process.wait(timeout=max(1, deadline - time.monotonic())) == 0
        finally:
            for process in processes:
                if process.poll() is None:
                    process.terminate()
                process.wait(timeout=5)
            for log in logs:
                log.close()
    events = [
        json.loads(line)
        for line in (output / "trajectory.jsonl").read_text().splitlines()
    ]
    episode = events[-1]
    assert episode["status"] == "completed" and len(events[:-1]) == 96
    assert set(episode["outcome"]["player_cleanup"].values()) == {"acknowledged"}
    assert (output / "trajectory.jsonl").stat().st_mode & 0o777 == 0o600
    selected = variants[prompt_seed] if choice == "mixed" else choice
    systems, roles, transcript = set(), set(), []
    for event in events[:-1]:
        view = event["observation"]
        assert view.pop("prompt_selection") == {
            "bank": "babel-rules-v1",
            "variant": selected,
            "selection": choice,
            "seed": prompt_seed,
        }
        prompt_attempts = view.pop("prompt_attempts")
        roles.add(view["role"])
        seat = int(event["seat"])
        assert len(event["attempts"]) == 1
        attempt = event["attempts"][0]
        assert attempt["origin"] == "model" and not attempt["accepted"]
        assert attempt["response_reader_joined"] is True
        assert attempt["raw_response"] is None and attempt["platform_call_id"] is None
        assert (
            event["action_status"] == "fallback"
            and event["selected_attempt_id"] is None
        )
        messages = attempt["prompt"]
        assert [message["role"] for message in messages] == ["system", "user"]
        system, user = [message["content"] for message in messages]
        assert prompt_attempts == [
            {
                "attempt_id": attempt["attempt_id"],
                "prompt_template": {
                    "bank": "babel-rules-v1",
                    "variant": selected,
                    "selection": choice,
                    "seed": prompt_seed,
                    "system_sha256": hashlib.sha256(system.encode()).hexdigest(),
                    "user_sha256": hashlib.sha256(user.encode()).hexdigest(),
                },
            }
        ]
        systems.add(system)
        assert attempt["request"]["system"] == system
        assert attempt["request"]["messages"] == [messages[1]]
        rendered = user.split("Your private observation:\n", 1)[1].split(
            "\nOperator guidance:", 1
        )[0]
        assert json.loads(rendered) == view
        assert f"PRIVATE-OPERATOR-{seat}:" in user
        assert all(
            f"PRIVATE-OPERATOR-{other}:" not in user
            for other in range(4)
            if other != seat
        )
        transcript.append((view, user, event["executed_action"]))
    assert roles == {"speaker", "listener"} and len(systems) == 1
    system = systems.pop()
    replay_text = (output / "replay.json").read_text()
    results_text = (output / "results.json").read_text()
    assert "PRIVATE-OPERATOR" not in replay_text + results_text
    outcome = transcript, json.loads(replay_text), json.loads(results_text)
    if choice == "canonical":
        canonical = outcome
    else:
        assert outcome == canonical, (
            "Wording changed private views, actions, replay, or scores"
        )
    if choice == "mixed":
        assert system == direct[selected]
    else:
        direct[choice] = system
    (output / "proof.json").write_text(
        json.dumps(
            {
                "source_revision": SOURCE,
                "variant": selected,
                "decisions": 96,
                "scores": episode["participant_outcomes"],
                "model_responses": 0,
            }
        )
        + "\n"
    )
    print(choice, prompt_seed, "96 native-player decisions PASS", flush=True)
assert len(set(direct.values())) == 7
