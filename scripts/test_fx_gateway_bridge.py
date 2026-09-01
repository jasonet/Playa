#!/usr/bin/env python3
"""Focused regression checks for the fx-to-OpenAI Responses bridge."""

import base64
import json
import os
import tempfile

from playa_server import (
    _is_image_output_model,
    _responses_image_payloads,
    _responses_error_detail,
    _responses_finish_reason,
    _responses_tool_call,
    _split_generated_images_from_text,
    _store_generated_image,
)


def assert_equal(actual, expected, message):
    if actual != expected:
        raise AssertionError(f"{message}: expected {expected!r}, got {actual!r}")


reasoning_output = [
    {"type": "message", "content": [{"type": "output_text", "text": "OK"}]},
    {"type": "reasoning", "encrypted_content": "opaque", "summary": []},
]
assert_equal(
    _responses_finish_reason(reasoning_output),
    "stop",
    "reasoning metadata must not be treated as a tool call",
)

function_call = {
    "type": "function_call",
    "call_id": "call_1",
    "name": "read_file",
    "arguments": {"path": "README.md"},
}
assert_equal(
    _responses_finish_reason([*reasoning_output, function_call]),
    "tool-calls",
    "function calls must use the tool-calls finish reason",
)
assert_equal(
    _responses_tool_call(function_call),
    {
        "type": "tool-call",
        "toolCallId": "call_1",
        "toolName": "read_file",
        "input": '{"path":"README.md"}',
    },
    "function calls must translate to the fx gateway event shape",
)
assert_equal(
    _responses_tool_call({"type": "reasoning", "id": "reasoning_1"}),
    None,
    "non-tool output items must be ignored",
)
assert_equal(
    _responses_error_detail({"status": "failed", "error": {"message": "bad request"}}),
    "bad request",
    "provider error details must be preserved",
)

for image_model in (
    "gemini-3.1-flash-image",
    "codex/gpt-image-1.5",
    "gpt-image-2",
):
    assert_equal(
        _is_image_output_model(image_model),
        True,
        f"{image_model} must enable generated image extraction",
    )

image_payload = {
    "type": "message",
    "content": [
        {"type": "output_text", "text": "Here is the image."},
        {
            "type": "image_generation_call",
            "result": "aW1hZ2U=",
            "output_format": "png",
        },
    ],
}
assert_equal(
    _responses_image_payloads(image_payload),
    [("aW1hZ2U=", None, "png")],
    "image_generation_call results must be extracted from message content",
)
assert_equal(
    _responses_image_payloads({
        "type": "output_image",
        "inlineData": {"mimeType": "image/webp", "data": "aW1hZ2U="},
    }),
    [("aW1hZ2U=", "image/webp", None)],
    "Gemini inlineData image output must be extracted",
)

embedded_data = base64.b64encode(b"embedded-image").decode()
cleaned_text, embedded_payloads = _split_generated_images_from_text(
    f"Before ![generated](data:image/png;base64,{embedded_data}) after"
)
assert_equal(cleaned_text, "Before  after", "embedded data URLs must be removed from text")
assert_equal(
    embedded_payloads,
    [(embedded_data, "image/png", None)],
    "embedded data URLs must become image payloads",
)

with tempfile.TemporaryDirectory(prefix="playa-image-bridge-test-") as directory:
    stored = _store_generated_image(
        embedded_data,
        "image/png",
        cache_directory=directory,
    )
    if stored is None:
        raise AssertionError("valid generated image data must be stored")
    marker, _ = stored
    token = marker.removeprefix("[[PLAYA_IMAGE_V1:").removesuffix("]]" )
    token += "=" * ((4 - len(token) % 4) % 4)
    metadata = json.loads(base64.urlsafe_b64decode(token))
    assert_equal(metadata["mimeType"], "image/png", "marker must preserve MIME type")
    if not os.path.isfile(os.path.join(directory, metadata["filename"])):
        raise AssertionError("generated image cache file was not written")

print("PASS: fx gateway bridge regression checks succeeded.")
