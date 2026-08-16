from __future__ import annotations

import asyncio
import hashlib
import json
import os
import sys
import unittest
from pathlib import Path

from temporalio import workflow
from temporalio.testing import WorkflowEnvironment
from temporalio.worker import Worker
from temporalio.worker.workflow_sandbox import SandboxedWorkflowRunner

from zigai_temporal_sidecar import (
    ACTIVITY_NAME,
    CommandActivity,
    Config,
    Handler,
    PROTOCOL_VERSION,
    WORKFLOW_NAME,
    load_config,
    read_bounded,
    validate_record,
    validate_request,
)
from zigai_temporal_workflow import OperationWorkflow


def make_request(config: Config) -> dict[str, object]:
    return {
        "version": PROTOCOL_VERSION,
        "namespace": "default",
        "task_queue": config.task_queue,
        "workflow_name": WORKFLOW_NAME,
        "activity_name": ACTIVITY_NAME,
        "workflow_id": "run/model.request/1",
        "invocation": {
            "run_id": "run",
            "step_id": "model.request",
            "sequence": 1,
            "kind": "model_request",
            "handler_id": "support-model",
            "input_json": "{}",
        },
        "activity": {
            "start_to_close_timeout_ms": 30_000,
            "schedule_to_close_timeout_ms": 90_000,
            "heartbeat_timeout_ms": None,
            "retry": {
                "initial_interval_ms": 1_000,
                "backoff_coefficient_milli": 2_000,
                "maximum_interval_ms": 30_000,
                "maximum_attempts": 5,
            },
        },
    }


class SidecarTests(unittest.TestCase):
    def setUp(self) -> None:
        self.config = load_config(Path(__file__).with_name("worker.example.toml"))

    def request(self) -> dict[str, object]:
        return make_request(self.config)

    def test_example_registers_worker_commands(self) -> None:
        self.assertIn(("model_request", "support-model"), self.config.handlers)
        self.assertEqual("zigai-agents", self.config.task_queue)

    def test_request_validation_is_strict(self) -> None:
        request = self.request()
        self.assertIs(request, validate_request(request, self.config, "default"))
        request["namespace"] = "another"
        with self.assertRaisesRegex(ValueError, "deployment"):
            validate_request(request, self.config, "default")

    def test_unregistered_handler_is_rejected(self) -> None:
        request = self.request()
        request["invocation"]["handler_id"] = "unknown"  # type: ignore[index]
        with self.assertRaisesRegex(ValueError, "not registered"):
            validate_request(request, self.config, "default")

    def test_record_must_match_the_invocation_and_digest(self) -> None:
        invocation = self.request()["invocation"]
        record = {
            "version": 1,
            "invocation": invocation,
            "input_sha256": hashlib.sha256(b"{}").hexdigest(),
            "status": "success",
            "output_json": "{\"ok\":true}",
        }
        self.assertIs(record, validate_record(record, invocation))  # type: ignore[arg-type]
        record["input_sha256"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "digest"):
            validate_record(record, invocation)  # type: ignore[arg-type]


class BoundedReadTests(unittest.IsolatedAsyncioTestCase):
    async def test_workflow_prepares_in_temporal_sandbox(self) -> None:
        definition = workflow._Definition.must_from_class(OperationWorkflow)
        SandboxedWorkflowRunner().prepare_workflow(definition)

    async def test_operation_runs_on_temporal_test_server(self) -> None:
        task_queue = "zigai-integration"
        handler = Handler(
            "model_request",
            "support-model",
            (sys.executable, str(Path(__file__).with_name("_test_worker.py"))),
        )
        config = Config(
            listen="127.0.0.1",
            port=8078,
            task_queue=task_queue,
            max_request_bytes=2 * 1024 * 1024,
            max_record_bytes=8 * 1024 * 1024,
            handlers={(handler.kind, handler.handler_id): handler},
        )
        request = make_request(config)
        cache = os.environ.get("TEMPORAL_TEST_SERVER_CACHE")
        if cache is not None:
            Path(cache).mkdir(parents=True, exist_ok=True)
        environment = await WorkflowEnvironment.start_time_skipping(
            download_dest_dir=cache
        )
        async with environment:
            worker = Worker(
                environment.client,
                task_queue=task_queue,
                workflows=[OperationWorkflow],
                activities=[CommandActivity(config).execute],
            )
            async with worker:
                result = await environment.client.execute_workflow(
                    OperationWorkflow.run,
                    request,
                    id=request["workflow_id"],  # type: ignore[arg-type]
                    task_queue=task_queue,
                )
        record = json.loads(result)
        self.assertEqual('{"engine":"temporal"}', record["output_json"])
        validate_record(record, request["invocation"])  # type: ignore[arg-type]

    async def test_read_bounded_stops_after_limit(self) -> None:
        reader = asyncio.StreamReader()
        reader.feed_data(b"abcdef")
        reader.feed_eof()
        self.assertEqual(b"abcd", await read_bounded(reader, 3))

    async def test_read_bounded_returns_short_stream(self) -> None:
        reader = asyncio.StreamReader()
        reader.feed_data(b"abc")
        reader.feed_eof()
        self.assertEqual(b"abc", await read_bounded(reader, 5))


if __name__ == "__main__":
    unittest.main()
