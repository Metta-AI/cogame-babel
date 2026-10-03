"""Exercise forged origins and response/action mismatch through real player sockets."""
import contextlib
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GAME, PLAYER = (str(Path(arg).resolve()) for arg in sys.argv[1:3])
for origin in ("teacher", "human", "model-mismatch", "model-body-mismatch", "scripted-model-body-mismatch", "stale-stop", "premature-stop"):
    if len(sys.argv) == 4:
        path = Path(sys.argv[3]).resolve() / origin
        path.mkdir(parents=True, exist_ok=False)
        output_context = contextlib.nullcontext(path)
    else:
        output_context = tempfile.TemporaryDirectory()
    with output_context as directory:
        output = Path(directory)
        with socket.socket() as reserve:
            reserve.bind(("127.0.0.1", 0))
            port = reserve.getsockname()[1]
        config = {"tokens": [f"t{seat}" for seat in range(4)],
                  "players": [{"name": f"p{seat}"} for seat in range(4)],
                  "seed": 7, "rounds": 2, "turnDelayMs": 0,
                  "decisionTimeoutSeconds": 0.2 if origin in {"model-body-mismatch", "scripted-model-body-mismatch"} else 5, "player_connect_timeout_seconds": 5}
        (output / "config.json").write_text(json.dumps(config))
        env = {**os.environ, "COGAME_HOST": "127.0.0.1", "COGAME_PORT": str(port),
               "COGAME_CONFIG_URI": (output / "config.json").as_uri(),
               "COGAME_RESULTS_URI": (output / "results.json").as_uri(),
               "COGAME_SAVE_REPLAY_URI": (output / "replay.json").as_uri(),
               "COGAME_SAVE_TRAJECTORY_URI": (output / "trajectory.jsonl").as_uri(),
               "COWORLD_EPISODE_ID": str(uuid.uuid4()), "COWORLD_GAME_VERSION": "attack-fixture",
               "COWORLD_SOURCE_REVISION": (os.environ["COWORLD_TEST_SOURCE_REVISION"] if "COWORLD_TEST_SOURCE_REVISION" in os.environ
                 else subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()),
               "ASSERTED_ORIGIN": origin}
        processes = []
        with (output / "game.log").open("w") as log:
            try:
                processes.append(subprocess.Popen([GAME], cwd=ROOT, env=env, stdout=log, stderr=log))
                for _ in range(100):
                    if processes[0].poll() is not None: raise AssertionError("game exited before accepting players")
                    with socket.socket() as check:
                        if check.connect_ex(("127.0.0.1", port)) == 0: break
                    time.sleep(.05)
                else: raise AssertionError("game socket never opened")
                for seat in range(4):
                    player_env = {**env, "COWORLD_PLAYER_WS_URL": f"ws://127.0.0.1:{port}/player?slot={seat}&token=t{seat}"}
                    processes.append(subprocess.Popen([PLAYER], cwd=ROOT, env=player_env, stdout=log, stderr=log))
                for process in processes: assert process.wait(timeout=40) == 0
                events = [json.loads(line) for line in (output / "trajectory.jsonl").read_text().splitlines()]
                unresolved = origin in {"stale-stop", "premature-stop"}
                assert events[-1]["status"] == ("truncated" if unresolved else "completed")
                assert len(events[:-1]) == 8
                if unresolved:
                    assert not (output / "results.json").exists() and not (output / "replay.json").exists()
                    assert set(events[-1]["outcome"]["player_cleanup"].values()) == {"unresolved"}
                for decision in events[:-1]:
                    attempt = decision["attempts"][0]
                    if origin in {"model-body-mismatch", "scripted-model-body-mismatch"}:
                        assert attempt["origin"] == "model" and not attempt["accepted"]
                        assert attempt["parsed_action"] is None
                        assert decision["action_status"] == "fallback" and decision["selected_attempt_id"] is None
                    elif origin == "model-mismatch":
                        assert attempt["origin"] == "model" and not attempt["accepted"]
                        assert attempt["parsed_action"] == json.loads(attempt["response"])
                        assert decision["action_status"] == "fallback" and decision["selected_attempt_id"] is None
                    else:
                        assert attempt["origin"] == "unknown" and attempt["accepted"]
                        assert decision["action_status"] == "accepted"
                        assert attempt["parsed_action"] == decision["executed_action"]
                print(origin, "eight decisions; no teacher/model target granted", flush=True)
            finally:
                for process in processes:
                    if process.poll() is None: process.terminate()
                    process.wait(timeout=5)
