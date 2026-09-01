from __future__ import annotations

import atexit
import base64
import binascii
import hashlib
import json
import os
import re
import sqlite3
import time
import uuid
from contextvars import ContextVar
from dataclasses import dataclass
from datetime import datetime
from threading import Lock
from types import SimpleNamespace
from typing import Any

from fastapi import HTTPException, Request
from fastapi.responses import Response, StreamingResponse
import httpx

import mlx_vlm.server as base
import mlx_vlm.server.cli as base_cli
import mlx_vlm.server.openai as base_openai


BACKEND_NAME = f"mlx_vlm/{base.__version__}"
TRACKED_PATHS = {
    "/chat/completions",
    "/v1/chat/completions",
    "/responses",
    "/v1/responses",
}

_BASE_METRICS_CAPTURE: ContextVar[dict[str, Any] | None] = ContextVar(
    "playa_base_metrics_capture",
    default=None,
)


@dataclass
class RequestObservation:
    request_id: str
    endpoint: str
    model: str | None
    stream: bool
    image_count: int
    audio_count: int
    structured_output: bool
    thinking_enabled: bool
    started_at_unix: float
    start_time: float
    first_token_at: float | None = None


@dataclass
class ModelAggregate:
    model: str
    requests_started: int = 0
    requests_completed: int = 0
    requests_failed: int = 0
    streaming_requests: int = 0
    prompt_tokens_total: int = 0
    completion_tokens_total: int = 0
    generated_tokens_total: int = 0
    request_time_total_seconds: float = 0.0
    decode_time_total_seconds: float = 0.0
    last_request_at: float | None = None

    def to_dict(self) -> dict[str, Any]:
        avg_request_tok_s = (
            self.completion_tokens_total / self.request_time_total_seconds
            if self.request_time_total_seconds > 0
            else 0.0
        )
        avg_decode_tok_s = (
            self.generated_tokens_total / self.decode_time_total_seconds
            if self.decode_time_total_seconds > 0
            else 0.0
        )
        return {
            "model": self.model,
            "requests_started": self.requests_started,
            "requests_completed": self.requests_completed,
            "requests_failed": self.requests_failed,
            "streaming_requests": self.streaming_requests,
            "prompt_tokens_total": self.prompt_tokens_total,
            "completion_tokens_total": self.completion_tokens_total,
            "generated_tokens_total": self.generated_tokens_total,
            "avg_request_time_s": (
                self.request_time_total_seconds / self.requests_completed
                if self.requests_completed > 0
                else 0.0
            ),
            "avg_request_tok_s": avg_request_tok_s,
            "avg_decode_tok_s": avg_decode_tok_s,
            "last_request_at": self.last_request_at,
        }


def analytics_db_path() -> str:
    configured_path = os.environ.get("MLX_PLATFORM_ANALYTICS_DB_PATH")
    if configured_path:
        return os.path.expanduser(configured_path)

    return os.path.expanduser(
        "~/Library/Application Support/Playa/Analytics.sqlite3"
    )


def bucket_start_unix(timestamp: float, granularity: str) -> float:
    bucket_time = datetime.fromtimestamp(timestamp)
    if granularity == "hour":
        bucket_time = bucket_time.replace(minute=0, second=0, microsecond=0)
    else:
        bucket_time = bucket_time.replace(hour=0, minute=0, second=0, microsecond=0)
    return bucket_time.timestamp()


def seconds_to_milliseconds(value: float | None) -> int | None:
    if value is None:
        return None
    return max(0, int(round(float(value) * 1000)))


def gigabytes_to_bytes(value: float | None) -> int | None:
    if value is None:
        return None
    return max(0, int(round(float(value) * (1024**3))))


class AnalyticsStore:
    def __init__(self, path: str) -> None:
        self.path = path
        self.session_id = uuid.uuid4().hex
        self._lock = Lock()
        directory = os.path.dirname(self.path) or "."
        os.makedirs(directory, exist_ok=True)
        self._connection = sqlite3.connect(self.path, check_same_thread=False)
        self._connection.execute("PRAGMA journal_mode = WAL")
        self._connection.execute("PRAGMA synchronous = NORMAL")
        self._connection.execute("PRAGMA busy_timeout = 3000")
        self._ensure_schema()
        self._start_session()
        atexit.register(self.close_session)

    def _ensure_schema(self) -> None:
        self._connection.executescript(
            """
            CREATE TABLE IF NOT EXISTS request_events (
                request_id TEXT PRIMARY KEY,
                started_at REAL NOT NULL,
                completed_at REAL NOT NULL,
                model_id TEXT NOT NULL,
                endpoint TEXT NOT NULL,
                status TEXT NOT NULL,
                streaming INTEGER NOT NULL,
                prompt_tokens INTEGER NOT NULL,
                completion_tokens INTEGER NOT NULL,
                generated_tokens INTEGER NOT NULL,
                request_elapsed_ms INTEGER,
                decode_elapsed_ms INTEGER,
                ttft_ms INTEGER,
                peak_memory_bytes INTEGER,
                prefill_tokens_per_second REAL,
                decode_tokens_per_second REAL,
                image_count INTEGER NOT NULL,
                audio_count INTEGER NOT NULL,
                structured_output INTEGER NOT NULL,
                thinking_enabled INTEGER NOT NULL,
                tool_calls INTEGER NOT NULL,
                finish_reason TEXT,
                backend TEXT,
                created_at REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS analytics_buckets (
                granularity TEXT NOT NULL,
                bucket_start REAL NOT NULL,
                model_id TEXT NOT NULL,
                requests_started INTEGER NOT NULL,
                requests_completed INTEGER NOT NULL,
                requests_failed INTEGER NOT NULL,
                streaming_requests INTEGER NOT NULL,
                prompt_tokens_total INTEGER NOT NULL,
                completion_tokens_total INTEGER NOT NULL,
                generated_tokens_total INTEGER NOT NULL,
                request_elapsed_ms_total INTEGER NOT NULL,
                decode_elapsed_ms_total INTEGER NOT NULL,
                peak_memory_bytes_max INTEGER,
                updated_at REAL NOT NULL,
                PRIMARY KEY (granularity, bucket_start, model_id)
            );

            CREATE TABLE IF NOT EXISTS server_sessions (
                session_id TEXT PRIMARY KEY,
                started_at REAL NOT NULL,
                ended_at REAL,
                last_seen_at REAL NOT NULL,
                backend TEXT,
                loaded_model TEXT,
                loaded_adapter TEXT
            );

            CREATE INDEX IF NOT EXISTS idx_request_events_completed_at
                ON request_events (completed_at);
            CREATE INDEX IF NOT EXISTS idx_request_events_model_completed_at
                ON request_events (model_id, completed_at);
            CREATE INDEX IF NOT EXISTS idx_request_events_status_completed_at
                ON request_events (status, completed_at);
            CREATE INDEX IF NOT EXISTS idx_analytics_buckets_granularity_bucket_start
                ON analytics_buckets (granularity, bucket_start);
            CREATE INDEX IF NOT EXISTS idx_analytics_buckets_granularity_model_bucket_start
                ON analytics_buckets (granularity, model_id, bucket_start);
            """
        )

    def _start_session(self) -> None:
        started_at = time.time()
        with self._lock:
            self._connection.execute(
                """
                INSERT OR REPLACE INTO server_sessions (
                    session_id,
                    started_at,
                    last_seen_at,
                    backend,
                    loaded_model,
                    loaded_adapter
                ) VALUES (?, ?, ?, ?, ?, ?)
                """,
                (self.session_id, started_at, started_at, BACKEND_NAME, None, None),
            )
            self._connection.commit()

    def heartbeat(self, runtime: dict[str, Any] | None = None) -> None:
        snapshot = runtime or {}
        current_time = time.time()
        with self._lock:
            self._connection.execute(
                """
                UPDATE server_sessions
                SET
                    last_seen_at = ?,
                    backend = COALESCE(?, backend),
                    loaded_model = COALESCE(?, loaded_model),
                    loaded_adapter = COALESCE(?, loaded_adapter)
                WHERE session_id = ?
                """,
                (
                    current_time,
                    BACKEND_NAME,
                    snapshot.get("loaded_model"),
                    snapshot.get("loaded_adapter"),
                    self.session_id,
                ),
            )
            self._connection.commit()

    def close_session(self) -> None:
        ended_at = time.time()
        with self._lock:
            self._connection.execute(
                """
                UPDATE server_sessions
                SET ended_at = ?, last_seen_at = ?
                WHERE session_id = ? AND ended_at IS NULL
                """,
                (ended_at, ended_at, self.session_id),
            )
            self._connection.commit()

    def record_event(self, event: dict[str, Any]) -> None:
        model_id = str(event.get("model_id") or "Unknown")
        completed_at = float(event["completed_at"])
        status = str(event.get("status") or "completed")
        is_completed = status == "completed"
        updated_at = time.time()

        record = (
            str(event["request_id"]),
            float(event["started_at"]),
            completed_at,
            model_id,
            str(event.get("endpoint") or "unknown"),
            status,
            1 if event.get("streaming") else 0,
            int(event.get("prompt_tokens") or 0),
            int(event.get("completion_tokens") or 0),
            int(event.get("generated_tokens") or 0),
            event.get("request_elapsed_ms"),
            event.get("decode_elapsed_ms"),
            event.get("ttft_ms"),
            event.get("peak_memory_bytes"),
            event.get("prefill_tokens_per_second"),
            event.get("decode_tokens_per_second"),
            int(event.get("image_count") or 0),
            int(event.get("audio_count") or 0),
            1 if event.get("structured_output") else 0,
            1 if event.get("thinking_enabled") else 0,
            1 if event.get("tool_calls") else 0,
            event.get("finish_reason"),
            event.get("backend"),
            updated_at,
        )

        with self._lock:
            cursor = self._connection.execute(
                """
                INSERT OR IGNORE INTO request_events (
                    request_id,
                    started_at,
                    completed_at,
                    model_id,
                    endpoint,
                    status,
                    streaming,
                    prompt_tokens,
                    completion_tokens,
                    generated_tokens,
                    request_elapsed_ms,
                    decode_elapsed_ms,
                    ttft_ms,
                    peak_memory_bytes,
                    prefill_tokens_per_second,
                    decode_tokens_per_second,
                    image_count,
                    audio_count,
                    structured_output,
                    thinking_enabled,
                    tool_calls,
                    finish_reason,
                    backend,
                    created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                record,
            )
            if cursor.rowcount == 0:
                self._connection.commit()
                return

            request_elapsed_ms_total = int(event.get("request_elapsed_ms") or 0) if is_completed else 0
            decode_elapsed_ms_total = int(event.get("decode_elapsed_ms") or 0) if is_completed else 0
            peak_memory_bytes = event.get("peak_memory_bytes") if is_completed else None

            for granularity in ("hour", "day"):
                self._connection.execute(
                    """
                    INSERT INTO analytics_buckets (
                        granularity,
                        bucket_start,
                        model_id,
                        requests_started,
                        requests_completed,
                        requests_failed,
                        streaming_requests,
                        prompt_tokens_total,
                        completion_tokens_total,
                        generated_tokens_total,
                        request_elapsed_ms_total,
                        decode_elapsed_ms_total,
                        peak_memory_bytes_max,
                        updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(granularity, bucket_start, model_id) DO UPDATE SET
                        requests_started = analytics_buckets.requests_started + excluded.requests_started,
                        requests_completed = analytics_buckets.requests_completed + excluded.requests_completed,
                        requests_failed = analytics_buckets.requests_failed + excluded.requests_failed,
                        streaming_requests = analytics_buckets.streaming_requests + excluded.streaming_requests,
                        prompt_tokens_total = analytics_buckets.prompt_tokens_total + excluded.prompt_tokens_total,
                        completion_tokens_total = analytics_buckets.completion_tokens_total + excluded.completion_tokens_total,
                        generated_tokens_total = analytics_buckets.generated_tokens_total + excluded.generated_tokens_total,
                        request_elapsed_ms_total = analytics_buckets.request_elapsed_ms_total + excluded.request_elapsed_ms_total,
                        decode_elapsed_ms_total = analytics_buckets.decode_elapsed_ms_total + excluded.decode_elapsed_ms_total,
                        peak_memory_bytes_max = CASE
                            WHEN analytics_buckets.peak_memory_bytes_max IS NULL THEN excluded.peak_memory_bytes_max
                            WHEN excluded.peak_memory_bytes_max IS NULL THEN analytics_buckets.peak_memory_bytes_max
                            ELSE MAX(analytics_buckets.peak_memory_bytes_max, excluded.peak_memory_bytes_max)
                        END,
                        updated_at = excluded.updated_at
                    """,
                    (
                        granularity,
                        bucket_start_unix(completed_at, granularity),
                        model_id,
                        1,
                        1 if is_completed else 0,
                        0 if is_completed else 1,
                        1 if event.get("streaming") else 0,
                        int(event.get("prompt_tokens") or 0) if is_completed else 0,
                        int(event.get("completion_tokens") or 0) if is_completed else 0,
                        int(event.get("generated_tokens") or 0) if is_completed else 0,
                        request_elapsed_ms_total,
                        decode_elapsed_ms_total,
                        peak_memory_bytes,
                        updated_at,
                    ),
                )

            self._connection.execute(
                """
                UPDATE server_sessions
                SET
                    last_seen_at = ?,
                    backend = COALESCE(?, backend)
                WHERE session_id = ?
                """,
                (updated_at, BACKEND_NAME, self.session_id),
            )
            self._connection.commit()


ANALYTICS_STORE = AnalyticsStore(analytics_db_path())


class MetricsTracker:
    def __init__(self) -> None:
        self._lock = Lock()
        self.started_at = time.time()
        self.requests_started = 0
        self.requests_completed = 0
        self.requests_failed = 0
        self.streaming_requests = 0
        self.in_flight = 0
        self.prompt_tokens_total = 0
        self.completion_tokens_total = 0
        self.generated_tokens_total = 0
        self.request_time_total_seconds = 0.0
        self.decode_time_total_seconds = 0.0
        self.last_request_at: float | None = None
        self.latest_request: dict[str, Any] | None = None
        self.models: dict[str, ModelAggregate] = {}

    def record_started(self, observation: RequestObservation) -> None:
        with self._lock:
            self.requests_started += 1
            self.in_flight += 1
            if observation.stream:
                self.streaming_requests += 1
            model_key = observation.model or "Unknown"
            aggregate = self.models.setdefault(model_key, ModelAggregate(model=model_key))
            aggregate.requests_started += 1
            if observation.stream:
                aggregate.streaming_requests += 1

    def record_failed(self, observation: RequestObservation) -> None:
        completed_at = time.time()
        event = {
            "request_id": observation.request_id,
            "started_at": observation.started_at_unix,
            "completed_at": completed_at,
            "model_id": observation.model or "Unknown",
            "endpoint": observation.endpoint,
            "status": "failed",
            "streaming": observation.stream,
            "prompt_tokens": 0,
            "completion_tokens": 0,
            "generated_tokens": 0,
            "request_elapsed_ms": seconds_to_milliseconds(
                max(0.0, time.perf_counter() - observation.start_time)
            ),
            "decode_elapsed_ms": None,
            "ttft_ms": seconds_to_milliseconds(
                max(0.0, observation.first_token_at - observation.start_time)
            )
            if observation.first_token_at is not None
            else None,
            "peak_memory_bytes": None,
            "prefill_tokens_per_second": None,
            "decode_tokens_per_second": None,
            "image_count": observation.image_count,
            "audio_count": observation.audio_count,
            "structured_output": observation.structured_output,
            "thinking_enabled": observation.thinking_enabled,
            "tool_calls": False,
            "finish_reason": None,
            "backend": BACKEND_NAME,
        }

        with self._lock:
            self.requests_failed += 1
            self.in_flight = max(0, self.in_flight - 1)
            model_key = observation.model or "Unknown"
            aggregate = self.models.setdefault(model_key, ModelAggregate(model=model_key))
            aggregate.requests_failed += 1
            aggregate.last_request_at = completed_at

        try:
            ANALYTICS_STORE.record_event(event)
        except Exception as error:
            base.logger.warning("analytics persistence failed for failed request: %s", error)

    def record_completed(
        self,
        observation: RequestObservation,
        completion: dict[str, Any],
    ) -> None:
        completed_at = time.time()
        prompt_tokens = int(completion.get("prompt_tokens") or 0)
        completion_tokens = int(completion.get("completion_tokens") or 0)
        generated_tokens = int(completion.get("generated_tokens") or completion_tokens)
        elapsed = float(completion.get("request_elapsed_s") or 0.0)
        decode_tps = float(completion.get("decode_tok_s") or 0.0)
        reported_decode_time = float(completion.get("decode_elapsed_s") or 0.0)
        decode_time = reported_decode_time
        if decode_time <= 0 and generated_tokens > 0 and decode_tps > 0:
            decode_time = generated_tokens / decode_tps
        if decode_time <= 0 and generated_tokens > 0:
            decode_time = elapsed
        request_tok_s = completion.get("request_tok_s")
        if request_tok_s is None and elapsed > 0 and completion_tokens > 0:
            request_tok_s = completion_tokens / elapsed

        latest = {
            "timestamp_unix": completed_at,
            "endpoint": observation.endpoint,
            "model": completion.get("model") or observation.model,
            "stream": observation.stream,
            "backend": BACKEND_NAME,
            "prompt_tokens": prompt_tokens,
            "completion_tokens": completion_tokens,
            "generated_tokens": generated_tokens,
            "reasoning_tokens": 0,
            "total_tokens": prompt_tokens + generated_tokens,
            "prompt_eval_time_s": completion.get("prompt_eval_time_s"),
            "prefill_tok_s": completion.get("prefill_tok_s"),
            "ttft_s": completion.get("ttft_s"),
            "decode_elapsed_s": decode_time if decode_time > 0 else None,
            "request_elapsed_s": elapsed if elapsed > 0 else None,
            "request_tok_s": request_tok_s,
            "decode_tok_s": completion.get("decode_tok_s"),
            "peak_memory_gb": completion.get("peak_memory_gb"),
            "finish_reason": completion.get("finish_reason"),
            "image_count": observation.image_count,
            "audio_count": observation.audio_count,
            "structured_output": observation.structured_output,
            "thinking_enabled": observation.thinking_enabled,
            "tool_parser": current_tool_parser(),
            "tool_calls": bool(completion.get("tool_calls")),
            "apc_enabled": base.apc_manager is not None,
        }

        event = {
            "request_id": observation.request_id,
            "started_at": observation.started_at_unix,
            "completed_at": completed_at,
            "model_id": latest["model"] or observation.model or "Unknown",
            "endpoint": observation.endpoint,
            "status": "completed",
            "streaming": observation.stream,
            "prompt_tokens": prompt_tokens,
            "completion_tokens": completion_tokens,
            "generated_tokens": generated_tokens,
            "request_elapsed_ms": seconds_to_milliseconds(
                elapsed if elapsed > 0 else None
            ),
            "decode_elapsed_ms": seconds_to_milliseconds(
                decode_time if decode_time > 0 else None
            ),
            "ttft_ms": seconds_to_milliseconds(completion.get("ttft_s")),
            "peak_memory_bytes": gigabytes_to_bytes(completion.get("peak_memory_gb")),
            "prefill_tokens_per_second": completion.get("prefill_tok_s"),
            "decode_tokens_per_second": completion.get("decode_tok_s"),
            "image_count": observation.image_count,
            "audio_count": observation.audio_count,
            "structured_output": observation.structured_output,
            "thinking_enabled": observation.thinking_enabled,
            "tool_calls": bool(completion.get("tool_calls")),
            "finish_reason": completion.get("finish_reason"),
            "backend": BACKEND_NAME,
        }

        with self._lock:
            self.requests_completed += 1
            self.in_flight = max(0, self.in_flight - 1)
            self.prompt_tokens_total += prompt_tokens
            self.completion_tokens_total += completion_tokens
            self.generated_tokens_total += generated_tokens
            self.request_time_total_seconds += elapsed
            self.decode_time_total_seconds += max(0.0, decode_time)
            self.last_request_at = completed_at
            self.latest_request = latest

            model_key = latest["model"] or observation.model or "Unknown"
            aggregate = self.models.setdefault(model_key, ModelAggregate(model=model_key))
            aggregate.requests_completed += 1
            aggregate.prompt_tokens_total += prompt_tokens
            aggregate.completion_tokens_total += completion_tokens
            aggregate.generated_tokens_total += generated_tokens
            aggregate.request_time_total_seconds += elapsed
            aggregate.decode_time_total_seconds += max(0.0, decode_time)
            aggregate.last_request_at = completed_at

        try:
            ANALYTICS_STORE.record_event(event)
        except Exception as error:
            base.logger.warning("analytics persistence failed for completed request: %s", error)

    def snapshot(self) -> dict[str, Any]:
        runtime = current_runtime_snapshot()
        try:
            ANALYTICS_STORE.heartbeat(runtime)
        except Exception as error:
            base.logger.warning("analytics session heartbeat failed: %s", error)

        with self._lock:
            avg_request_time = (
                self.request_time_total_seconds / self.requests_completed
                if self.requests_completed > 0
                else 0.0
            )
            avg_request_tok_s = (
                self.completion_tokens_total / self.request_time_total_seconds
                if self.request_time_total_seconds > 0
                else 0.0
            )
            avg_decode_tok_s = (
                self.generated_tokens_total / self.decode_time_total_seconds
                if self.decode_time_total_seconds > 0
                else 0.0
            )
            return {
                "latest": self.latest_request,
                "summary": {
                    "uptime_s": max(0.0, time.time() - self.started_at),
                    "requests_started": self.requests_started,
                    "requests_completed": self.requests_completed,
                    "requests_failed": self.requests_failed,
                    "streaming_requests": self.streaming_requests,
                    "in_flight": self.in_flight,
                    "prompt_tokens_total": self.prompt_tokens_total,
                    "completion_tokens_total": self.completion_tokens_total,
                    "generated_tokens_total": self.generated_tokens_total,
                    "avg_request_time_s": avg_request_time,
                    "avg_request_tok_s": avg_request_tok_s,
                    "avg_decode_tok_s": avg_decode_tok_s,
                    "last_request_at": self.last_request_at,
                },
                "server": runtime,
                "models": [
                    aggregate.to_dict()
                    for aggregate in sorted(
                        self.models.values(),
                        key=lambda item: (item.last_request_at or 0.0, item.model),
                        reverse=True,
                    )
                ],
            }


TRACKER = MetricsTracker()


def iter_message_media(messages: list[Any]) -> tuple[int, int]:
    image_count = 0
    audio_count = 0
    for message in messages:
        content = message.get("content") if isinstance(message, dict) else None
        if not isinstance(content, list):
            continue
        for item in content:
            if not isinstance(item, dict):
                continue
            item_type = item.get("type")
            if item_type in {"image_url", "input_image"}:
                image_count += 1
            elif item_type == "input_audio":
                audio_count += 1
    return image_count, audio_count


def resolve_thinking_enabled(payload: dict[str, Any]) -> bool:
    value = payload.get("enable_thinking")
    if isinstance(value, bool):
        return value
    return bool(base.get_server_enable_thinking())


def parse_request_observation(request: Request, payload: dict[str, Any]) -> RequestObservation:
    image_count = 0
    audio_count = 0
    if request.url.path.endswith("chat/completions"):
        image_count, audio_count = iter_message_media(payload.get("messages") or [])
    elif request.url.path.endswith("responses"):
        input_items = payload.get("input")
        if isinstance(input_items, list):
            image_count, audio_count = iter_message_media(input_items)

    return RequestObservation(
        request_id=uuid.uuid4().hex,
        endpoint=request.url.path.lstrip("/"),
        model=payload.get("model"),
        stream=bool(payload.get("stream")),
        image_count=image_count,
        audio_count=audio_count,
        structured_output=payload.get("response_format") is not None or payload.get("text") is not None,
        thinking_enabled=resolve_thinking_enabled(payload),
        started_at_unix=time.time(),
        start_time=time.perf_counter(),
    )


def current_tool_parser() -> str | None:
    processor = base.model_cache.get("processor") if isinstance(base.model_cache, dict) else None
    if processor is None:
        return None
    try:
        return base._infer_tool_parser_from_processor(processor)
    except Exception:
        return None


def current_runtime_snapshot() -> dict[str, Any]:
    server_runtime_snapshot = getattr(base, "_server_runtime_snapshot", None)
    if callable(server_runtime_snapshot):
        snapshot = dict(server_runtime_snapshot())
        snapshot["analytics_db_path"] = ANALYTICS_STORE.path
        return snapshot

    config = base.model_cache.get("config") if isinstance(base.model_cache, dict) else None
    text_config = getattr(config, "text_config", None)
    loaded_context_size = getattr(text_config, "max_position_embeddings", None)

    queue_depth = 0
    requests_queue = getattr(getattr(base, "response_generator", None), "requests", None)
    if requests_queue is not None:
        try:
            queue_depth = requests_queue.qsize()
        except Exception:
            queue_depth = 0

    if base.apc_manager is not None:
        apc_snapshot = dict(base.apc_manager.stats_snapshot())
        apc_snapshot["enabled"] = True
    else:
        apc_snapshot = {"enabled": False}

    return {
        "loaded_model": base.model_cache.get("model_path") if isinstance(base.model_cache, dict) else None,
        "loaded_adapter": base.model_cache.get("adapter_path") if isinstance(base.model_cache, dict) else None,
        "loaded_context_size": loaded_context_size,
        "configured_context_limit": loaded_context_size,
        "effective_context_limit": loaded_context_size,
        "loaded_tool_parser": current_tool_parser(),
        "analytics_db_path": ANALYTICS_STORE.path,
        "continuous_batching_enabled": getattr(base, "response_generator", None) is not None,
        "request_queue_depth": queue_depth,
        "apc": apc_snapshot,
    }


class StreamAccumulator:
    def __init__(self, observation: RequestObservation, kind: str) -> None:
        self.observation = observation
        self.kind = kind
        self.model = observation.model
        self.prompt_tokens = 0
        self.completion_tokens = 0
        self.generated_tokens = 0
        self.prefill_tok_s: float | None = None
        self.decode_tok_s: float | None = None
        self.peak_memory_gb: float | None = None
        self.finish_reason: str | None = None
        self.tool_calls = False

    def feed(self, block: str) -> None:
        lines = [line for line in block.splitlines() if line]
        if not lines:
            return

        event_name = None
        data_parts: list[str] = []
        for line in lines:
            if line.startswith("event:"):
                event_name = line.partition(":")[2].strip()
            elif line.startswith("data:"):
                data_parts.append(line.partition(":")[2].lstrip())

        if not data_parts:
            return

        data_text = "\n".join(data_parts)
        if data_text == "[DONE]":
            return

        try:
            payload = json.loads(data_text)
        except json.JSONDecodeError:
            return

        if self.kind == "chat":
            self._consume_chat_chunk(payload)
        else:
            self._consume_responses_event(event_name, payload)

    def _consume_chat_chunk(self, payload: dict[str, Any]) -> None:
        self.model = payload.get("model") or self.model
        usage = payload.get("usage") or {}
        timings = payload.get("timings") or {}
        self.prompt_tokens = int(usage.get("prompt_tokens") or self.prompt_tokens)
        self.completion_tokens = int(usage.get("completion_tokens") or self.completion_tokens)
        self.generated_tokens = int(usage.get("completion_tokens") or self.generated_tokens)
        if usage.get("prompt_tps") is not None:
            self.prefill_tok_s = float(usage["prompt_tps"])
        generation_tps = usage.get("generation_tps")
        if generation_tps is None:
            generation_tps = timings.get("predicted_per_second")
        if generation_tps is not None and float(generation_tps) > 0:
            self.decode_tok_s = float(generation_tps)
        peak_memory = timings.get("peak_memory")
        if peak_memory is None:
            peak_memory = usage.get("peak_memory")
        if peak_memory is not None:
            self.peak_memory_gb = float(peak_memory)

        choices = payload.get("choices") or []
        if not choices:
            return

        choice = choices[0] or {}
        if choice.get("finish_reason"):
            self.finish_reason = choice["finish_reason"]
        delta = choice.get("delta") or {}
        if delta.get("tool_calls"):
            self.tool_calls = True
        if self.observation.first_token_at is None:
            content = delta.get("content")
            reasoning = delta.get("reasoning")
            if (isinstance(content, str) and content) or (isinstance(reasoning, str) and reasoning):
                self.observation.first_token_at = time.perf_counter()

    def _consume_responses_event(self, event_name: str | None, payload: dict[str, Any]) -> None:
        if (
            event_name
            in {"response.output_text.delta", "response.reasoning_text.delta"}
            and payload.get("delta")
        ):
            if self.observation.first_token_at is None:
                self.observation.first_token_at = time.perf_counter()
            return

        if event_name == "response.output_text.done":
            generation_tps = (payload.get("timings") or {}).get("predicted_per_second")
            if generation_tps is not None and float(generation_tps) > 0:
                self.decode_tok_s = float(generation_tps)
            return

        if event_name != "response.completed":
            return

        response = payload.get("response") or {}
        self.model = response.get("model") or self.model
        usage = response.get("usage") or {}
        self.prompt_tokens = int(usage.get("input_tokens") or self.prompt_tokens)
        self.completion_tokens = int(usage.get("output_tokens") or self.completion_tokens)
        self.generated_tokens = int(usage.get("output_tokens") or self.generated_tokens)

    def finalize(self) -> dict[str, Any]:
        elapsed = max(0.0, time.perf_counter() - self.observation.start_time)
        prompt_eval_time = None
        if self.prefill_tok_s and self.prefill_tok_s > 0 and self.prompt_tokens > 0:
            prompt_eval_time = self.prompt_tokens / self.prefill_tok_s

        return {
            "model": self.model,
            "prompt_tokens": self.prompt_tokens,
            "completion_tokens": self.completion_tokens,
            "generated_tokens": self.generated_tokens or self.completion_tokens,
            "request_elapsed_s": elapsed,
            "request_tok_s": (
                self.completion_tokens / elapsed if elapsed > 0 and self.completion_tokens > 0 else None
            ),
            "decode_tok_s": self.decode_tok_s,
            "prompt_eval_time_s": prompt_eval_time,
            "prefill_tok_s": self.prefill_tok_s,
            "ttft_s": (
                max(0.0, self.observation.first_token_at - self.observation.start_time)
                if self.observation.first_token_at is not None
                else None
            ),
            "peak_memory_gb": self.peak_memory_gb,
            "finish_reason": self.finish_reason,
            "tool_calls": self.tool_calls or self.finish_reason == "tool_calls",
        }


def parse_chat_response(body: bytes, observation: RequestObservation) -> dict[str, Any]:
    payload = json.loads(body.decode("utf-8"))
    usage = payload.get("usage") or {}
    timings = payload.get("timings") or {}
    choices = payload.get("choices") or []
    choice = choices[0] if choices else {}
    elapsed = max(0.0, time.perf_counter() - observation.start_time)
    prompt_tokens = int(usage.get("prompt_tokens") or 0)
    completion_tokens = int(usage.get("completion_tokens") or 0)
    prompt_tps = usage.get("prompt_tps")
    generation_tps = usage.get("generation_tps")
    prompt_eval_time = (
        prompt_tokens / float(prompt_tps)
        if prompt_tps and float(prompt_tps) > 0 and prompt_tokens > 0
        else None
    )
    return {
        "model": payload.get("model") or observation.model,
        "prompt_tokens": prompt_tokens,
        "completion_tokens": completion_tokens,
        "generated_tokens": int(usage.get("completion_tokens") or completion_tokens),
        "request_elapsed_s": elapsed,
        "request_tok_s": (
            completion_tokens / elapsed if elapsed > 0 and completion_tokens > 0 else None
        ),
        "decode_tok_s": float(generation_tps) if generation_tps is not None else None,
        "prompt_eval_time_s": prompt_eval_time,
        "prefill_tok_s": float(prompt_tps) if prompt_tps is not None else None,
        "ttft_s": None,
        "peak_memory_gb": (
            float(timings["peak_memory"])
            if timings.get("peak_memory") is not None
            else float(usage["peak_memory"])
            if usage.get("peak_memory") is not None
            else None
        ),
        "finish_reason": choice.get("finish_reason"),
        "tool_calls": (
            choice.get("finish_reason") == "tool_calls"
            or bool((choice.get("message") or {}).get("tool_calls"))
        ),
    }


def parse_responses_body(body: bytes, observation: RequestObservation) -> dict[str, Any]:
    payload = json.loads(body.decode("utf-8"))
    usage = payload.get("usage") or {}
    elapsed = max(0.0, time.perf_counter() - observation.start_time)
    prompt_tokens = int(usage.get("input_tokens") or 0)
    completion_tokens = int(usage.get("output_tokens") or 0)
    return {
        "model": payload.get("model") or observation.model,
        "prompt_tokens": prompt_tokens,
        "completion_tokens": completion_tokens,
        "generated_tokens": completion_tokens,
        "request_elapsed_s": elapsed,
        "request_tok_s": (
            completion_tokens / elapsed if elapsed > 0 and completion_tokens > 0 else None
        ),
        "decode_tok_s": None,
        "prompt_eval_time_s": None,
        "prefill_tok_s": None,
        "ttft_s": None,
        "peak_memory_gb": None,
        "finish_reason": "stop",
        "tool_calls": False,
    }


def merge_base_metrics(
    completion: dict[str, Any],
    envelope: dict[str, Any] | None,
) -> dict[str, Any]:
    if not envelope:
        return completion

    merged = dict(completion)
    for key in (
        "model",
        "prompt_tokens",
        "completion_tokens",
        "generated_tokens",
        "request_elapsed_s",
        "request_tok_s",
        "decode_elapsed_s",
        "decode_tok_s",
        "prompt_eval_time_s",
        "prefill_tok_s",
        "ttft_s",
        "peak_memory_gb",
        "finish_reason",
        "tool_calls",
    ):
        value = envelope.get(key)
        if value is not None:
            merged[key] = value
    return merged


def install_base_metrics_capture() -> None:
    if getattr(base_openai, "_playa_metrics_capture_installed", False):
        return

    original_build_metrics_envelope = getattr(
        base_openai,
        "_build_metrics_envelope",
        None,
    )
    if original_build_metrics_envelope is None:
        return

    def capturing_build_metrics_envelope(*args: Any, **kwargs: Any) -> dict[str, Any]:
        envelope = original_build_metrics_envelope(*args, **kwargs)
        capture = _BASE_METRICS_CAPTURE.get()
        if capture is not None:
            capture["envelope"] = dict(envelope)
        return envelope

    base_openai._build_metrics_envelope = capturing_build_metrics_envelope
    base_openai._playa_metrics_capture_installed = True


async def materialize_response(response: Any) -> tuple[Any, bytes]:
    response_body = bytes(getattr(response, "body", b"") or b"")
    if response_body or not hasattr(response, "body_iterator"):
        return response, response_body

    chunks: list[bytes] = []
    async for chunk in response.body_iterator:
        if isinstance(chunk, bytes):
            chunks.append(chunk)
        elif isinstance(chunk, bytearray):
            chunks.append(bytes(chunk))
        else:
            chunks.append(str(chunk).encode("utf-8"))

    response_body = b"".join(chunks)
    rebuilt = Response(
        content=response_body,
        status_code=response.status_code,
        headers=dict(response.headers),
        media_type=getattr(response, "media_type", None),
        background=getattr(response, "background", None),
    )
    return rebuilt, response_body


def _gateway_content_text(content: Any) -> str:
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    parts: list[str] = []
    for part in content:
        if not isinstance(part, dict):
            continue
        if part.get("type") == "text" and isinstance(part.get("text"), str):
            parts.append(part["text"])
        elif part.get("type") == "tool-result":
            output = part.get("output") or {}
            value = output.get("value") if isinstance(output, dict) else output
            if isinstance(value, str):
                parts.append(value)
    return "\n".join(parts)


def _gateway_to_responses(payload: dict[str, Any], model: str) -> dict[str, Any]:
    instructions: list[str] = []
    input_items: list[dict[str, Any]] = []
    for message in payload.get("prompt") or []:
        if not isinstance(message, dict):
            continue
        role = message.get("role")
        content = message.get("content")
        if role == "system":
            text = _gateway_content_text(content)
            if text:
                instructions.append(text)
            continue
        if role in {"user", "assistant"}:
            text = _gateway_content_text(content)
            if text:
                input_items.append({"role": role, "content": text})
            if role == "assistant" and isinstance(content, list):
                for part in content:
                    if isinstance(part, dict) and part.get("type") == "tool-call":
                        input_items.append({
                            "type": "function_call",
                            "call_id": part.get("toolCallId"),
                            "name": part.get("toolName"),
                            "arguments": json.dumps(part.get("input") or {}),
                        })
        elif role == "tool" and isinstance(content, list):
            for part in content:
                if not isinstance(part, dict) or part.get("type") != "tool-result":
                    continue
                output = part.get("output") or {}
                value = output.get("value") if isinstance(output, dict) else output
                input_items.append({
                    "type": "function_call_output",
                    "call_id": part.get("toolCallId"),
                    "output": value if isinstance(value, str) else json.dumps(value),
                })

    tools = []
    for tool in payload.get("tools") or []:
        if not isinstance(tool, dict) or not tool.get("name"):
            continue
        tools.append({
            "type": "function",
            "name": tool["name"],
            "description": tool.get("description") or "",
            "parameters": tool.get("inputSchema") or {"type": "object"},
        })

    request_payload: dict[str, Any] = {
        "model": model,
        "input": input_items,
        "instructions": "\n\n".join(instructions),
        "tools": tools,
        "tool_choice": "auto" if tools else "none",
        "stream": True,
        "store": False,
    }
    max_tokens = payload.get("maxOutputTokens")
    if isinstance(max_tokens, int) and max_tokens > 0:
        request_payload["max_output_tokens"] = max_tokens
    return request_payload


def _gateway_sse_event(value: dict[str, Any]) -> bytes:
    return f"data: {json.dumps(value, separators=(',', ':'))}\n\n".encode()


_RESPONSES_TOOL_ITEM_TYPES = {"function_call", "custom_tool_call"}
_IMAGE_OUTPUT_MODEL_IDS = {
    "gemini-3.1-flash-image",
    "gpt-image-1.5",
    "gpt-image-2",
}
_CHAT_COMPLETIONS_IMAGE_MODEL_IDS = {"gemini-3.1-flash-image"}
_IMAGES_API_MODEL_IDS = {"gpt-image-1.5", "gpt-image-2"}
_DATA_IMAGE_URL_PATTERN = re.compile(
    r"data:(image/[A-Za-z0-9.+-]+);base64,([A-Za-z0-9+/=]+)"
)
_MARKDOWN_DATA_IMAGE_PATTERN = re.compile(
    r"!\[[^\]]*\]\(\s*(data:image/[A-Za-z0-9.+-]+;base64,[A-Za-z0-9+/=]+)\s*\)"
)
_GENERATED_IMAGE_MAX_BYTES = 64 * 1024 * 1024


def _responses_tool_call(item: Any) -> dict[str, Any] | None:
    if not isinstance(item, dict) or item.get("type") not in _RESPONSES_TOOL_ITEM_TYPES:
        return None
    call_id = item.get("call_id") or item.get("id")
    name = item.get("name")
    if not isinstance(call_id, str) or not call_id:
        return None
    if not isinstance(name, str) or not name:
        return None
    arguments = item.get("arguments")
    if isinstance(arguments, (dict, list)):
        arguments = json.dumps(arguments, separators=(",", ":"))
    elif not isinstance(arguments, str):
        arguments = "{}"
    return {
        "type": "tool-call",
        "toolCallId": call_id,
        "toolName": name,
        "input": arguments,
    }


def _responses_finish_reason(output: Any) -> str:
    if not isinstance(output, list):
        return "stop"
    return "tool-calls" if any(_responses_tool_call(item) for item in output) else "stop"


def _is_image_output_model(model: str) -> bool:
    base_model = model.strip().lower().rsplit("/", 1)[-1]
    return base_model in _IMAGE_OUTPUT_MODEL_IDS


def _image_output_model_kind(model: str) -> str | None:
    base_model = model.strip().lower().rsplit("/", 1)[-1]
    if base_model in _CHAT_COMPLETIONS_IMAGE_MODEL_IDS:
        return "chat_completions"
    if base_model in _IMAGES_API_MODEL_IDS:
        return "images"
    return None


def _gateway_to_chat_completions(
    payload: dict[str, Any], model: str
) -> dict[str, Any]:
    messages: list[dict[str, str]] = []
    for message in payload.get("prompt") or []:
        if not isinstance(message, dict):
            continue
        role = message.get("role")
        if role not in {"system", "user", "assistant"}:
            continue
        text = _gateway_content_text(message.get("content"))
        if text:
            messages.append({"role": role, "content": text})
    return {
        "model": model,
        "messages": messages,
        "stream": False,
    }


def _gateway_latest_user_prompt(payload: dict[str, Any]) -> str:
    for message in reversed(payload.get("prompt") or []):
        if isinstance(message, dict) and message.get("role") == "user":
            text = _gateway_content_text(message.get("content"))
            if text:
                return text
    return "Generate an image."


def _responses_image_payloads(item: Any) -> list[tuple[str, str | None, str | None]]:
    """Collect generated image payloads without treating input images as output."""
    if not isinstance(item, dict):
        return []

    item_type = str(item.get("type") or "").lower()
    payloads: list[tuple[str, str | None, str | None]] = []
    if item_type in {
        "image_generation_call",
        "output_image",
        "generated_image",
        "image_url",
        "image",
    }:
        value = (
            item.get("result")
            or item.get("b64_json")
            or item.get("data")
            or item.get("image_url")
            or item.get("url")
        )
        if isinstance(value, dict):
            value = value.get("url") or value.get("data")
        if isinstance(value, str) and value.strip():
            payloads.append((
                value.strip(),
                item.get("mime_type") or item.get("mimeType"),
                item.get("output_format") or item.get("format"),
            ))

    inline_data = item.get("inlineData") or item.get("inline_data")
    if isinstance(inline_data, dict):
        value = inline_data.get("data")
        if isinstance(value, str) and value.strip():
            payloads.append((
                value.strip(),
                inline_data.get("mimeType") or inline_data.get("mime_type"),
                item.get("output_format") or item.get("format"),
            ))

    content = item.get("content")
    if isinstance(content, list):
        for part in content:
            payloads.extend(_responses_image_payloads(part))
    return payloads


def _responses_output_text(output: Any) -> str:
    if not isinstance(output, list):
        return ""
    text_parts: list[str] = []
    for item in output:
        if not isinstance(item, dict):
            continue
        if item.get("type") in {"output_text", "text"}:
            text = item.get("text")
            if isinstance(text, str):
                text_parts.append(text)
        content = item.get("content")
        if isinstance(content, list):
            nested = _responses_output_text(content)
            if nested:
                text_parts.append(nested)
    return "".join(text_parts)


def _split_generated_images_from_text(
    text: str,
) -> tuple[str, list[tuple[str, str | None, str | None]]]:
    payloads: list[tuple[str, str | None, str | None]] = []

    def capture(match: re.Match) -> str:
        data_url = match.group(1)
        parsed = _DATA_IMAGE_URL_PATTERN.fullmatch(data_url)
        if parsed:
            payloads.append((parsed.group(2), parsed.group(1), None))
        return ""

    cleaned = _MARKDOWN_DATA_IMAGE_PATTERN.sub(capture, text)

    def capture_raw(match: re.Match) -> str:
        payloads.append((match.group(2), match.group(1), None))
        return ""

    cleaned = _DATA_IMAGE_URL_PATTERN.sub(capture_raw, cleaned)
    cleaned = re.sub(r"[ \t]+\n", "\n", cleaned)
    cleaned = re.sub(r"\n{3,}", "\n\n", cleaned).strip()
    return cleaned, payloads


def _image_mime_type(data: bytes, mime_hint: Any, format_hint: Any) -> tuple[str, str]:
    mime = str(mime_hint or "").strip().lower()
    output_format = str(format_hint or "").strip().lower().lstrip(".")
    if output_format == "jpg":
        output_format = "jpeg"
    if not mime.startswith("image/"):
        mime = {
            "png": "image/png",
            "jpeg": "image/jpeg",
            "webp": "image/webp",
            "gif": "image/gif",
        }.get(output_format, "")
    if not mime:
        if data.startswith(b"\x89PNG\r\n\x1a\n"):
            mime = "image/png"
        elif data.startswith(b"\xff\xd8\xff"):
            mime = "image/jpeg"
        elif data.startswith((b"GIF87a", b"GIF89a")):
            mime = "image/gif"
        elif data.startswith(b"RIFF") and data[8:12] == b"WEBP":
            mime = "image/webp"
        else:
            mime = "image/png"
    extension = {
        "image/png": "png",
        "image/jpeg": "jpg",
        "image/webp": "webp",
        "image/gif": "gif",
    }.get(mime, output_format or "png")
    return mime, extension


def _store_generated_image(
    value: str,
    mime_hint: Any = None,
    format_hint: Any = None,
    cache_directory: str | None = None,
    seen_digests: set[str] | None = None,
) -> tuple[str, str] | None:
    match = _DATA_IMAGE_URL_PATTERN.fullmatch(value.strip())
    if match:
        mime_hint = match.group(1)
        value = match.group(2)
    try:
        image_data = base64.b64decode(value, validate=True)
    except (ValueError, binascii.Error):
        return None
    if not image_data or len(image_data) > _GENERATED_IMAGE_MAX_BYTES:
        return None
    digest = hashlib.sha256(image_data).hexdigest()
    if seen_digests is not None and digest in seen_digests:
        return None

    mime_type, extension = _image_mime_type(image_data, mime_hint, format_hint)
    directory = cache_directory or os.path.expanduser(
        "~/Library/Caches/Playa/Chat/GeneratedImages"
    )
    try:
        os.makedirs(directory, exist_ok=True)
        filename = f"generated-{uuid.uuid4().hex}.{extension}"
        destination = os.path.join(directory, filename)
        with open(destination, "xb") as file:
            file.write(image_data)
    except OSError:
        return None

    metadata = json.dumps(
        {"filename": filename, "mimeType": mime_type},
        separators=(",", ":"),
    ).encode()
    token = base64.urlsafe_b64encode(metadata).decode().rstrip("=")
    marker = f"[[PLAYA_IMAGE_V1:{token}]]"
    if seen_digests is not None:
        seen_digests.add(digest)
    return marker, digest


def _responses_error_detail(response: Any) -> str:
    if not isinstance(response, dict):
        return "CLIProxyAPI response did not complete."
    error = response.get("error")
    if isinstance(error, dict):
        message = error.get("message") or error.get("code")
        if message:
            return str(message)
    if error:
        return str(error)
    status = response.get("status")
    return f"CLIProxyAPI response ended with status {status or 'unknown'}."


def _cli_proxy_api_configuration() -> tuple[str, str] | None:
    path = os.path.expanduser("~/Library/Application Support/Playa/cli-proxy-api.json")
    try:
        with open(path, encoding="utf-8") as file:
            configuration = json.load(file)
        base_url = str(configuration.get("baseURL") or "").strip().rstrip("/")
        api_key = str(configuration.get("apiKey") or "").strip()
        if base_url:
            return base_url, api_key

        host = str(configuration.get("host") or "").strip()
        port = int(configuration.get("port") or 8317)
        if not host or not 1 <= port <= 65535:
            return None
        url_host = f"[{host}]" if ":" in host and not host.startswith("[") else host
        return f"http://{url_host}:{port}/v1", api_key
    except (OSError, TypeError, ValueError, json.JSONDecodeError):
        return "http://127.0.0.1:8317/v1", "123456"


def _cli_proxy_api_model_ids() -> list[str]:
    path = os.path.expanduser("~/Library/Application Support/Playa/cli-proxy-api.json")
    try:
        with open(path, encoding="utf-8") as file:
            configuration = json.load(file)
    except (OSError, TypeError, ValueError, json.JSONDecodeError):
        return []

    candidates = configuration.get("cachedModelIDs")
    model_ids = candidates if isinstance(candidates, list) else []
    default_model_id = configuration.get("defaultModelID")
    if isinstance(default_model_id, str) and default_model_id.strip():
        model_ids = [default_model_id, *model_ids]

    normalized: list[str] = []
    for value in model_ids:
        if not isinstance(value, str):
            continue
        model_id = value.strip()
        if model_id and model_id not in normalized:
            normalized.append(model_id)
    return normalized


def install_fx_gateway_overlay() -> None:
    if getattr(base.app.state, "playa_fx_gateway_installed", False):
        return
    base.app.state.playa_fx_gateway_installed = True

    @base.app.get("/coding-agent/v1/models", include_in_schema=False)
    async def fx_gateway_models_endpoint():
        """Expose local and CLIProxyAPI language models in fx's catalog shape."""
        snapshot = current_runtime_snapshot()
        model_ids: list[str] = []

        loaded_model = snapshot.get("loaded_model")
        if loaded_model is not None:
            loaded_model_id = str(loaded_model)
            if loaded_model_id:
                model_ids.append(loaded_model_id)

        loaded_models = snapshot.get("loaded_models")
        if isinstance(loaded_models, dict):
            for loaded in loaded_models.values():
                model_id = loaded.get("model") if isinstance(loaded, dict) else loaded
                if model_id is not None:
                    model_id = str(model_id)
                if model_id and model_id not in model_ids:
                    model_ids.append(model_id)

        for model_id in _cli_proxy_api_model_ids():
            routed_model_id = f"cliproxyapi::{model_id}"
            if routed_model_id not in model_ids:
                model_ids.append(routed_model_id)

        return {
            "object": "list",
            "data": [
                {
                    "id": model_id,
                    "type": "language",
                    "tags": ["tool-use", "reasoning"],
                }
                for model_id in model_ids
            ],
        }

    @base.app.post("/v3/ai/language-model", include_in_schema=False)
    async def fx_gateway_endpoint(request: Request):
        payload = await request.json()
        model = request.headers.get("ai-language-model-id") or payload.get("model")
        if not isinstance(model, str) or not model:
            raise HTTPException(status_code=400, detail="Missing ai-language-model-id.")
        cli_proxy_prefix = "cliproxyapi::"
        routes_to_cli_proxy = model.startswith(cli_proxy_prefix)
        if routes_to_cli_proxy:
            model = model[len(cli_proxy_prefix):]
            if not model:
                raise HTTPException(status_code=400, detail="Missing CLIProxyAPI model ID.")
            cli_proxy = _cli_proxy_api_configuration()
            if cli_proxy is None:
                raise HTTPException(
                    status_code=503,
                    detail="CLIProxyAPI is not configured. Save it from Integrations first.",
                )
            cli_proxy_base_url, cli_proxy_api_key = cli_proxy
            if cli_proxy_base_url.endswith("/v1"):
                responses_url = f"{cli_proxy_base_url}/responses"
            else:
                responses_url = f"{cli_proxy_base_url}/v1/responses"
            forwarded_headers = {"accept": "text/event-stream"}
            if cli_proxy_api_key:
                forwarded_headers["authorization"] = f"Bearer {cli_proxy_api_key}"
        else:
            responses_url = str(request.url.replace(path="/v1/responses", query=""))
            forwarded_headers = {"accept": "text/event-stream"}
            if authorization := request.headers.get("authorization"):
                forwarded_headers["authorization"] = authorization
        responses_payload = _gateway_to_responses(payload, model)
        captures_generated_images = routes_to_cli_proxy and _is_image_output_model(model)
        image_output_model_kind = _image_output_model_kind(model) if routes_to_cli_proxy else None

        async def stream():
            emitted_tool_call_ids: set[str] = set()
            emitted_image_digests: set[str] = set()
            buffered_text: list[str] = []

            def tool_call_event(item: Any) -> dict[str, Any] | None:
                converted = _responses_tool_call(item)
                if converted is None:
                    return None
                call_id = converted["toolCallId"]
                if call_id in emitted_tool_call_ids:
                    return None
                emitted_tool_call_ids.add(call_id)
                return converted

            def generated_image_events(item: Any) -> list[dict[str, Any]]:
                events: list[dict[str, Any]] = []
                for value, mime_hint, format_hint in _responses_image_payloads(item):
                    stored = _store_generated_image(
                        value,
                        mime_hint,
                        format_hint,
                        seen_digests=emitted_image_digests,
                    )
                    if stored is None:
                        continue
                    marker, digest = stored
                    events.append({
                        "type": "text-delta",
                        "id": f"generated_image_{len(emitted_image_digests)}",
                        "delta": marker,
                    })
                return events

            async def emit_image_model_response(client: httpx.AsyncClient):
                if image_output_model_kind == "chat_completions":
                    endpoint = (
                        f"{cli_proxy_base_url}/chat/completions"
                        if cli_proxy_base_url.endswith("/v1")
                        else f"{cli_proxy_base_url}/v1/chat/completions"
                    )
                    response = await client.post(
                        endpoint,
                        json=_gateway_to_chat_completions(payload, model),
                        headers=forwarded_headers,
                    )
                else:
                    endpoint = (
                        f"{cli_proxy_base_url}/images/generations"
                        if cli_proxy_base_url.endswith("/v1")
                        else f"{cli_proxy_base_url}/v1/images/generations"
                    )
                    response = await client.post(
                        endpoint,
                        json={
                            "model": model,
                            "prompt": _gateway_latest_user_prompt(payload),
                            "n": 1,
                            "response_format": "b64_json",
                        },
                        headers=forwarded_headers,
                    )

                if response.status_code >= 400:
                    yield _gateway_sse_event({"type": "error", "error": response.text})
                    yield _gateway_sse_event({
                        "type": "finish",
                        "finishReason": {"unified": "error", "raw": "provider_error"},
                    })
                    return

                try:
                    result = response.json()
                except ValueError:
                    yield _gateway_sse_event({
                        "type": "error",
                        "error": "CLIProxyAPI returned an invalid image response.",
                    })
                    yield _gateway_sse_event({
                        "type": "finish",
                        "finishReason": {"unified": "error", "raw": "provider_error"},
                    })
                    return

                text = ""
                image_items: list[Any] = []
                input_tokens = 0
                output_tokens = 0
                if image_output_model_kind == "chat_completions":
                    choices = result.get("choices") if isinstance(result, dict) else None
                    message = (
                        choices[0].get("message")
                        if isinstance(choices, list)
                        and choices
                        and isinstance(choices[0], dict)
                        and isinstance(choices[0].get("message"), dict)
                        else {}
                    )
                    content = message.get("content")
                    if isinstance(content, str):
                        text = content
                    elif isinstance(content, list):
                        text = _responses_output_text(content)
                    images = message.get("images")
                    if isinstance(images, list):
                        image_items.extend(images)
                    if isinstance(content, list):
                        image_items.extend(content)
                    usage = result.get("usage") if isinstance(result, dict) else {}
                    if isinstance(usage, dict):
                        input_tokens = usage.get("prompt_tokens", 0)
                        output_tokens = usage.get("completion_tokens", 0)
                else:
                    data = result.get("data") if isinstance(result, dict) else None
                    output_format = result.get("output_format") if isinstance(result, dict) else None
                    if isinstance(data, list):
                        image_items.extend({
                            "type": "generated_image",
                            "b64_json": item.get("b64_json"),
                            "url": item.get("url"),
                            "output_format": item.get("output_format") or output_format,
                        } for item in data if isinstance(item, dict))

                cleaned_text, embedded_images = _split_generated_images_from_text(text)
                if cleaned_text:
                    yield _gateway_sse_event({
                        "type": "text-delta",
                        "id": "answer_1",
                        "delta": cleaned_text,
                    })
                image_items.extend({
                    "type": "generated_image",
                    "data": value,
                    "mime_type": mime_hint,
                    "output_format": format_hint,
                } for value, mime_hint, format_hint in embedded_images)

                emitted_image_count = 0
                for image_event in generated_image_events({
                    "type": "message",
                    "content": image_items,
                }):
                    emitted_image_count += 1
                    yield _gateway_sse_event(image_event)

                if emitted_image_count == 0:
                    yield _gateway_sse_event({
                        "type": "error",
                        "error": "CLIProxyAPI completed without returning image data.",
                    })
                    yield _gateway_sse_event({
                        "type": "finish",
                        "finishReason": {"unified": "error", "raw": "missing_image"},
                    })
                    return

                yield _gateway_sse_event({
                    "type": "finish",
                    "finishReason": {"unified": "stop", "raw": "stop"},
                    "usage": {
                        "inputTokens": {"total": input_tokens},
                        "outputTokens": {"total": output_tokens},
                    },
                })

            async with httpx.AsyncClient(timeout=None, trust_env=False) as client:
                if image_output_model_kind is not None:
                    async for image_chunk in emit_image_model_response(client):
                        yield image_chunk
                    yield b"data: [DONE]\n\n"
                    return
                async with client.stream(
                    "POST",
                    responses_url,
                    json=responses_payload,
                    headers=forwarded_headers,
                ) as response:
                    if response.status_code >= 400:
                        detail = (await response.aread()).decode(errors="replace")
                        yield _gateway_sse_event({"type": "error", "error": detail})
                        yield _gateway_sse_event({
                            "type": "finish",
                            "finishReason": {"unified": "error", "raw": "provider_error"},
                        })
                        return
                    event_name: str | None = None
                    async for line in response.aiter_lines():
                        if line.startswith("event:"):
                            event_name = line[6:].strip()
                            continue
                        if not line.startswith("data:"):
                            continue
                        data = line[5:].strip()
                        if not data or data == "[DONE]":
                            continue
                        event = json.loads(data)
                        event_type = event.get("type") or event_name
                        if event_type == "response.output_text.delta" and event.get("delta"):
                            if captures_generated_images:
                                buffered_text.append(event["delta"])
                            else:
                                yield _gateway_sse_event({
                                    "type": "text-delta",
                                    "id": event.get("item_id") or "answer_1",
                                    "delta": event["delta"],
                                })
                        elif event_type == "response.reasoning_text.delta" and event.get("delta"):
                            yield _gateway_sse_event({
                                "type": "reasoning-delta",
                                "id": event.get("item_id") or "reasoning_1",
                                "delta": event["delta"],
                            })
                        elif event_type == "response.function_call_arguments.done":
                            converted = tool_call_event({
                                "type": "function_call",
                                "call_id": event.get("call_id") or event.get("item_id"),
                                "name": event.get("name"),
                                "arguments": event.get("arguments"),
                            })
                            if converted is not None:
                                yield _gateway_sse_event(converted)
                        elif event_type == "response.output_item.done":
                            output_item = event.get("item")
                            converted = tool_call_event(output_item)
                            if converted is not None:
                                yield _gateway_sse_event(converted)
                            if captures_generated_images:
                                for image_event in generated_image_events(output_item):
                                    yield _gateway_sse_event(image_event)
                        elif event_type == "response.completed":
                            completed = event.get("response") or {}
                            status = completed.get("status")
                            if status not in {None, "completed"} or completed.get("error"):
                                yield _gateway_sse_event({
                                    "type": "error",
                                    "error": _responses_error_detail(completed),
                                })
                                yield _gateway_sse_event({
                                    "type": "finish",
                                    "finishReason": {"unified": "error", "raw": "provider_error"},
                                })
                                return
                            output = completed.get("output") or []
                            if captures_generated_images:
                                completed_text = _responses_output_text(output)
                                combined_text = completed_text or "".join(buffered_text)
                                cleaned_text, embedded_images = _split_generated_images_from_text(
                                    combined_text
                                )
                                if cleaned_text:
                                    yield _gateway_sse_event({
                                        "type": "text-delta",
                                        "id": "answer_1",
                                        "delta": cleaned_text,
                                    })
                                for image_event in generated_image_events({
                                    "type": "message",
                                    "content": [
                                        {
                                            "type": "generated_image",
                                            "data": value,
                                            "mime_type": mime_hint,
                                            "output_format": format_hint,
                                        }
                                        for value, mime_hint, format_hint in embedded_images
                                    ],
                                }):
                                    yield _gateway_sse_event(image_event)
                                for image_event in generated_image_events({
                                    "type": "message",
                                    "content": output,
                                }):
                                    yield _gateway_sse_event(image_event)
                            for item in output:
                                converted = tool_call_event(item)
                                if converted is not None:
                                    yield _gateway_sse_event(converted)
                            usage = completed.get("usage") or {}
                            finish = _responses_finish_reason(output)
                            yield _gateway_sse_event({
                                "type": "finish",
                                "finishReason": {"unified": finish, "raw": finish},
                                "usage": {
                                    "inputTokens": {"total": usage.get("input_tokens", 0)},
                                    "outputTokens": {"total": usage.get("output_tokens", 0)},
                                },
                            })
                    yield b"data: [DONE]\n\n"

        return StreamingResponse(stream(), media_type="text/event-stream")


def install_metrics_overlay() -> None:
    if getattr(base.app.state, "mlx_platform_metrics_installed", False):
        return
    base.app.state.mlx_platform_metrics_installed = True
    install_base_metrics_capture()

    @base.app.middleware("http")
    async def metrics_middleware(request: Request, call_next):
        if request.url.path not in TRACKED_PATHS:
            return await call_next(request)

        body = await request.body()
        try:
            payload = json.loads(body.decode("utf-8")) if body else {}
        except json.JSONDecodeError:
            payload = {}
        observation = parse_request_observation(request, payload)
        TRACKER.record_started(observation)
        metrics_capture: dict[str, Any] = {}
        capture_token = _BASE_METRICS_CAPTURE.set(metrics_capture)

        try:
            response = await call_next(request)
        except Exception:
            TRACKER.record_failed(observation)
            raise
        finally:
            _BASE_METRICS_CAPTURE.reset(capture_token)

        if response.status_code >= 400:
            TRACKER.record_failed(observation)
            return response

        content_type = response.headers.get("content-type", "")
        if "text/event-stream" in content_type and hasattr(response, "body_iterator"):
            accumulator = StreamAccumulator(
                observation,
                "chat" if request.url.path.endswith("chat/completions") else "responses",
            )
            original_iterator = response.body_iterator

            async def wrapped_iterator():
                buffer = ""
                try:
                    async for chunk in original_iterator:
                        text = (
                            chunk.decode("utf-8", errors="replace")
                            if isinstance(chunk, (bytes, bytearray))
                            else str(chunk)
                        )
                        buffer += text
                        while "\n\n" in buffer:
                            block, buffer = buffer.split("\n\n", 1)
                            try:
                                accumulator.feed(block)
                            except Exception as error:
                                base.logger.warning("metrics stream instrumentation failed: %s", error)
                        yield chunk
                    if buffer.strip():
                        try:
                            accumulator.feed(buffer)
                        except Exception as error:
                            base.logger.warning("metrics stream instrumentation failed: %s", error)
                    try:
                        completion = merge_base_metrics(
                            accumulator.finalize(),
                            metrics_capture.get("envelope"),
                        )
                        TRACKER.record_completed(observation, completion)
                    except Exception as error:
                        base.logger.warning("metrics completion instrumentation failed: %s", error)
                except Exception:
                    TRACKER.record_failed(observation)
                    raise

            response.body_iterator = wrapped_iterator()
            return response

        try:
            response, response_body = await materialize_response(response)
            if request.url.path.endswith("chat/completions"):
                completion = parse_chat_response(response_body, observation)
            else:
                completion = parse_responses_body(response_body, observation)
            completion = merge_base_metrics(
                completion,
                metrics_capture.get("envelope"),
            )
            TRACKER.record_completed(observation, completion)
        except Exception as error:
            base.logger.warning("metrics instrumentation failed for %s: %s", request.url.path, error)

        return response

    @base.app.get("/v1", include_in_schema=False)
    @base.app.get("/v1/", include_in_schema=False)
    async def openai_api_root():
        snapshot = current_runtime_snapshot()
        return {
            "object": "api",
            "name": "Playa OpenAI-compatible API",
            "version": "v1",
            "status": "ready" if snapshot.get("loaded_model") else "loading",
            "model": snapshot.get("loaded_model"),
            "endpoints": {
                "models": "/v1/models",
                "chat_completions": "/v1/chat/completions",
                "responses": "/v1/responses",
                "metrics": "/v1/metrics",
                "health": "/health",
            },
        }

    @base.app.get("/metrics")
    @base.app.get("/v1/metrics", include_in_schema=False)
    async def metrics_endpoint():
        return TRACKER.snapshot()

    @base.app.post("/models/load", include_in_schema=False)
    @base.app.post("/v1/models/load")
    def load_model_endpoint(request: Request, payload: dict[str, Any]):
        """Load or hot-swap the text model without restarting the server."""
        require_api_key = getattr(base, "_require_management_api_key", None)
        if require_api_key is not None:
            require_api_key(request)

        model = payload.get("model")
        if not isinstance(model, str) or not model.strip():
            raise HTTPException(status_code=400, detail="A non-empty model is required.")

        adapter = payload.get("adapter_path")
        if adapter is not None and not isinstance(adapter, str):
            raise HTTPException(status_code=400, detail="adapter_path must be a string or null.")

        try:
            base.get_cached_model(model.strip(), adapter)
        except HTTPException:
            raise
        except Exception as error:
            raise HTTPException(status_code=500, detail=f"Failed to load model: {error}") from error

        snapshot = current_runtime_snapshot()
        return {
            "status": "loaded",
            "model": snapshot.get("loaded_model"),
            "loaded_models": snapshot.get("loaded_models", {}),
        }


def main() -> None:
    install_fx_gateway_overlay()
    install_metrics_overlay()
    original_argparse = base_cli.argparse

    def playa_argument_parser(*args: Any, **kwargs: Any):
        kwargs["description"] = "Playa."
        return original_argparse.ArgumentParser(*args, **kwargs)

    base_cli.argparse = SimpleNamespace(ArgumentParser=playa_argument_parser)
    try:
        base.main()
    finally:
        base_cli.argparse = original_argparse


install_metrics_overlay()


if __name__ == "__main__":
    main()
