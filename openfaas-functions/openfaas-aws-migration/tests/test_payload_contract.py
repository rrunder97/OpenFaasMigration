import json

from handler import handle
from sqs_worker import _load_message_payload


def test_handle_accepts_customer_and_org_ids_payload():
    request_payload = {"customer": "acme", "Org_Ids": [101]}

    result = handle(json.dumps(request_payload))

    assert isinstance(result, dict)
    assert result["ok"] is True
    assert result["customer"] == "acme"
    assert result["Org_Ids"] == [101]
    assert result["received_event"] == request_payload


def test_worker_payload_loader_supports_direct_message_body():
    message = {
        "Body": json.dumps({"customer": "acme", "Org_Ids": [101]}),
        "MessageId": "msg-123",
    }

    payload, job_id = _load_message_payload(message)

    assert payload == {"customer": "acme", "Org_Ids": [101]}
    assert job_id == "msg-123"


def test_worker_payload_loader_supports_wrapped_payload_shape():
    message = {
        "Body": json.dumps(
            {
                "job_id": "job-abc",
                "payload": {"customer": "acme", "Org_Ids": [101]},
            }
        ),
        "MessageId": "msg-123",
    }

    payload, job_id = _load_message_payload(message)

    assert payload == {"customer": "acme", "Org_Ids": [101]}
    assert job_id == "job-abc"


def test_handle_rejects_missing_customer():
    result = handle(json.dumps({"Org_Ids": [101]}))

    assert isinstance(result, dict)
    assert result["ok"] is False
    assert result["code"] == "INVALID_PAYLOAD"


def test_handle_rejects_missing_org_ids():
    result = handle(json.dumps({"customer": "acme"}))

    assert isinstance(result, dict)
    assert result["ok"] is False
    assert result["code"] == "INVALID_PAYLOAD"


def test_handle_rejects_multiple_org_ids_for_one_customer():
    result = handle(json.dumps({"customer": "acme", "Org_Ids": [101, 102]}))

    assert isinstance(result, dict)
    assert result["ok"] is False
    assert result["code"] == "INVALID_PAYLOAD"
