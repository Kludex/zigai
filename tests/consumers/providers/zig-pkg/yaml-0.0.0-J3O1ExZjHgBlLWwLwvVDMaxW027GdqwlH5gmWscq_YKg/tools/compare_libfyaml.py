#!/usr/bin/env python3
"""Compare yaml-test-suite results with libfyaml's fy-tool.

This is an optional external-oracle audit. It intentionally does not participate
in normal library behavior or the default test gate.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import subprocess
import sys
import tempfile


VISIBLE_SPACE = "\u2423"
VISIBLE_TAB_ARROW = "\u00bb"
VISIBLE_TAB_DASH = "\u2014"
VISIBLE_NEWLINE = "\u21b5"
VISIBLE_NO_FINAL_NEWLINE = "\u220e"
VISIBLE_CARRIAGE_RETURN = "\u2190"
VISIBLE_BOM = "\u21d4"

KNOWN_LIBFYAML_JSON_DEVIATIONS = {
    "C4HZ": "libfyaml 1.0.0 emits YAML 1.2 hex integer 0xFFEEBB as a JSON string while yaml-test-suite in.json expects an integer",
}


def decode_case_file(name: str, data: bytes) -> bytes:
    if name not in {"in.yaml", "out.yaml", "emit.yaml", "test.event"}:
        return data

    text = data.decode("utf-8")
    out = bytearray()
    index = 0
    while index < len(text):
        if text.startswith(VISIBLE_SPACE, index):
            out.extend(b" ")
            index += len(VISIBLE_SPACE)
            continue
        tab_len = visible_tab_marker_len(text[index:])
        if tab_len is not None:
            out.extend(b"\t")
            index += tab_len
            continue
        if text.startswith(VISIBLE_NEWLINE, index):
            out.extend(b"\n")
            index = skip_one_physical_line_break(text, index + len(VISIBLE_NEWLINE))
            continue
        if text.startswith(VISIBLE_NO_FINAL_NEWLINE, index):
            index += len(VISIBLE_NO_FINAL_NEWLINE)
            if only_physical_line_breaks_remain(text[index:]):
                break
            continue
        if text.startswith(VISIBLE_CARRIAGE_RETURN, index):
            out.extend(b"\r")
            index += len(VISIBLE_CARRIAGE_RETURN)
            continue
        if text.startswith(VISIBLE_BOM, index):
            out.extend(b"\xef\xbb\xbf")
            index += len(VISIBLE_BOM)
            continue
        if name == "test.event" and text.startswith("<SPC>", index):
            out.extend(b" ")
            index += len("<SPC>")
            continue
        if name == "test.event" and text.startswith("<TAB>", index):
            out.extend(b"\t")
            index += len("<TAB>")
            continue
        out.extend(text[index].encode("utf-8"))
        index += 1
    return bytes(out)


def visible_tab_marker_len(text: str) -> int | None:
    if text.startswith(VISIBLE_TAB_ARROW):
        return len(VISIBLE_TAB_ARROW)

    index = 0
    dash_count = 0
    while dash_count < 3 and text.startswith(VISIBLE_TAB_DASH, index):
        index += len(VISIBLE_TAB_DASH)
        dash_count += 1
    if dash_count == 0 or not text.startswith(VISIBLE_TAB_ARROW, index):
        return None
    return index + len(VISIBLE_TAB_ARROW)


def skip_one_physical_line_break(text: str, index: int) -> int:
    if index >= len(text):
        return index
    if text[index] == "\r":
        if index + 1 < len(text) and text[index + 1] == "\n":
            return index + 2
        return index + 1
    if text[index] == "\n":
        return index + 1
    return index


def only_physical_line_breaks_remain(text: str) -> bool:
    return all(char in "\r\n" for char in text)


def case_id(input_path: pathlib.Path, suite_root: pathlib.Path) -> str:
    return input_path.parent.relative_to(suite_root).as_posix()


def run_fy_tool(
    fy_tool: str,
    decoded_input: bytes,
    mode: str | None = None,
    testsuite: bool = False,
) -> subprocess.CompletedProcess[bytes]:
    with tempfile.NamedTemporaryFile(prefix="yaml-libfyaml-", suffix=".yaml") as temp:
        temp.write(decoded_input)
        temp.flush()
        command = [fy_tool, "--yaml-1.2", "--quiet", "--color", "off"]
        if testsuite:
            command.insert(1, "--testsuite")
        if mode is not None:
            command.extend(["--resolve", "--mode", mode])
        command.append(temp.name)
        return subprocess.run(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )


def parse_concatenated_json(data: bytes) -> list[object]:
    text = data.decode("utf-8")
    decoder = json.JSONDecoder()
    values: list[object] = []
    index = 0
    while True:
        while index < len(text) and text[index] in " \t\r\n":
            index += 1
        if index == len(text):
            return values
        value, index = decoder.raw_decode(text, index)
        values.append(value)


def try_parse_concatenated_json(cid: str, label: str, data: bytes, deltas: list[str]) -> list[object] | None:
    try:
        return parse_concatenated_json(data)
    except json.JSONDecodeError as err:
        deltas.append(f"{cid}: {label} is not strict JSON: {err}")
        return None


def json_values_equal(left: object, right: object) -> bool:
    if isinstance(left, bool) or isinstance(right, bool):
        return left is right
    if isinstance(left, (int, float)) and isinstance(right, (int, float)):
        return left == right
    if isinstance(left, list) and isinstance(right, list):
        return len(left) == len(right) and all(json_values_equal(a, b) for a, b in zip(left, right))
    if isinstance(left, dict) and isinstance(right, dict):
        if left.keys() != right.keys():
            return False
        return all(json_values_equal(left[key], right[key]) for key in left)
    return left == right


def json_documents_equal(left: list[object], right: list[object]) -> bool:
    return len(left) == len(right) and all(json_values_equal(a, b) for a, b in zip(left, right))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("fy_tool", help="Path to libfyaml fy-tool")
    parser.add_argument("suite_root", help="Generated yaml-test-suite data directory")
    parser.add_argument("--max-deltas", type=int, default=20, help="Maximum deltas to print")
    args = parser.parse_args()

    suite_root = pathlib.Path(args.suite_root)
    inputs = sorted(suite_root.glob("**/in.yaml"))
    if not inputs:
        print(f"no yaml-test-suite cases found under {suite_root}", file=sys.stderr)
        return 2

    checked = 0
    json_checked = 0
    emit_checked = 0
    classified_json_deltas = 0
    classified_emitter_style_deltas = 0
    deltas: list[str] = []
    for input_path in inputs:
        checked += 1
        cid = case_id(input_path, suite_root)
        case_dir = input_path.parent
        has_error = (case_dir / "error").exists()
        decoded_input = decode_case_file("in.yaml", input_path.read_bytes())
        result = run_fy_tool(args.fy_tool, decoded_input, testsuite=True)

        if has_error:
            if result.returncode == 0:
                deltas.append(f"{cid}: libfyaml accepted expected-error case")
            continue

        if result.returncode != 0:
            stderr = result.stderr.decode("utf-8", errors="replace").strip()
            deltas.append(f"{cid}: libfyaml rejected non-error case: {stderr}")
            continue

        expected_path = case_dir / "test.event"
        if not expected_path.exists():
            deltas.append(f"{cid}: missing test.event expectation")
            continue
        expected = decode_case_file("test.event", expected_path.read_bytes())
        if result.stdout != expected:
            deltas.append(f"{cid}: libfyaml testsuite event output differs from test.event")

        json_path = case_dir / "in.json"
        if json_path.exists():
            json_checked += 1
            json_result = run_fy_tool(args.fy_tool, decoded_input, "json")
            if json_result.returncode != 0:
                stderr = json_result.stderr.decode("utf-8", errors="replace").strip()
                deltas.append(f"{cid}: libfyaml JSON mode rejected non-error case: {stderr}")
                continue
            expected_json = try_parse_concatenated_json(cid, "in.json", json_path.read_bytes(), deltas)
            actual_json = try_parse_concatenated_json(cid, "libfyaml JSON output", json_result.stdout, deltas)
            if expected_json is None or actual_json is None:
                continue
            if not json_documents_equal(actual_json, expected_json):
                if cid in KNOWN_LIBFYAML_JSON_DEVIATIONS:
                    classified_json_deltas += 1
                else:
                    deltas.append(f"{cid}: libfyaml JSON output differs from in.json")

        emit_path = case_dir / "emit.yaml"
        if emit_path.exists():
            emit_checked += 1
            emit_result = run_fy_tool(args.fy_tool, decoded_input)
            if emit_result.returncode != 0:
                stderr = emit_result.stderr.decode("utf-8", errors="replace").strip()
                deltas.append(f"{cid}: libfyaml emitter rejected non-error case: {stderr}")
                continue
            expected_emit = decode_case_file("emit.yaml", emit_path.read_bytes())
            if emit_result.stdout != expected_emit:
                if json_path.exists():
                    emitted_json = run_fy_tool(args.fy_tool, emit_result.stdout, "json")
                    if emitted_json.returncode != 0:
                        stderr = emitted_json.stderr.decode("utf-8", errors="replace").strip()
                        deltas.append(f"{cid}: libfyaml emitter produced YAML that libfyaml could not load as JSON: {stderr}")
                        continue
                    expected_json = try_parse_concatenated_json(cid, "in.json", json_path.read_bytes(), deltas)
                    actual_json = try_parse_concatenated_json(cid, "libfyaml emitted JSON output", emitted_json.stdout, deltas)
                    if expected_json is not None and actual_json is not None and json_documents_equal(actual_json, expected_json):
                        classified_emitter_style_deltas += 1
                        continue

                emitted_events = run_fy_tool(args.fy_tool, emit_result.stdout, testsuite=True)
                if emitted_events.returncode == 0 and emitted_events.stdout == expected:
                    classified_emitter_style_deltas += 1
                else:
                    deltas.append(f"{cid}: libfyaml emitter output is not event-equivalent to test.event")

    print(f"libfyaml comparison checked {checked} yaml-test-suite cases")
    print(f"libfyaml JSON comparison checked {json_checked} in.json cases")
    print(f"libfyaml emitter comparison checked {emit_checked} emit.yaml cases")
    if classified_json_deltas:
        print(f"libfyaml JSON comparison classified {classified_json_deltas} known libfyaml deltas")
    if classified_emitter_style_deltas:
        print(f"libfyaml emitter comparison classified {classified_emitter_style_deltas} style-only deltas")
    if not deltas:
        print("libfyaml comparison found no unexplained parser-event, JSON, or emitter semantic deltas")
        return 0

    print(f"libfyaml comparison found {len(deltas)} deltas", file=sys.stderr)
    for delta in deltas[: args.max_deltas]:
        print(delta, file=sys.stderr)
    if len(deltas) > args.max_deltas:
        print(f"... {len(deltas) - args.max_deltas} more deltas omitted", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
