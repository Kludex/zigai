#!/usr/bin/env python3
"""Generate the PydanticAI v2 message golden fixture with the upstream adapter."""

from __future__ import annotations

import argparse
from importlib.metadata import version
from pathlib import Path

from pydantic_ai.messages import ModelMessagesTypeAdapter


PYDANTIC_AI_VERSION = "2.31.0"


def messages() -> list[dict[str, object]]:
    timestamp = "2026-08-15T12:34:56.789Z"
    provider_details = {"nested": {"enabled": True}, "sequence": [1, None, "three"]}
    metadata = {"string": "value", "number": 42, "nested": {"ok": True}}
    return [
        {
            "kind": "request",
            "parts": [
                {
                    "part_kind": "system-prompt",
                    "content": "Be concise.",
                    "timestamp": timestamp,
                    "dynamic_ref": "policy",
                },
                {
                    "part_kind": "user-prompt",
                    "content": [
                        "Inspect these files.",
                        {"kind": "text-content", "content": "caption", "metadata": metadata},
                        {
                            "kind": "image-url",
                            "url": "https://example.com/image.png",
                            "force_download": False,
                            "vendor_metadata": {"detail": "high"},
                            "media_type": "image/png",
                            "identifier": "image-1",
                        },
                        {
                            "kind": "audio-url",
                            "url": "https://example.com/audio.mp3",
                            "force_download": True,
                            "media_type": "audio/mpeg",
                            "identifier": "audio-1",
                        },
                        {
                            "kind": "document-url",
                            "url": "https://example.com/report.pdf",
                            "force_download": "allow-local",
                            "media_type": "application/pdf",
                            "identifier": "document-1",
                        },
                        {
                            "kind": "video-url",
                            "url": "https://example.com/video.mp4",
                            "media_type": "video/mp4",
                            "identifier": "video-1",
                        },
                        {
                            "kind": "binary",
                            "data": "AAEC",
                            "media_type": "application/octet-stream",
                            "vendor_metadata": {"origin": "fixture"},
                            "identifier": "binary-1",
                        },
                        {
                            "kind": "uploaded-file",
                            "file_id": "file_123",
                            "provider_name": "openai",
                            "vendor_metadata": {"purpose": "assistants"},
                            "media_type": "application/pdf",
                            "identifier": "upload-1",
                        },
                        {"kind": "cache-point", "ttl": "1h"},
                    ],
                    "timestamp": timestamp,
                },
                {
                    "part_kind": "speech",
                    "speaker": "user",
                    "transcript": "Hello",
                    "audio": {"kind": "binary", "data": "AQID", "media_type": "audio/wav"},
                    "id": "speech-user-1",
                    "provider_name": "openai",
                    "provider_details": provider_details,
                },
                {
                    "part_kind": "tool-return",
                    "tool_name": "weather",
                    "content": {"temperature": 21, "conditions": ["sunny"]},
                    "tool_call_id": "call-weather",
                    "metadata": metadata,
                    "timestamp": timestamp,
                    "outcome": "success",
                },
                {
                    "part_kind": "tool-return",
                    "tool_name": "search_tools",
                    "tool_kind": "tool-search",
                    "tool_call_id": "call-search",
                    "content": {
                        "discovered_tools": [{"name": "lookup"}, {"name": "summarize"}],
                        "message": "Two tools found.",
                    },
                    "timestamp": timestamp,
                },
                {
                    "part_kind": "tool-return",
                    "tool_name": "load_capability",
                    "tool_kind": "capability-load",
                    "tool_call_id": "call-capability",
                    "content": {"instructions": "Use the finance policy."},
                    "timestamp": timestamp,
                },
                {
                    "part_kind": "retry-prompt",
                    "content": [
                        {
                            "type": "int_parsing",
                            "loc": ["amount"],
                            "msg": "Input should be an integer",
                            "input": "many",
                            "ctx": {"expected": "integer"},
                        }
                    ],
                    "tool_name": "charge",
                    "tool_call_id": "call-charge",
                    "timestamp": timestamp,
                },
                {
                    "part_kind": "tool-availability-delta",
                    "tools_added": ["lookup", "summarize"],
                    "tool_call_id": "call-search",
                },
            ],
            "timestamp": timestamp,
            "instructions": "Be concise.\nUse tools when useful.",
            "run_id": "run-1",
            "conversation_id": "conversation-1",
            "metadata": metadata,
            "state": "interrupted",
        },
        {
            "kind": "response",
            "parts": [
                {
                    "part_kind": "text",
                    "content": "Working on it.",
                    "id": "text-1",
                    "provider_name": "openai",
                    "provider_details": provider_details,
                },
                {
                    "part_kind": "thinking",
                    "content": "I should call a tool.",
                    "id": "thinking-1",
                    "signature": "opaque-signature",
                    "provider_name": "anthropic",
                    "provider_details": provider_details,
                },
                {
                    "part_kind": "tool-call",
                    "tool_name": "weather",
                    "args": {"city": "Madrid", "days": 2},
                    "tool_call_id": "call-weather",
                    "id": "provider-item-1",
                    "provider_name": "openai",
                    "provider_details": provider_details,
                },
                {
                    "part_kind": "tool-call",
                    "tool_name": "search_tools",
                    "tool_kind": "tool-search",
                    "args": {"queries": ["weather", "forecast"]},
                    "tool_call_id": "call-search",
                },
                {
                    "part_kind": "tool-call",
                    "tool_name": "load_capability",
                    "tool_kind": "capability-load",
                    "args": {"id": "finance"},
                    "tool_call_id": "call-capability",
                },
                {
                    "part_kind": "builtin-tool-call",
                    "tool_name": "web_search",
                    "args": "{\"query\":\"Zig\"}",
                    "tool_call_id": "native-call",
                    "id": "native-item-1",
                    "provider_name": "openai",
                    "provider_details": provider_details,
                },
                {
                    "part_kind": "builtin-tool-call",
                    "tool_name": "tool_search",
                    "tool_kind": "tool-search",
                    "args": {"queries": ["compiler"]},
                    "tool_call_id": "native-search",
                    "provider_name": "anthropic",
                },
                {
                    "part_kind": "builtin-tool-return",
                    "tool_name": "web_search",
                    "content": ["result", {"kind": "binary", "data": "BAUG", "media_type": "image/png"}],
                    "tool_call_id": "native-call",
                    "metadata": metadata,
                    "timestamp": timestamp,
                    "outcome": "success",
                    "provider_name": "openai",
                    "provider_details": provider_details,
                },
                {
                    "part_kind": "builtin-tool-return",
                    "tool_name": "tool_search",
                    "tool_kind": "tool-search",
                    "tool_call_id": "native-search",
                    "content": {
                        "discovered_tools": [{"name": "compile"}],
                        "message": "One tool found.",
                    },
                    "timestamp": timestamp,
                    "provider_name": "anthropic",
                },
                {
                    "part_kind": "file",
                    "content": {
                        "kind": "binary",
                        "data": "BwgJ",
                        "media_type": "image/png",
                        "identifier": "generated-image",
                    },
                    "id": "file-1",
                    "provider_name": "google",
                    "provider_details": provider_details,
                },
                {
                    "part_kind": "speech",
                    "speaker": "assistant",
                    "transcript": "Done",
                    "audio": {"kind": "binary", "data": "CgsM", "media_type": "audio/wav"},
                    "interrupted_at_ms": 250,
                    "id": "speech-assistant-1",
                    "provider_name": "openai",
                    "provider_details": provider_details,
                },
                {
                    "part_kind": "compaction",
                    "content": "Earlier context summarized.",
                    "id": "compaction-1",
                    "provider_name": "anthropic",
                    "provider_details": provider_details,
                },
            ],
            "usage": {
                "input_tokens": 120,
                "cache_write_tokens": 10,
                "cache_read_tokens": 20,
                "output_tokens": 45,
                "input_audio_tokens": 3,
                "cache_audio_read_tokens": 2,
                "output_audio_tokens": 4,
                "details": {"reasoning_tokens": 11},
                "cost": "0.0123",
            },
            "model_name": "fixture-model",
            "timestamp": timestamp,
            "provider_name": "openai",
            "provider_url": "https://api.openai.com/v1",
            "provider_details": provider_details,
            "provider_response_id": "response-1",
            "finish_reason": "tool_call",
            "run_id": "run-1",
            "conversation_id": "conversation-1",
            "metadata": metadata,
            "state": "suspended",
        },
    ]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    installed = version("pydantic-ai-slim")
    if installed != PYDANTIC_AI_VERSION:
        raise SystemExit(f"expected pydantic-ai-slim {PYDANTIC_AI_VERSION}, found {installed}")
    validated = ModelMessagesTypeAdapter.validate_python(messages())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(ModelMessagesTypeAdapter.dump_json(validated, indent=2) + b"\n")


if __name__ == "__main__":
    main()
