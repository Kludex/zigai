#!/usr/bin/env python3
"""Generate ZigAI's offline pricing snapshot from pydantic/genai-prices v2."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import pathlib
import re
import sys
import urllib.request
from decimal import Decimal, ROUND_HALF_UP
from typing import Any

ROOT = pathlib.Path(__file__).resolve().parents[1]
DATA_PATH = ROOT / "data" / "genai_prices_v2.json"
OUTPUT_PATH = ROOT / "src" / "pricing_snapshot.zig"
VERSION = "v0.1.0"
COMMIT = "f1c7fab4c07950b93f5c1ea8cb10c2b54d623134"
SOURCE_PATH = "prices/new_data/v2/data_slim.json"
SOURCE_URL = f"https://raw.githubusercontent.com/pydantic/genai-prices/{COMMIT}/{SOURCE_PATH}"
SOURCE_SHA256 = "18383e0b20d34f0b66a345dade43a744e864fb8fa5371ec9233809dc6922afeb"
SNAPSHOT_DATE = dt.date(2026, 8, 16)

RATE_FIELDS = {
    "input_mtok": "input",
    "cache_write_mtok": "cache_write",
    "cache_write_1h_mtok": "cache_write_1h",
    "cache_read_mtok": "cache_read",
    "output_mtok": "output",
    "output_reasoning_mtok": "output_reasoning",
    "input_audio_mtok": "input_audio",
    "cache_audio_read_mtok": "cache_audio_read",
    "output_audio_mtok": "output_audio",
    "input_image_mtok": "input_image",
    "cache_image_read_mtok": "cache_image_read",
    "output_image_mtok": "output_image",
    "input_video_mtok": "input_video",
    "output_video_mtok": "output_video",
    "output_citation_mtok": "output_citation",
    "requests_kcount": "requests",
    "web_searches_kcount": "web_searches",
}


def zig_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def nano_rate(value: Decimal) -> int:
    scaled = value * Decimal(1_000_000_000)
    rounded = scaled.to_integral_value(rounding=ROUND_HALF_UP)
    if scaled < 0:
        raise ValueError(f"price {value} cannot be negative")
    result = int(rounded)
    if result > 2**64 - 1:
        raise ValueError(f"price {value} exceeds u64")
    return result


def active_prices(value: Any) -> dict[str, Any]:
    if isinstance(value, dict):
        return value
    if not isinstance(value, list) or not value:
        raise ValueError("prices must be an object or non-empty conditional list")
    selected = value[0]["prices"]
    for item in reversed(value):
        constraint = item.get("constraint")
        if constraint is None:
            selected = item["prices"]
            break
        if "start_date" in constraint and SNAPSHOT_DATE >= dt.date.fromisoformat(constraint["start_date"]):
            selected = item["prices"]
            break
        # Daily time-of-day discounts are intentionally not frozen into a
        # standard-price snapshot. The unconditional row remains deterministic.
    return selected


def leaves(value: dict[str, Any]) -> list[tuple[str, str]]:
    if "or" in value:
        result: list[tuple[str, str]] = []
        for child in value["or"]:
            result.extend(leaves(child))
        return result
    for source, target in (
        ("equals", "exact"),
        ("starts_with", "prefix"),
        ("ends_with", "suffix"),
        ("contains", "contains"),
    ):
        if source in value:
            return [(target, value[source])]
    if "regex" in value:
        pattern = value["regex"]
        dated = re.fullmatch(r"\^(.*)-\\d\{8\}\$", pattern)
        if dated:
            return [("dated", dated.group(1).replace(r"\.", ".") + "-")]
        digit_prefix = re.fullmatch(r"\^(.*)-\\d", pattern)
        if digit_prefix:
            return [("digit_prefix", digit_prefix.group(1).replace(r"\.", ".") + "-")]
        raise ValueError(f"unsupported model regex: {pattern}")
    raise ValueError(f"unsupported model match: {value!r}")


def emit_rates(prices: dict[str, Any]) -> tuple[str, list[str]]:
    unknown = prices.keys() - RATE_FIELDS.keys()
    if unknown:
        raise ValueError(f"unsupported price fields: {sorted(unknown)}")
    fields: list[str] = []
    tiers: list[str] = []
    for source, target in RATE_FIELDS.items():
        value = prices.get(source)
        if value is None:
            continue
        if isinstance(value, dict):
            fields.append(f".{target} = {nano_rate(value['base'])}")
            for tier in value.get("tiers", []):
                tiers.append(
                    ".{ .bucket = .%s, .start_tokens = %d, .rate = %d }"
                    % (target, tier["start"], nano_rate(tier["price"]))
                )
        else:
            fields.append(f".{target} = {nano_rate(value)}")
    return ".{ " + ", ".join(fields) + " }", tiers


def generate(data: list[dict[str, Any]]) -> str:
    entries: list[str] = []
    fallbacks: list[str] = []
    model_count = 0
    for provider in data:
        provider_id = provider["id"]
        provider_fallbacks = provider.get("fallback_model_providers", [])
        if provider_fallbacks:
            values = ", ".join(zig_string(item) for item in provider_fallbacks)
            fallbacks.append(
                f"        .{{ .provider = {zig_string(provider_id)}, .fallbacks = &.{{ {values} }} }},"
            )
        for model in provider.get("models", []):
            model_count += 1
            prices = active_prices(model.get("prices", {}))
            rates, tiers = emit_rates(prices)
            if rates == ".{  }":
                continue
            tier_source = "&.{ " + ", ".join(tiers) + " }" if tiers else "&.{}"
            for match, pattern in leaves(model["match"]):
                entries.append(
                    "        .{ .provider = %s, .model = %s, .match = .%s, .rates = %s, .tiers = %s },"
                    % (zig_string(provider_id), zig_string(pattern), match, rates, tier_source)
                )

    return "\n".join(
        [
            "//! Generated by tools/pricing_snapshot.py. Do not edit by hand.",
            "// zig fmt: off",
            "",
            f'pub const source_version = "{VERSION}";',
            f'pub const source_commit = "{COMMIT}";',
            f'pub const source_path = "{SOURCE_PATH}";',
            f'pub const source_sha256 = "{SOURCE_SHA256}";',
            f'pub const snapshot_date = "{SNAPSHOT_DATE.isoformat()}";',
            f"pub const provider_count: usize = {len(data)};",
            f"pub const model_count: usize = {model_count};",
            f"pub const entry_count: usize = {len(entries)};",
            "",
            "pub fn entries(comptime Schema: type) [entry_count]Schema.Entry {",
            "    return .{",
            *entries,
            "    };",
            "}",
            "",
            f"pub const fallback_count: usize = {len(fallbacks)};",
            "",
            "pub fn fallbacks(comptime Schema: type) [fallback_count]Schema.ProviderFallback {",
            "    return .{",
            *fallbacks,
            "    };",
            "}",
            "",
        ]
    )


def load_data() -> list[dict[str, Any]]:
    raw = DATA_PATH.read_bytes()
    digest = hashlib.sha256(raw).hexdigest()
    if digest != SOURCE_SHA256:
        raise ValueError(f"{DATA_PATH} checksum is {digest}, expected {SOURCE_SHA256}")
    value = json.loads(raw, parse_float=Decimal)
    if not isinstance(value, list):
        raise ValueError("genai-prices root must be an array")
    return value


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--update", action="store_true", help="download the pinned upstream dataset")
    parser.add_argument("--check", action="store_true", help="fail if generated output differs")
    args = parser.parse_args()
    if args.update:
        with urllib.request.urlopen(SOURCE_URL, timeout=30) as response:
            raw = response.read()
        if hashlib.sha256(raw).hexdigest() != SOURCE_SHA256:
            raise ValueError("downloaded genai-prices checksum does not match the pinned release")
        DATA_PATH.write_bytes(raw)
    rendered = generate(load_data())
    if args.check:
        if not OUTPUT_PATH.exists() or OUTPUT_PATH.read_text() != rendered:
            print(f"{OUTPUT_PATH} is stale; run tools/pricing_snapshot.py", file=sys.stderr)
            return 1
    else:
        OUTPUT_PATH.write_text(rendered)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
