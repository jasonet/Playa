#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.request
from typing import Any, Optional


DEFAULT_MODEL = "mlx-community/Qwen3.5-0.8B-8bit"
DEFAULT_PROMPTS = [
    "In one sentence, explain what MLX is useful for.",
    "Name three practical ways to reduce latency in a local model server.",
    "Write a tiny JSON object with keys status and note.",
]


def request_json(
    base_url: str,
    path: str,
    *,
    method: str = "GET",
    payload: Optional[dict[str, Any]] = None,
    timeout: float,
) -> dict[str, Any]:
    url = base_url.rstrip("/") + path
    data = None
    headers = {"Accept": "application/json"}

    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"

    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def fetch_metrics(base_url: str, timeout: float) -> dict[str, Any]:
    last_error: Optional[Exception] = None
    for path in ("/metrics", "/v1/metrics"):
        try:
            return request_json(base_url, path, timeout=timeout)
        except urllib.error.HTTPError as error:
            last_error = error
            if error.code == 404:
                continue
            raise
        except Exception as error:
            last_error = error
            raise

    raise RuntimeError(f"metrics endpoint not found: {last_error}")


def run_chat_query(
    base_url: str,
    *,
    model: str,
    prompt: str,
    max_tokens: int,
    timeout: float,
) -> dict[str, Any]:
    payload = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": 0,
        "stream": False,
    }
    return request_json(
        base_url,
        "/v1/chat/completions",
        method="POST",
        payload=payload,
        timeout=timeout,
    )


def summary(metrics: dict[str, Any]) -> dict[str, Any]:
    return metrics.get("summary") or {}


def latest(metrics: dict[str, Any]) -> dict[str, Any]:
    return metrics.get("latest") or {}


def total_processed_tokens(summary_payload: dict[str, Any]) -> int:
    return int(summary_payload.get("prompt_tokens_total") or 0) + int(
        summary_payload.get("generated_tokens_total") or 0
    )


def print_metrics(label: str, metrics: dict[str, Any]) -> None:
    summary_payload = summary(metrics)
    latest_payload = latest(metrics)
    server_payload = metrics.get("server") or {}

    print(f"\n== {label} metrics ==")
    print(f"requests completed: {summary_payload.get('requests_completed', 0)}")
    print(f"requests failed:    {summary_payload.get('requests_failed', 0)}")
    print(f"prompt tokens:      {summary_payload.get('prompt_tokens_total', 0)}")
    print(f"generated tokens:   {summary_payload.get('generated_tokens_total', 0)}")
    print(f"processed tokens:   {total_processed_tokens(summary_payload)}")
    print(f"avg decode tok/s:   {summary_payload.get('avg_decode_tok_s', 0)}")
    print(f"loaded model:       {server_payload.get('loaded_model')}")

    if latest_payload:
        print(f"latest endpoint:    {latest_payload.get('endpoint')}")
        print(f"latest total:       {latest_payload.get('total_tokens')}")
        print(f"latest decode tok/s: {latest_payload.get('decode_tok_s')}")


def print_delta(before: dict[str, Any], after: dict[str, Any]) -> None:
    before_summary = summary(before)
    after_summary = summary(after)
    fields = [
        "requests_completed",
        "requests_failed",
        "prompt_tokens_total",
        "generated_tokens_total",
    ]

    print("\n== delta ==")
    for field in fields:
        start = int(before_summary.get(field) or 0)
        end = int(after_summary.get(field) or 0)
        print(f"{field}: {end - start}")
    print(
        "total_processed_tokens: "
        f"{total_processed_tokens(after_summary) - total_processed_tokens(before_summary)}"
    )


def response_text(response: dict[str, Any]) -> str:
    choices = response.get("choices") or []
    if not choices:
        return ""
    message = choices[0].get("message") or {}
    content = message.get("content")
    if isinstance(content, str):
        return content.strip()
    return ""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Send a few simple chat requests to mlx-vlm and print metrics deltas."
    )
    parser.add_argument(
        "--base-url",
        default="http://127.0.0.1:8080",
        help="Base URL for a running mlx-vlm server.",
    )
    parser.add_argument(
        "--model",
        default=DEFAULT_MODEL,
        help="Model id to send in each chat completion request.",
    )
    parser.add_argument(
        "--max-tokens",
        type=int,
        default=48,
        help="Maximum generated tokens per prompt.",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=600,
        help="HTTP timeout in seconds. First run may download and load the model.",
    )
    parser.add_argument(
        "--prompt",
        action="append",
        dest="prompts",
        help="Prompt to send. Repeat to override the default prompt list.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    prompts = args.prompts or DEFAULT_PROMPTS

    print(f"server: {args.base_url}")
    print(f"model:  {args.model}")
    print("The first request may take a while as the model downloads and loads.")

    try:
        before = fetch_metrics(args.base_url, timeout=10)
        print_metrics("before", before)

        for index, prompt in enumerate(prompts, start=1):
            print(f"\n== query {index}/{len(prompts)} ==")
            print(prompt)
            started = time.monotonic()
            response = run_chat_query(
                args.base_url,
                model=args.model,
                prompt=prompt,
                max_tokens=args.max_tokens,
                timeout=args.timeout,
            )
            elapsed = time.monotonic() - started
            text = response_text(response)
            print(f"elapsed: {elapsed:.2f}s")
            print(f"response: {text or '<empty>'}")

        after = fetch_metrics(args.base_url, timeout=10)
        print_metrics("after", after)
        print_delta(before, after)
        return 0
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", errors="replace")
        print(f"HTTP {error.code}: {body}", file=sys.stderr)
    except urllib.error.URLError as error:
        print(f"Could not reach server at {args.base_url}: {error.reason}", file=sys.stderr)
    except KeyboardInterrupt:
        print("\nInterrupted.", file=sys.stderr)
        return 130
    except Exception as error:
        print(f"Error: {error}", file=sys.stderr)

    return 1


if __name__ == "__main__":
    raise SystemExit(main())
