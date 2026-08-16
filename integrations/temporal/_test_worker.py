"""Subprocess worker used by the Temporal integration test."""

import hashlib
import json
import sys

invocation = json.loads(sys.stdin.readline())
record = {
    "version": 1,
    "invocation": invocation,
    "input_sha256": hashlib.sha256(invocation["input_json"].encode()).hexdigest(),
    "status": "success",
    "output_json": "{\"engine\":\"temporal\"}",
}
json.dump(record, sys.stdout, separators=(",", ":"))
