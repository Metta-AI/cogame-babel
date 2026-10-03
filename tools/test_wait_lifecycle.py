"""Signals during configured pacing retain private state and join every player."""

import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import time
import uuid

GAME, PLAYER, OUTPUT = (Path(value).resolve() for value in sys.argv[1:4])
ROOT = Path(__file__).resolve().parents[1]
SOURCE = (os.environ["COWORLD_TEST_SOURCE_REVISION"] if "COWORLD_TEST_SOURCE_REVISION" in os.environ
          else subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip())

for stop_signal in (signal.SIGTERM, signal.SIGINT):
    output = OUTPUT / stop_signal.name
    output.mkdir(parents=True, exist_ok=False)
    with socket.socket() as reserve:
        reserve.bind(("127.0.0.1", 0))
        port = reserve.getsockname()[1]
    config = {"tokens": [f"t{seat}" for seat in range(4)],
              "players": [{"name": f"p{seat}"} for seat in range(4)],
              "seed": 7, "rounds": 2, "turnDelayMs": 30000,
              "decisionTimeoutSeconds": 5, "player_connect_timeout_seconds": 5}
    (output / "config.json").write_text(json.dumps(config))
    env = {**os.environ, "COGAME_HOST": "127.0.0.1", "COGAME_PORT": str(port),
           "COGAME_CONFIG_URI": (output / "config.json").as_uri(),
           "COGAME_RESULTS_URI": (output / "results.json").as_uri(),
           "COGAME_SAVE_REPLAY_URI": (output / "replay.json").as_uri(),
           "COGAME_SAVE_TRAJECTORY_URI": (output / "trajectory.jsonl").as_uri(),
           "COWORLD_TIMEOUT_SECONDS": "120", "COWORLD_EPISODE_ID": str(uuid.uuid4()),
           "COWORLD_GAME_VERSION": "wait-fixture", "COWORLD_SOURCE_REVISION": SOURCE}
    processes, logs = [], []
    try:
        game_log = (output / "game.log").open("w")
        logs.append(game_log)
        game = subprocess.Popen([str(GAME)], cwd=ROOT, env=env, stdout=game_log, stderr=game_log)
        processes.append(game)
        ready_deadline = time.monotonic() + 5
        while True:
            with socket.socket() as probe:
                ready = probe.connect_ex(("127.0.0.1", port)) == 0
            if ready:
                break
            assert game.poll() is None and time.monotonic() < ready_deadline
            time.sleep(.02)
        for seat in range(4):
            player_env = {**env, "COWORLD_PLAYER_WS_URL": f"ws://127.0.0.1:{port}/player?slot={seat}&token=t{seat}",
                          "PLAYER_SCRIPTED": "1"}
            player_log = (output / f"player-{seat}.log").open("w")
            logs.append(player_log)
            processes.append(subprocess.Popen([str(PLAYER)], cwd=ROOT, env=player_env,
                                              stdout=player_log, stderr=player_log))
        pacing_deadline = time.monotonic() + 5
        while not any("round 1 pair 1 " in line and " picks " in line
                      for line in (output / "game.log").read_text().splitlines()):
            assert game.poll() is None and time.monotonic() < pacing_deadline
            time.sleep(.02)
        time.sleep(.05)
        started = time.monotonic()
        game.send_signal(stop_signal)
        assert game.wait(timeout=5) == 0
        elapsed = time.monotonic() - started
        for player in processes[1:]:
            assert player.wait(timeout=1) == 0
        events = [json.loads(line) for line in (output / "trajectory.jsonl").read_text().splitlines()]
        assert events[-1]["status"] == "truncated"
        assert len([event for event in events if event["event_type"] == "decision"]) == 4
        assert not (output / "results.json").exists() and not (output / "replay.json").exists()
        assert (output / "trajectory.jsonl").stat().st_mode & 0o777 == 0o600
        (output / "proof.json").write_text(json.dumps({"signal": stop_signal.name,
            "configured_pacing_ms": 30000, "signal_to_seal_seconds": elapsed,
            "source_revision": SOURCE, "scope": "fixture-only"}) + "\n")
        print(stop_signal.name, "pacing joined/private truncated", elapsed, flush=True)
    finally:
        for process in reversed(processes):
            if process.poll() is None:
                process.kill()
            process.wait()
        for log in logs:
            log.close()
