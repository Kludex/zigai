"""Deterministic Temporal workflow for one ZigAI durable operation."""

from datetime import timedelta
from typing import Any

from temporalio import workflow
from temporalio.common import RetryPolicy

WORKFLOW_NAME = "zigai.operation.v1"
ACTIVITY_NAME = "zigai.execute.v1"


@workflow.defn(name=WORKFLOW_NAME)
class OperationWorkflow:
    @workflow.run
    async def run(self, request: dict[str, Any]) -> str:
        options = request["activity"]
        retry = options["retry"]
        heartbeat_ms = options["heartbeat_timeout_ms"]
        return await workflow.execute_activity(
            ACTIVITY_NAME,
            request,
            result_type=str,
            task_queue=request["task_queue"],
            start_to_close_timeout=timedelta(
                milliseconds=options["start_to_close_timeout_ms"]
            ),
            schedule_to_close_timeout=timedelta(
                milliseconds=options["schedule_to_close_timeout_ms"]
            ),
            heartbeat_timeout=(
                timedelta(milliseconds=heartbeat_ms)
                if heartbeat_ms is not None
                else None
            ),
            retry_policy=RetryPolicy(
                initial_interval=timedelta(milliseconds=retry["initial_interval_ms"]),
                backoff_coefficient=retry["backoff_coefficient_milli"] / 1000,
                maximum_interval=timedelta(milliseconds=retry["maximum_interval_ms"]),
                maximum_attempts=retry["maximum_attempts"],
            ),
        )
