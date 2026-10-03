"""Run real game/player sockets against a native Messages fixture, without paid calls."""

import base64
import contextlib
import http.server
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from pathlib import Path


GAME, PLAYER = (Path(arg).resolve() for arg in sys.argv[1:3])
ROOT = Path(__file__).resolve().parents[1]

for failure in (None, "invalid-json", "illegal-action", "sampled", "greedy-null", "greedy-tokens", "provider-error", "malformed-200", "timeout", "unknown", "large-metadata", "invalid-token-types", "invalid-probabilities", "invalid-probability-count", "invalid-usage"):
    calls = {}

    class Messages(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            assert self.path == "/v1/messages"
            request = json.loads(self.rfile.read(int(self.headers["content-length"])))
            assert request["temperature"] == (1 if failure in {"sampled", "large-metadata", "invalid-token-types", "invalid-probabilities", "invalid-probability-count"} else 0)
            assert self.headers["X-Coworld-Player-Slot"] in {"0", "1", "2", "3"}
            view = json.loads(request["messages"][0]["content"].split("Your private observation:\n", 1)[1]
                              .split("\nOperator guidance:", 1)[0])
            action = ({"tokens": [view["alphabet"][0]], "notes": "private-notes-fixture"}
                      if view["role"] == "speaker" else {"pick": 0, "notes": "private-notes-fixture"})
            text = json.dumps(action)
            if view["slot"] == 0 and failure == "invalid-json":
                text = "not a JSON action"
            elif view["slot"] == 0 and failure == "illegal-action":
                text = json.dumps({"tokens": ["outside-alphabet"], "notes": "private-notes-fixture"})
            call_id = str(uuid.uuid4())
            payload = {"id": "msg_" + call_id, "type": "message", "role": "assistant",
                       "model": "mock/served", "content": [{"type": "text", "text": text}],
                       "stop_reason": "end_turn", "usage": {"input_tokens": 10, "output_tokens": 5}}
            if failure in {"sampled", "greedy-tokens", "large-metadata", "invalid-token-types", "invalid-probabilities", "invalid-probability-count"}:
                payload["sampling_evidence"] = {
                    "policy_revision": "a" * 64, "tokenizer_revision": "b" * 64,
                    "chat_template": "fixture-template", "sampling": "full_softmax_temperature_one" if failure in {"sampled", "large-metadata", "invalid-token-types", "invalid-probabilities", "invalid-probability-count"} else "greedy",
                    "enable_thinking": False, "max_new_tokens": request["max_tokens"],
                    "max_sequence_length": 32768 + request["max_tokens"] if failure == "large-metadata" else 4096, "sampling_seed": 7, "eos_token_ids": [4],
                    "prompt_token_ids": list(range(32768)) if failure == "large-metadata" else [1, 2], "completion_token_ids": [3, 4],
                    "behavior_log_probs": [-0.5, -0.3] if failure in {"sampled", "large-metadata", "invalid-token-types", "invalid-probabilities", "invalid-probability-count"} else None, "stop_reason": "eos", "response": text}
            if failure == "greedy-null": payload["sampling_evidence"] = None
            if view["slot"] == 0:
                if failure == "invalid-token-types":
                    payload["sampling_evidence"]["prompt_token_ids"][0] = "private-token-sentinel"
                elif failure == "invalid-probabilities":
                    payload["sampling_evidence"]["behavior_log_probs"][0] = "private-probability-sentinel"
                elif failure == "invalid-probability-count":
                    payload["sampling_evidence"]["behavior_log_probs"] = [-0.5]
                elif failure == "invalid-usage":
                    payload["usage"]["input_tokens"] = "private-usage-sentinel"
            raw_body = "malformed private provider reply" if failure == "malformed-200" and view["slot"] == 0 else json.dumps(payload)
            body = raw_body.encode()
            calls[call_id] = (request, payload, raw_body)
            if failure == "timeout" and view["slot"] == 0 and view["round"] == 1:
                time.sleep(2)
            self.send_response(429 if failure == "provider-error" and view["slot"] == 0 else 200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("X-Softmax-Llm-Call-Id", call_id)
            self.send_header("request-id", "fixture-provider-" + call_id)
            if failure in {"sampled", "greedy-tokens", "large-metadata", "invalid-token-types", "invalid-probabilities", "invalid-probability-count"}:
                self.send_header("X-Coworld-Checkpoint-Sha256", "a" * 64)
                self.send_header("X-Coworld-Tokenizer-Sha256", "b" * 64)
                self.send_header("X-Coworld-Chat-Template-Sha256", "c" * 64)
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_args):
            pass

    if len(sys.argv) == 4:
        path = Path(sys.argv[3]).resolve() / (failure or "accepted")
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
                  "decisionTimeoutSeconds": 1 if failure == "timeout" else 5, "player_connect_timeout_seconds": 5}
        (output / "config.json").write_text(json.dumps(config))
        source = (os.environ["COWORLD_TEST_SOURCE_REVISION"] if "COWORLD_TEST_SOURCE_REVISION" in os.environ
                  else subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip())
        env = {**os.environ, "COGAME_HOST": "127.0.0.1", "COGAME_PORT": str(port),
               "COGAME_CONFIG_URI": (output / "config.json").as_uri(),
               "COGAME_RESULTS_URI": (output / "results.json").as_uri(),
               "COGAME_SAVE_REPLAY_URI": (output / "replay.json").as_uri(),
               "COGAME_SAVE_TRAJECTORY_URI": (output / "trajectory.jsonl").as_uri(),
               "COWORLD_EPISODE_ID": str(uuid.uuid4()), "COWORLD_GAME_VERSION": "native-fixture",
               "COWORLD_SOURCE_REVISION": source}
        provider = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Messages)
        thread_started = False
        processes = []
        logs = []
        try:
            thread = threading.Thread(target=provider.serve_forever)
            thread.start()
            thread_started = True
            game_log = (output / "game.log").open("w")
            logs.append(game_log)
            game = subprocess.Popen([str(GAME)], cwd=ROOT, env=env, stdout=game_log, stderr=game_log)
            processes.append(game)
            deadline = time.monotonic() + 10
            while True:
                with socket.socket() as probe:
                    connected = probe.connect_ex(("127.0.0.1", port)) == 0
                if connected:
                    break
                assert game.poll() is None, (output / "game.log").read_text()
                assert time.monotonic() < deadline
                time.sleep(0.02)
            for seat in range(4):
                player_env = {**env, "COWORLD_PLAYER_WS_URL": f"ws://127.0.0.1:{port}/player?slot={seat}&token=t{seat}",
                              "COWORLD_LLM_ENDPOINT": f"http://127.0.0.1:{provider.server_port}",
                              "COWORLD_LLM_MODEL": "mock/fixture", "COWORLD_LLM_TEMPERATURE": "1" if failure in {"sampled", "large-metadata", "invalid-token-types", "invalid-probabilities", "invalid-probability-count"} else "0",
                              "PLAYER_PROMPT": "private-strategy-fixture", "PLAYER_SCRIPTED": "1" if failure == "unknown" else ""}
                player_log = (output / f"player-{seat}.log").open("w")
                logs.append(player_log)
                processes.append(subprocess.Popen([str(PLAYER)], cwd=ROOT, env=player_env,
                                                  stdout=player_log, stderr=player_log))
            assert game.wait(timeout=20) == 0, (output / "game.log").read_text()
            for process in processes[1:]:
                result = process.wait(timeout=5)
                assert result == 0 or failure == "timeout"
            events = [json.loads(line) for line in (output / "trajectory.jsonl").read_text().splitlines()]
            decisions = [event for event in events if event["event_type"] == "decision"]
            episode = events[-1]
            expected = 8
            assert len(decisions) == expected and episode["status"] == "completed"
            assert episode["outcome"]["reason"] == "complete"
            assert episode["source_revision"] == source
            assert len(calls) == (0 if failure == "unknown" else expected)
            recorded_calls = set()
            fallbacks = 0
            for decision in decisions:
                assert decision["visibility"] == "private"
                assert decision["observation"]["slot"] == int(decision["seat"])
                attempt, = decision["attempts"]
                assert attempt["inference_mode"] == "text_action"
                call_id = attempt["platform_call_id"]
                if failure == "unknown":
                    assert attempt["origin"] == "unknown" and call_id is None
                    assert attempt["prompt"] is None and attempt["raw_response"] is None
                    assert attempt["decoder"] is None and attempt["request"] is None
                    assert attempt["accepted"] and attempt["parsed_action"] == decision["executed_action"]
                    continue
                if failure == "timeout" and int(decision["seat"]) == 0 and decision["observation"]["round"] == 1:
                    assert call_id is None and attempt["raw_response"] is None
                    assert attempt["response_headers"] is None and attempt["provider_request_id"] is None
                    assert attempt["request"]["messages"] and attempt["prompt"]
                    assert attempt["rejection_reason"] in {"game decision timeout before player response",
                                                          "native transport nhDeadline",
                                                          "late player response after game decision deadline"}
                    assert attempt["parsed_action"] is None
                    assert decision["action_status"] == "fallback" and not attempt["accepted"]
                    assert decision["selected_attempt_id"] is None
                    fallbacks += 1
                    continue
                request, raw_response, raw_body = calls[call_id]
                recorded_calls.add(call_id)
                assert attempt["request"] == request
                assert attempt["raw_response"] == raw_body
                assert base64.b64decode(attempt["response_body_b64"]) == raw_body.encode()
                assert b"X-Softmax-Llm-Call-Id: " + call_id.encode() in base64.b64decode(attempt["response_headers_b64"])
                assert attempt["response_complete"] is True and attempt["response_reader_joined"] is True
                assert attempt["http_status"] == (429 if failure == "provider-error" and int(decision["seat"]) == 0 else 200)
                received_failure = failure in {"provider-error", "malformed-200"} and int(decision["seat"]) == 0
                assert attempt["model"] == ("mock/fixture" if received_failure else "mock/served")
                headers = {key.lower(): value for key, value in attempt["response_headers"].items()}
                assert headers["x-softmax-llm-call-id"] == call_id
                assert headers["request-id"] == attempt["provider_request_id"] == "fixture-provider-" + call_id
                assert attempt["decoder"] == {key: request[key] for key in ("temperature", "max_tokens")}
                invalid_sampling = failure in {"invalid-token-types", "invalid-probabilities", "invalid-probability-count"} and int(decision["seat"]) == 0
                if failure in {"sampled", "greedy-tokens", "large-metadata", "invalid-token-types", "invalid-probabilities", "invalid-probability-count"} and not invalid_sampling:
                    assert attempt["prompt_token_ids"] == (list(range(32768)) if failure == "large-metadata" else [1, 2])
                    assert attempt["sampled_token_ids"] == [3, 4]
                    assert attempt["behavior_logprobs"] == ([-0.5, -0.3] if failure in {"sampled", "large-metadata", "invalid-token-types", "invalid-probabilities", "invalid-probability-count"} else None)
                    assert attempt["model_identity"] == "a" * 64
                    assert attempt["tokenizer_identity"] == "b" * 64
                    assert attempt["chat_template_sha256"] == "c" * 64
                    assert attempt["stop_reason"] == "eos"
                else:
                    assert attempt["prompt_token_ids"] is None and attempt["behavior_logprobs"] is None
                invalid_usage = failure == "invalid-usage" and int(decision["seat"]) == 0
                if not received_failure and not invalid_usage:
                    assert attempt["input_tokens"] == 10 and attempt["output_tokens"] == 5
                else:
                    assert attempt["input_tokens"] is None and attempt["output_tokens"] is None
                if invalid_sampling or invalid_usage:
                    assert decision["action_status"] == "fallback" and not attempt["accepted"]
                if decision["action_status"] == "accepted":
                    assert decision["selected_attempt_id"] == attempt["attempt_id"]
                    assert attempt["accepted"] and attempt["parsed_action"] == decision["executed_action"]
                else:
                    fallbacks += 1
                    assert decision["action_status"] == "fallback"
                    assert not attempt["accepted"] and decision["selected_attempt_id"] is None
                    assert decision["fallback_origin"] and attempt["rejection_reason"]
            assert len(recorded_calls) == (0 if failure == "unknown" else expected - (1 if failure == "timeout" else 0))
            assert recorded_calls <= set(calls)
            assert fallbacks == (2 if failure in {"invalid-json", "illegal-action", "provider-error", "malformed-200", "invalid-token-types", "invalid-probabilities", "invalid-probability-count", "invalid-usage"} else 1 if failure == "timeout" else 0)
            for log in logs: log.flush()
            public_logs = "".join(path.read_text() for path in output.glob("*.log"))
            assert "private-strategy-fixture" not in public_logs and "private-notes-fixture" not in public_logs
            replay = (output / "replay.json").read_text()
            assert "private-notes-fixture" not in replay
            assert "private-strategy-fixture" not in replay and "platform_call_id" not in replay
            assert all(identity not in replay for identity in calls)
            for sentinel in ("private-token-sentinel", "private-probability-sentinel", "private-usage-sentinel"):
                assert sentinel not in public_logs and sentinel not in replay
            assert (output / "trajectory.jsonl").stat().st_mode & 0o777 == 0o600
            print(failure or "accepted", len(decisions), "decisions", fallbacks, "fallbacks", len(recorded_calls), "fixture response IDs joined")
        finally:
            for process in processes:
                if process.poll() is None:
                    process.terminate()
                process.wait(timeout=5)
            for log in logs:
                log.close()
            if thread_started: provider.shutdown()
            provider.server_close()
            if thread_started:
                thread.join(timeout=5)
                assert not thread.is_alive()
