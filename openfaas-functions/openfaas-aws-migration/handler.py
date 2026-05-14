"""Shared handler logic for both raw-body and SQS-driven invocation paths."""

from __future__ import annotations

import json
import uuid
from typing import Any

from helpers.config_helper import get_env, load_app_config
from helpers.logging_helper import get_logger
from helpers.response_helper import error_response, success_response
from helpers.utils import create_ecs_timestamp

FUNCTION_NAME = "openfaas-aws-migration"

logger = get_logger(__name__)


def parse_request_body(req: str) -> tuple[dict[str, Any] | None, tuple[str, int] | None]:
    """Parse and validate raw JSON request string into an object payload."""
    try:
        parsed = json.loads(req)
    except json.decoder.JSONDecodeError:
        return None, ("Unable to convert to JSON.", 400)
    except ValueError:
        return None, ("Decoding JSON has failed.", 400)

    if not isinstance(parsed, dict):
        return None, ("JSON body must be an object.", 400)

    return parsed, None


def process_event(event: dict[str, Any], request_id: str | None = None) -> dict[str, Any]:
    """Shared execution path used by both HTTP invoke and SQS worker processing."""
    customer = event.get("customer")
    org_ids = event.get("Org_Ids")
    if customer in (None, "") or not isinstance(org_ids, list) or len(org_ids) != 1:
        return error_response(
            message="customer and Org_Ids are required with a 1:1 mapping; Org_Ids must contain exactly one id.",
            code="INVALID_PAYLOAD",
            extra={"received_customer": customer, "received_Org_Ids": org_ids},
        )

    function_start_time = create_ecs_timestamp()
    function_client_count = 0
    logger.info("START: Function %s", FUNCTION_NAME)

    generated_request_id = request_id or str(uuid.uuid4())

    gso_client = None
    kafka_client = None
    snow_client = None
    bitbucket_client = None
    helper_clients_list: list[Any] = []

    return function_handler(
        event=event,
        context={
            "request_id": generated_request_id,
            "function_start_time": function_start_time,
            "function_client_count": function_client_count,
            "gso_client": gso_client,
            "kafka_client": kafka_client,
            "snow_client": snow_client,
            "bitbucket_client": bitbucket_client,
            "helper_clients_list": helper_clients_list,
        },
    )


def handle(req: str) -> tuple[str, int] | dict[str, Any]:
    """
    Handle a request using the familiar OpenFaaS-style raw-string entrypoint.

    Args:
        req: Raw request body string.

    Returns:
        A JSON-serializable dict on success, or a `(message, status_code)` tuple on parse errors.
    """
    payload, parse_error = parse_request_body(req)
    if parse_error:
        return parse_error

    return process_event(payload)


def function_handler(event: dict[str, Any], context: Any = None) -> dict[str, Any]:
    """
    Framework-independent business logic entrypoint.

    This function is intentionally runtime-agnostic. It can be called from:
    - `handle(req)` when using the raw-string compatibility entrypoint
    - `process_event(...)` when invoked from the SQS worker
    """
    env = get_env("ENV", "dev")
    log_level = get_env("LOG_LEVEL", "INFO")
    app_config = load_app_config()
    request_id = context.get("request_id") if context else None
    logger.info(
        "Running function in ENV=%s, LOG_LEVEL=%s, request_id=%s",
        env,
        log_level,
        request_id,
    )

    # ==================================================
    # PASTE EXISTING OPENFAAS BUSINESS LOGIC BELOW
    # Keep the real business logic here, not in transport adapters.
    # Use the context dict above if your old handler relied on request metadata
    # or initialized clients.
    # ==================================================

    return success_response(
        data={
            "message": "Function executed successfully",
            "function": FUNCTION_NAME,
            "env": env,
            "log_level": log_level,
            "request_id": request_id,
            "customer": event.get("customer"),
            "Org_Ids": event.get("Org_Ids", []),
            "received_event": event,
            "app_config_loaded": bool(app_config),
        }
    )
