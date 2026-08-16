"""Temporal SDK sidecar for ZigAI's versioned durable operation protocol."""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import os
import re
import secrets
import signal
import tomllib
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from aiohttp import web
from temporalio import activity
from temporalio.client import Client
from temporalio.common import WorkflowIDReusePolicy
from temporalio.exceptions import ApplicationError, WorkflowAlreadyStartedError
from temporalio.worker import Worker

from zigai_temporal_workflow import ACTIVITY_NAME, WORKFLOW_NAME, OperationWorkflow

PROTOCOL_VERSION = 1
OPERATION_KINDS = {
    "model_request",
    "model_stream",
    "tool_call",
    "mcp_request",
    "event_delivery",
    "retry_delay",
    "approval_resume",
}
SUSPENSION_REASONS = {"approval", "external_tool", "provider_resume"}
IDENTIFIER = re.compile(r"[A-Za-z0-9._-]{1,128}\Z")


@dataclass(frozen=True)
class Handler:
    kind: str
    handler_id: str
    command: tuple[str, ...]


@dataclass(frozen=True)
class Config:
    listen: str
    port: int
    task_queue: str
    max_request_bytes: int
    max_record_bytes: int
    handlers: dict[tuple[str, str], Handler]


def load_config(path: Path) -> Config:
    with path.open("rb") as source:
        raw = tomllib.load(source)
    handlers: dict[tuple[str, str], Handler] = {}
    for item in raw.get("handlers", []):
        kind = item.get("kind")
        handler_id = item.get("id")
        command = item.get("command")
        if (
            kind not in OPERATION_KINDS
            or not isinstance(handler_id, str)
            or IDENTIFIER.fullmatch(handler_id) is None
            or not isinstance(command, list)
            or not command
            or not all(isinstance(value, str) and value for value in command)
        ):
            raise ValueError("invalid Temporal handler registration")
        key = (kind, handler_id)
        if key in handlers:
            raise ValueError(f"duplicate Temporal handler registration: {key!r}")
        handlers[key] = Handler(kind, handler_id, tuple(command))
    if not handlers:
        raise ValueError("at least one Temporal handler must be registered")
    config = Config(
        listen=raw.get("listen", "127.0.0.1"),
        port=raw.get("port", 8078),
        task_queue=raw.get("task_queue", "zigai-agents"),
        max_request_bytes=raw.get("max_request_bytes", 2 * 1024 * 1024),
        max_record_bytes=raw.get("max_record_bytes", 8 * 1024 * 1024),
        handlers=handlers,
    )
    if (
        not isinstance(config.listen, str)
        or not isinstance(config.port, int)
        or not 1 <= config.port <= 65535
        or not isinstance(config.task_queue, str)
        or IDENTIFIER.fullmatch(config.task_queue) is None
        or not isinstance(config.max_request_bytes, int)
        or config.max_request_bytes <= 0
        or not isinstance(config.max_record_bytes, int)
        or config.max_record_bytes <= 0
    ):
        raise ValueError("invalid Temporal sidecar configuration")
    return config


def validate_request(value: Any, config: Config, namespace: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != {
        "version",
        "namespace",
        "task_queue",
        "workflow_name",
        "activity_name",
        "workflow_id",
        "invocation",
        "activity",
    }:
        raise ValueError("invalid request fields")
    if (
        value["version"] != PROTOCOL_VERSION
        or value["namespace"] != namespace
        or value["task_queue"] != config.task_queue
        or value["workflow_name"] != WORKFLOW_NAME
        or value["activity_name"] != ACTIVITY_NAME
        or not isinstance(value["workflow_id"], str)
        or not value["workflow_id"]
    ):
        raise ValueError("request does not match this deployment")
    invocation = value["invocation"]
    if not isinstance(invocation, dict) or set(invocation) != {
        "run_id",
        "step_id",
        "sequence",
        "kind",
        "handler_id",
        "input_json",
    }:
        raise ValueError("invalid invocation")
    key = (invocation.get("kind"), invocation.get("handler_id"))
    if key not in config.handlers:
        raise ValueError("handler is not registered on this worker")
    if (
        not isinstance(invocation.get("run_id"), str)
        or IDENTIFIER.fullmatch(invocation["run_id"]) is None
        or not isinstance(invocation.get("step_id"), str)
        or IDENTIFIER.fullmatch(invocation["step_id"]) is None
        or type(invocation.get("sequence")) is not int
        or not 0 <= invocation["sequence"] <= 2**64 - 1
        or not isinstance(invocation.get("handler_id"), str)
        or IDENTIFIER.fullmatch(invocation["handler_id"]) is None
        or not isinstance(invocation.get("input_json"), str)
    ):
        raise ValueError("invalid invocation values")
    stable_key = (
        f'{invocation["run_id"]}/{invocation["step_id"]}/{invocation["sequence"]}'
    )
    if value["workflow_id"] != stable_key:
        raise ValueError("workflow ID does not match the invocation")
    json.loads(invocation["input_json"])
    activity_options = value["activity"]
    if not isinstance(activity_options, dict) or set(activity_options) != {
        "start_to_close_timeout_ms",
        "schedule_to_close_timeout_ms",
        "heartbeat_timeout_ms",
        "retry",
    }:
        raise ValueError("invalid activity options")
    retry = activity_options["retry"]
    integer_fields = (
        activity_options.get("start_to_close_timeout_ms"),
        activity_options.get("schedule_to_close_timeout_ms"),
        retry.get("initial_interval_ms") if isinstance(retry, dict) else None,
        retry.get("backoff_coefficient_milli") if isinstance(retry, dict) else None,
        retry.get("maximum_interval_ms") if isinstance(retry, dict) else None,
        retry.get("maximum_attempts") if isinstance(retry, dict) else None,
    )
    if (
        not isinstance(retry, dict)
        or set(retry) != {
            "initial_interval_ms",
            "backoff_coefficient_milli",
            "maximum_interval_ms",
            "maximum_attempts",
        }
        or not all(type(item) is int and item > 0 for item in integer_fields)
        or retry["backoff_coefficient_milli"] < 1_000
        or retry["maximum_interval_ms"] < retry["initial_interval_ms"]
        or activity_options["schedule_to_close_timeout_ms"]
        < activity_options["start_to_close_timeout_ms"]
        or (
            activity_options["heartbeat_timeout_ms"] is not None
            and (
                type(activity_options["heartbeat_timeout_ms"]) is not int
                or activity_options["heartbeat_timeout_ms"] <= 0
                or activity_options["heartbeat_timeout_ms"]
                > activity_options["start_to_close_timeout_ms"]
            )
        )
    ):
        raise ValueError("invalid retry or timeout policy")
    return value


def validate_record(value: Any, invocation: dict[str, Any]) -> dict[str, Any]:
    common = {"version", "invocation", "input_sha256", "status"}
    if not isinstance(value, dict) or not common <= set(value):
        raise ValueError("invalid durable record")
    if value["version"] != 1 or value["invocation"] != invocation:
        raise ValueError("durable record does not match its invocation")
    digest = hashlib.sha256(invocation["input_json"].encode("utf-8")).hexdigest()
    if (
        not isinstance(value["input_sha256"], str)
        or not secrets.compare_digest(value["input_sha256"], digest)
    ):
        raise ValueError("durable record input digest does not match")
    status = value["status"]
    if status == "success":
        if (
            set(value) != common | {"output_json"}
            or not isinstance(value["output_json"], str)
        ):
            raise ValueError("invalid durable success record")
        json.loads(value["output_json"])
    elif status == "failure":
        if (
            set(value) != common | {"error_name", "retryable"}
            or not isinstance(value["error_name"], str)
            or IDENTIFIER.fullmatch(value["error_name"]) is None
            or not isinstance(value["retryable"], bool)
        ):
            raise ValueError("invalid durable failure record")
    elif status == "suspended":
        if (
            set(value) != common | {"suspension_reason", "state_json"}
            or value["suspension_reason"] not in SUSPENSION_REASONS
            or not isinstance(value["state_json"], str)
        ):
            raise ValueError("invalid durable suspension record")
        json.loads(value["state_json"])
    else:
        raise ValueError("invalid durable record status")
    return value


async def read_bounded(stream: asyncio.StreamReader, limit: int) -> bytes:
    try:
        return await stream.readexactly(limit + 1)
    except asyncio.IncompleteReadError as exc:
        return exc.partial


class CommandActivity:
    def __init__(self, config: Config) -> None:
        self.config = config

    @activity.defn(name=ACTIVITY_NAME)
    async def execute(self, request: dict[str, Any]) -> str:
        invocation = request["invocation"]
        registration = self.config.handlers[
            (invocation["kind"], invocation["handler_id"])
        ]
        activity.heartbeat("starting ZigAI worker")
        process = await asyncio.create_subprocess_exec(
            *registration.command,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        assert process.stdin is not None
        assert process.stdout is not None
        assert process.stderr is not None
        process.stdin.write(
            json.dumps(invocation, separators=(",", ":")).encode("utf-8") + b"\n"
        )
        stdout_task = asyncio.create_task(
            read_bounded(process.stdout, self.config.max_record_bytes)
        )
        stderr_task = asyncio.create_task(read_bounded(process.stderr, 64 * 1024))
        try:
            await process.stdin.drain()
            process.stdin.close()
            done, pending = await asyncio.wait(
                {stdout_task, stderr_task}, return_when=asyncio.FIRST_COMPLETED
            )
            limits = {
                stdout_task: self.config.max_record_bytes,
                stderr_task: 64 * 1024,
            }
            if any(len(task.result()) > limits[task] for task in done):
                process.kill()
                for task in pending:
                    task.cancel()
                await asyncio.gather(*pending, return_exceptions=True)
                await process.wait()
                raise ApplicationError(
                    "ZigAI worker output exceeded its limit",
                    type="ZigAIWorkerOutputTooLarge",
                    non_retryable=True,
                )
            stdout, stderr = await asyncio.gather(stdout_task, stderr_task)
        except BaseException:
            stdout_task.cancel()
            stderr_task.cancel()
            await asyncio.gather(stdout_task, stderr_task, return_exceptions=True)
            if process.returncode is None:
                process.kill()
                await process.wait()
            raise
        if len(stdout) > self.config.max_record_bytes or len(stderr) > 64 * 1024:
            if process.returncode is None:
                process.kill()
                await process.wait()
            raise ApplicationError(
                "ZigAI worker output exceeded its limit",
                type="ZigAIWorkerOutputTooLarge",
                non_retryable=True,
            )
        return_code = await process.wait()
        if return_code != 0:
            detail = stderr.decode("utf-8", errors="replace")
            raise ApplicationError(
                f"ZigAI worker exited with {return_code}: {detail}",
                type="ZigAIWorkerFailed",
            )
        try:
            record = json.loads(stdout)
            validate_record(record, invocation)
        except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
            raise ApplicationError(
                "ZigAI worker returned an invalid record",
                type="ZigAIInvalidRecord",
                non_retryable=True,
            ) from exc
        activity.heartbeat("ZigAI worker completed")
        return stdout.decode("utf-8")


def create_app(
    client: Client,
    config: Config,
    namespace: str,
    bearer_token: str | None,
) -> web.Application:
    async def execute(request: web.Request) -> web.Response:
        if bearer_token is not None:
            supplied = request.headers.get("authorization", "")
            if not secrets.compare_digest(supplied, bearer_token):
                raise web.HTTPUnauthorized()
        if (
            request.content_length is not None
            and request.content_length > config.max_request_bytes
        ):
            raise web.HTTPRequestEntityTooLarge(
                max_size=config.max_request_bytes,
                actual_size=request.content_length,
            )
        body = await request.read()
        if len(body) > config.max_request_bytes:
            raise web.HTTPRequestEntityTooLarge(
                max_size=config.max_request_bytes,
                actual_size=len(body),
            )
        try:
            value = validate_request(json.loads(body), config, namespace)
        except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
            raise web.HTTPBadRequest(text=str(exc)) from exc
        workflow_id = value["workflow_id"]
        try:
            result = await client.execute_workflow(
                OperationWorkflow.run,
                value,
                id=workflow_id,
                task_queue=config.task_queue,
                id_reuse_policy=WorkflowIDReusePolicy.REJECT_DUPLICATE,
            )
        except WorkflowAlreadyStartedError:
            result = await client.get_workflow_handle(workflow_id).result()
        if (
            not isinstance(result, str)
            or len(result.encode("utf-8")) > config.max_record_bytes
        ):
            raise web.HTTPBadGateway(text="Temporal returned an invalid ZigAI record")
        return web.Response(
            status=200,
            text=result,
            content_type="application/json",
        )

    app = web.Application(client_max_size=config.max_request_bytes)
    app.router.add_post("/v1/execute", execute)
    return app


async def serve(config_path: Path) -> None:
    config = load_config(config_path)
    address = os.environ.get("TEMPORAL_ADDRESS", "localhost:7233")
    namespace = os.environ.get("TEMPORAL_NAMESPACE", "default")
    api_key = os.environ.get("TEMPORAL_API_KEY") or None
    bearer_token = os.environ.get("ZIGAI_TEMPORAL_SIDECAR_TOKEN") or None
    client = await Client.connect(
        address,
        namespace=namespace,
        api_key=api_key,
        tls=True if api_key else False,
    )
    worker = Worker(
        client,
        task_queue=config.task_queue,
        workflows=[OperationWorkflow],
        activities=[CommandActivity(config).execute],
    )
    runner = web.AppRunner(create_app(client, config, namespace, bearer_token))
    await runner.setup()
    site = web.TCPSite(runner, config.listen, config.port)
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for name in ("SIGINT", "SIGTERM"):
        if hasattr(signal, name):
            loop.add_signal_handler(getattr(signal, name), stop.set)
    async with worker:
        await site.start()
        await stop.wait()
    await runner.cleanup()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--config",
        type=Path,
        default=Path("worker.toml"),
        help="TOML worker registration file",
    )
    args = parser.parse_args()
    asyncio.run(serve(args.config))


if __name__ == "__main__":
    main()
