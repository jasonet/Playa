#!/usr/bin/env python3
"""Exercise the bundled fx ACP client through Playa's CLIProxyAPI bridge."""

from __future__ import annotations

import argparse
import json
import os
import queue
import subprocess
import tempfile
import threading
import time
from pathlib import Path


def _reader(stream, messages: queue.Queue):
    try:
        for line in stream:
            line = line.strip()
            if not line:
                continue
            try:
                messages.put(json.loads(line))
            except json.JSONDecodeError:
                messages.put({"_raw": line})
    finally:
        messages.put(None)


def _send(process: subprocess.Popen, payload: dict):
    process.stdin.write(json.dumps(payload, separators=(",", ":")) + "\n")
    process.stdin.flush()


def _await_response(
    messages: queue.Queue,
    request_id: int,
    *,
    timeout: float,
    agent_text: list[str],
) -> dict:
    deadline = time.monotonic() + timeout
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(f"timed out waiting for ACP response {request_id}")
        message = messages.get(timeout=remaining)
        if message is None:
            raise RuntimeError("fx closed its ACP output before completing the request")
        if message.get("method") == "session/update":
            update = message.get("params", {}).get("update", {})
            if update.get("sessionUpdate") == "agent_message_chunk":
                text = update.get("content", {}).get("text")
                if isinstance(text, str):
                    agent_text.append(text)
        if message.get("id") == request_id:
            if "error" in message:
                error = message["error"]
                detail = error.get("message") if isinstance(error, dict) else str(error)
                raise RuntimeError(f"ACP request {request_id} failed: {detail}")
            return message


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fx", required=True, type=Path)
    parser.add_argument("--base-url", default="http://127.0.0.1:18081")
    parser.add_argument("--api-key", default="playa-local")
    parser.add_argument("--model", default="cliproxyapi::gemini-3.6-flash-high")
    parser.add_argument(
        "--prompt",
        default="Reply with exactly FX_AGENT_OK and do not use tools.",
    )
    parser.add_argument("--expect", default="FX_AGENT_OK")
    parser.add_argument("--timeout", type=float, default=180.0)
    args = parser.parse_args()

    args.fx = args.fx.resolve()
    if not args.fx.is_file():
        raise SystemExit(f"fx binary not found: {args.fx}")

    environment = os.environ.copy()
    environment.update(
        {
            "AI_GATEWAY_API_KEY": args.api_key,
            "VERCEL_OIDC_TOKEN": "",
            "FX_GATEWAY_CHAT_URL": f"{args.base_url}/v3/ai/language-model",
            "FX_GATEWAY_BASE_URL": args.base_url,
            "FX_PERMISSION_MODE": "auto",
            "FX_AUTO_UPGRADE": "0",
            "FX_EXECUTION_MODE": "local",
            "NO_COLOR": "1",
        }
    )

    with tempfile.TemporaryDirectory(prefix="playa-fx-e2e-") as workspace:
        process = subprocess.Popen(
            [str(args.fx), "--context-limit", "skill_description_bytes=4096", "acp"],
            cwd=workspace,
            env=environment,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        assert process.stdin is not None
        assert process.stdout is not None
        messages: queue.Queue = queue.Queue()
        threading.Thread(target=_reader, args=(process.stdout, messages), daemon=True).start()
        agent_text: list[str] = []
        try:
            requests = [
                (1, "initialize", {"protocolVersion": 1}),
                (2, "session/new", {"cwd": workspace, "mcpServers": []}),
                (3, "session/set_config_option", {"configId": "provider", "value": "gateway"}),
                (4, "session/set_config_option", {"configId": "model", "value": args.model}),
            ]
            session_id = None
            for request_id, method, params in requests:
                _send(
                    process,
                    {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params},
                )
                response = _await_response(
                    messages,
                    request_id,
                    timeout=args.timeout,
                    agent_text=agent_text,
                )
                if request_id == 2:
                    session_id = response.get("result", {}).get("sessionId")
            if not session_id:
                raise RuntimeError("ACP session/new response did not contain sessionId")

            _send(
                process,
                {
                    "jsonrpc": "2.0",
                    "id": 5,
                    "method": "session/prompt",
                    "params": {
                        "sessionId": session_id,
                        "prompt": [
                            {
                                "type": "text",
                                "text": args.prompt,
                            }
                        ],
                    },
                },
            )
            final_response = _await_response(
                messages,
                5,
                timeout=args.timeout,
                agent_text=agent_text,
            )
            combined = "".join(agent_text)
            if args.expect not in combined:
                raise RuntimeError(f"unexpected fx agent output: {combined!r}")
            stop_reason = final_response.get("result", {}).get("stopReason")
            if stop_reason != "end_turn":
                raise RuntimeError(f"unexpected ACP stop reason: {stop_reason!r}")
            print(
                "PASS: fx ACP -> Playa gateway -> CLIProxyAPI completed "
                f"with {args.model}: {combined.strip()}"
            )
            return 0
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
            if process.returncode not in (0, -15):
                stderr = process.stderr.read() if process.stderr else ""
                if stderr:
                    print(stderr, end="", file=os.sys.stderr)


if __name__ == "__main__":
    raise SystemExit(main())
