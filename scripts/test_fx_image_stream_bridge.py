#!/usr/bin/env python3
"""End-to-end ASGI regression for fx text + generated-image stream translation."""

from __future__ import annotations

import asyncio
import base64
import json
import os
import tempfile
from types import SimpleNamespace

import httpx as real_httpx

import playa_server as server

server.install_fx_gateway_overlay()


PNG_BASE64 = (
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42Y"
    "AAAAASUVORK5CYII="
)


class FakeJSONResponse:
    status_code = 200

    def __init__(self, value):
        self.value = value
        self.text = json.dumps(value)

    def json(self):
        return self.value


class FakeClient:
    captured_requests = []

    def __init__(self, **_):
        pass

    async def __aenter__(self):
        return self

    async def __aexit__(self, *_):
        return False

    async def post(self, url, json, headers):
        type(self).captured_requests.append((url, json, headers))
        if url.endswith("/chat/completions"):
            return FakeJSONResponse({
                "choices": [{
                    "message": {
                        "role": "assistant",
                        "content": "Here is the Gemini image.",
                        "images": [{
                            "type": "image_url",
                            "image_url": {"url": f"data:image/png;base64,{PNG_BASE64}"},
                        }],
                    },
                    "finish_reason": "stop",
                }],
                "usage": {"prompt_tokens": 10, "completion_tokens": 5},
            })
        if url.endswith("/images/generations"):
            return FakeJSONResponse({
                "created": 1,
                "output_format": "png",
                "data": [{"b64_json": PNG_BASE64}],
            })
        raise AssertionError(f"unexpected image endpoint: {url}")


def parse_gateway_events(response):
    response.raise_for_status()
    return [
        json.loads(line[6:])
        for line in response.text.splitlines()
        if line.startswith("data: ") and line != "data: [DONE]"
    ]


def marker_from(events):
    markers = [
        event["delta"]
        for event in events
        if event.get("type") == "text-delta"
        and event.get("delta", "").startswith("[[PLAYA_IMAGE_V1:")
    ]
    if len(markers) != 1:
        raise AssertionError(f"expected one generated image marker, got {len(markers)}")
    return markers[0]


def assert_cached_marker(marker, directory):
    token = marker.removeprefix("[[PLAYA_IMAGE_V1:").removesuffix("]]" )
    token += "=" * ((4 - len(token) % 4) % 4)
    metadata = json.loads(base64.urlsafe_b64decode(token))
    cached_image = os.path.join(directory, metadata["filename"])
    if not os.path.isfile(cached_image):
        raise AssertionError("generated image was not written to the cache")


async def main():
    original_httpx = server.httpx
    original_configuration = server._cli_proxy_api_configuration
    original_store = server._store_generated_image
    try:
        with tempfile.TemporaryDirectory(prefix="playa-fx-image-stream-") as directory:
            server.httpx = SimpleNamespace(AsyncClient=FakeClient)
            server._cli_proxy_api_configuration = lambda: ("http://mock.local/v1", "test-key")

            def store_in_test_directory(value, mime_hint=None, format_hint=None, **kwargs):
                return original_store(
                    value,
                    mime_hint,
                    format_hint,
                    cache_directory=directory,
                    seen_digests=kwargs.get("seen_digests"),
                )

            server._store_generated_image = store_in_test_directory
            transport = real_httpx.ASGITransport(app=server.base.app)
            FakeClient.captured_requests = []
            async with real_httpx.AsyncClient(
                transport=transport,
                base_url="http://playa.test",
            ) as client:
                gemini_response = await client.post(
                    "/v3/ai/language-model",
                    headers={"ai-language-model-id": "cliproxyapi::gemini-3.1-flash-image"},
                    json={
                        "prompt": [
                            {
                                "role": "user",
                                "content": [{"type": "text", "text": "Draw a circle."}],
                            }
                        ]
                    },
                )
                gpt_response = await client.post(
                    "/v3/ai/language-model",
                    headers={"ai-language-model-id": "cliproxyapi::gpt-image-2"},
                    json={
                        "prompt": [
                            {
                                "role": "user",
                                "content": [{"type": "text", "text": "Draw a circle."}],
                            }
                        ]
                    },
                )
            gemini_events = parse_gateway_events(gemini_response)
            gpt_events = parse_gateway_events(gpt_response)
            gemini_deltas = [
                event["delta"]
                for event in gemini_events
                if event.get("type") == "text-delta"
            ]
            if gemini_deltas.count("Here is the Gemini image.") != 1:
                raise AssertionError(f"Gemini text was not emitted exactly once: {gemini_deltas!r}")
            gemini_marker = marker_from(gemini_events)
            gpt_marker = marker_from(gpt_events)
            if PNG_BASE64 in gemini_response.text or PNG_BASE64 in gpt_response.text:
                raise AssertionError("raw image data leaked into the visible assistant text stream")
            for events in (gemini_events, gpt_events):
                finish = next(event for event in events if event.get("type") == "finish")
                if finish.get("finishReason", {}).get("unified") != "stop":
                    raise AssertionError(f"unexpected finish event: {finish!r}")
            assert_cached_marker(gemini_marker, directory)
            assert_cached_marker(gpt_marker, directory)

            urls = [request[0] for request in FakeClient.captured_requests]
            if urls != [
                "http://mock.local/v1/chat/completions",
                "http://mock.local/v1/images/generations",
            ]:
                raise AssertionError(f"wrong image model routing: {urls!r}")
            print("PASS: fx routed Gemini and GPT image models and cached both results.")
    finally:
        server.httpx = original_httpx
        server._cli_proxy_api_configuration = original_configuration
        server._store_generated_image = original_store


if __name__ == "__main__":
    asyncio.run(main())
