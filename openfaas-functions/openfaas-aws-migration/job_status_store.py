"""Optional DynamoDB-backed job status persistence for async processing."""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Any

import boto3
from botocore.exceptions import ClientError

from helpers.config_helper import get_env
from helpers.logging_helper import get_logger

logger = get_logger(__name__)


def _utc_now_iso() -> str:
    return datetime.now(UTC).isoformat(timespec="seconds")


class JobStatusStore:
    """Small helper around a DynamoDB table keyed by `job_id`."""

    def __init__(self, table_name: str) -> None:
        self.table = boto3.resource("dynamodb").Table(table_name)

    def create_pending(self, job_id: str) -> None:
        timestamp = _utc_now_iso()
        self.table.put_item(
            Item={
                "job_id": job_id,
                "status": "PENDING",
                "submitted_at": timestamp,
                "updated_at": timestamp,
            },
            ConditionExpression="attribute_not_exists(job_id)",
        )

    def mark_running(self, job_id: str) -> None:
        timestamp = _utc_now_iso()
        self.table.update_item(
            Key={"job_id": job_id},
            UpdateExpression="SET #status = :status, started_at = :started_at, updated_at = :updated_at",
            ExpressionAttributeNames={"#status": "status"},
            ExpressionAttributeValues={
                ":status": "RUNNING",
                ":started_at": timestamp,
                ":updated_at": timestamp,
            },
        )

    def mark_succeeded(self, job_id: str, result: dict[str, Any] | None = None) -> None:
        timestamp = _utc_now_iso()
        expression = (
            "SET #status = :status, completed_at = :completed_at, "
            "updated_at = :updated_at, outcome_code = :outcome_code"
        )
        values: dict[str, Any] = {
            ":status": "SUCCEEDED",
            ":completed_at": timestamp,
            ":updated_at": timestamp,
            ":outcome_code": 200,
        }
        if result is not None:
            expression += ", result = :result"
            values[":result"] = result

        self.table.update_item(
            Key={"job_id": job_id},
            UpdateExpression=expression,
            ExpressionAttributeNames={"#status": "status"},
            ExpressionAttributeValues=values,
        )

    def mark_failed(self, job_id: str, error_message: str, outcome_code: int = 500) -> None:
        timestamp = _utc_now_iso()
        self.table.update_item(
            Key={"job_id": job_id},
            UpdateExpression=(
                "SET #status = :status, completed_at = :completed_at, updated_at = :updated_at, "
                "outcome_code = :outcome_code, error_message = :error_message"
            ),
            ExpressionAttributeNames={"#status": "status"},
            ExpressionAttributeValues={
                ":status": "FAILED",
                ":completed_at": timestamp,
                ":updated_at": timestamp,
                ":outcome_code": outcome_code,
                ":error_message": error_message[:1000],
            },
        )

    def get(self, job_id: str) -> dict[str, Any] | None:
        response = self.table.get_item(Key={"job_id": job_id})
        return response.get("Item")


def get_job_status_store() -> JobStatusStore | None:
    """Return a store when JOB_STATUS_TABLE is configured, else None."""
    table_name = get_env("JOB_STATUS_TABLE")
    if not table_name:
        return None
    return JobStatusStore(table_name)


def safe_update(action_name: str, callback: Any) -> None:
    """Run a DynamoDB status update and swallow non-fatal update failures."""
    try:
        callback()
    except ClientError:
        logger.exception("job status update failed during %s", action_name)
