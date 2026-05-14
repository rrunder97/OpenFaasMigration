"""Long-running SQS worker process for ECS/Fargate tasks."""

from __future__ import annotations

import json
import time
from typing import Any

import boto3

from handler import process_event
from helpers.config_helper import get_env
from helpers.logging_helper import get_logger
from job_status_store import get_job_status_store, safe_update

logger = get_logger(__name__)


def _load_message_payload(message: dict[str, Any]) -> tuple[dict[str, Any] | None, str | None]:
    """Extract application payload and job metadata from SQS message body."""
    try:
        body = json.loads(message["Body"])
    except (TypeError, ValueError):
        return None, None

    if not isinstance(body, dict):
        return None, None

    # Support both direct body payload and wrapped body payload for compatibility.
    payload = body.get("payload", body)
    if not isinstance(payload, dict):
        return None, None

    job_id = body.get("job_id") or message.get("MessageId")
    return payload, job_id


def run() -> None:
    queue_url = get_env("SQS_QUEUE_URL")
    if not queue_url:
        raise RuntimeError("SQS_QUEUE_URL is required for sqs_worker.")

    wait_time_seconds = int(get_env("SQS_WAIT_TIME_SECONDS", "20") or "20")
    # Critical reliability control: require explicit visibility timeout so there
    # is no hidden fallback drift between environments. In ECS this is injected
    # from Terraform var.sqs_visibility_timeout_seconds.
    visibility_timeout_value = get_env("SQS_VISIBILITY_TIMEOUT")
    if not visibility_timeout_value:
        raise RuntimeError(
            "SQS_VISIBILITY_TIMEOUT is required. Set it explicitly (ECS/Terraform injects this value)."
        )
    visibility_timeout = int(visibility_timeout_value)
    min_expected_job_duration_seconds = int(get_env("MIN_EXPECTED_JOB_DURATION_SECONDS", "1800") or "1800")
    max_messages = int(get_env("SQS_MAX_MESSAGES", "1") or "1")
    poll_interval_seconds = float(get_env("SQS_EMPTY_POLL_SLEEP_SECONDS", "1.0") or "1.0")

    if visibility_timeout < min_expected_job_duration_seconds:
        raise RuntimeError(
            "SQS_VISIBILITY_TIMEOUT is lower than MIN_EXPECTED_JOB_DURATION_SECONDS. "
            "Increase visibility timeout to avoid duplicate processing for long-running jobs."
        )

    sqs_client = boto3.client("sqs")
    job_status_store = get_job_status_store()
    logger.info("SQS worker started. queue_url=%s", queue_url)

    while True:
        response = sqs_client.receive_message(
            QueueUrl=queue_url,
            MaxNumberOfMessages=max_messages,
            WaitTimeSeconds=wait_time_seconds,
            VisibilityTimeout=visibility_timeout,
            MessageAttributeNames=["All"],
        )
        messages = response.get("Messages", [])

        if not messages:
            time.sleep(poll_interval_seconds)
            continue

        for message in messages:
            receipt_handle = message["ReceiptHandle"]
            payload, job_id = _load_message_payload(message)

            if payload is None:
                logger.warning("Dropping malformed SQS message: %s", message.get("MessageId"))
                if job_id and job_status_store:
                    safe_update(
                        "worker:mark_failed_malformed_message",
                        lambda: job_status_store.mark_failed(job_id, "Malformed SQS message body.", outcome_code=400),
                    )
                # Malformed payloads are non-retryable; delete to prevent poison-loop retries.
                sqs_client.delete_message(QueueUrl=queue_url, ReceiptHandle=receipt_handle)
                continue

            try:
                if job_id and job_status_store:
                    safe_update("worker:create_pending", lambda: job_status_store.create_pending(job_id))
                    safe_update("worker:mark_running", lambda: job_status_store.mark_running(job_id))
                result = process_event(payload, request_id=job_id)
                logger.info("Processed job_id=%s result_ok=%s", job_id, bool(result.get("ok")))
                if job_id and job_status_store:
                    safe_update("worker:mark_succeeded", lambda: job_status_store.mark_succeeded(job_id, result=result))
                # Successful processing must be followed by message deletion.
                sqs_client.delete_message(QueueUrl=queue_url, ReceiptHandle=receipt_handle)
            except Exception:  # noqa: BLE001
                logger.exception("Worker failed job_id=%s. Message will be retried.", job_id)
                if job_id and job_status_store:
                    safe_update(
                        "worker:mark_failed",
                        lambda: job_status_store.mark_failed(job_id, "Worker failed processing job.", outcome_code=500),
                    )


if __name__ == "__main__":
    run()
