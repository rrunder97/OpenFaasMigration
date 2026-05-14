# AWS Async Architecture (Detailed)

This document describes the deployed async architecture for the OpenFaaS migration, including route behavior, queue processing, state management, monitoring, and DLQ reprocessing.

## 1) End-to-End Request Route

1. Caller sends `POST /jobs` with a JSON payload.
2. API Gateway REST API receives the request.
3. API Gateway uses AWS service integration to call SQS `SendMessage`.
4. SQS `jobs` queue stores the payload.
5. ECS/Fargate worker (`sqs_worker.py`) long-polls and receives the message.
6. Worker calls shared business logic (`process_event()` in `handler.py`).
7. Worker updates DynamoDB status table (`job_status`).
8. On success, worker deletes the SQS message.
9. On processing exception, message is retried by SQS and eventually moved to DLQ after `maxReceiveCount`.

```mermaid
sequenceDiagram
    autonumber
    participant C as Client
    participant APIGW as API Gateway (REST)
    participant Q as SQS jobs queue
    participant W as ECS/Fargate Worker
    participant H as handler.process_event()
    participant DDB as DynamoDB job_status
    participant DLQ as SQS jobs_dlq

    C->>APIGW: POST /jobs (JSON)
    APIGW->>Q: SendMessage(MessageBody=input.body)
    APIGW-->>C: 202 ACCEPTED

    W->>Q: receive_message (long poll)
    Q-->>W: Message + ReceiptHandle
    W->>DDB: create/update status (PENDING/RUNNING)
    W->>H: process_event(payload, request_id)
    alt Success
        H-->>W: result
        W->>DDB: mark SUCCEEDED
        W->>Q: delete_message(ReceiptHandle)
    else Processing Exception
        H--xW: exception
        W->>DDB: mark FAILED (best effort)
        Note over Q: Message becomes visible again after visibility timeout
        Note over Q,DLQ: After maxReceiveCount, SQS moves message to DLQ
    end
```

## 2) API Gateway to SQS Integration Details

- Route: `POST /jobs`
- Integration type: API Gateway -> AWS service (SQS)
- Mapping template:

```
Action=SendMessage&MessageBody=$util.urlEncode($input.body)
```

- Response semantics: accepted/async (`202` style contract)

## 3) Queueing and Processing Semantics

- Primary queue: `jobs`
- DLQ: `jobs_dlq` via `redrive_policy`
- Worker runtime: `openfaas-functions/openfaas-aws-migration/sqs_worker.py`
- Processing characteristics:
  - long polling (`WaitTimeSeconds`)
  - visibility timeout configured for long-running jobs
  - configurable message batch size
  - malformed payloads are treated as non-retryable and deleted
  - processing exceptions are retryable (message not deleted)

## 4) Job State Model (DynamoDB)

Status table is used to track async lifecycle by `job_id`.

```mermaid
stateDiagram-v2
    [*] --> PENDING
    PENDING --> RUNNING
    RUNNING --> SUCCEEDED
    RUNNING --> FAILED
```

Typical status fields:

- `job_id` (partition key)
- `status` (`PENDING`, `RUNNING`, `SUCCEEDED`, `FAILED`)
- `submitted_at`, `started_at`, `completed_at`, `updated_at`
- `outcome_code`
- `result` (on success) or `error_message` (on failure)

## 5) Monitoring, Alerting, and Scaling

### CloudWatch alarms

- Queue backlog (`ApproximateNumberOfMessagesVisible`)
- Oldest message age (`ApproximateAgeOfOldestMessage`)
- DLQ has messages (`jobs_dlq` visible messages > 0)

### Autoscaling

- ECS service desired count scales from SQS backlog thresholds (scale out/in policies).

### Logs

- Worker logs to CloudWatch log group `/ecs/<name_prefix>`.

## 6) DLQ Reprocessing (Operational Flow)

DLQ is the safety boundary for messages that exceeded retry limits.

```mermaid
flowchart TD
    A[DLQ Alarm Triggers] --> B[Inspect failed payloads and errors]
    B --> C{Transient or Permanent?}
    C -->|Transient| D[Fix dependency/config issue]
    C -->|Permanent| E[Correct payload or reject job]
    D --> F[Redrive DLQ messages to jobs queue]
    E --> F
    F --> G[Monitor queue age/backlog and status transitions]
    G --> H[Close incident after successful drain]
```

Recommended redrive options:

- SQS redrive task from DLQ to source queue
- controlled/scripted replay from DLQ to `jobs` queue
- rate limit replay during incident recovery to avoid worker saturation

## 7) Notes for Architecture Reviews

- This is an async-first design: HTTP is submission only, not compute execution.
- Reliability comes from queue buffering, retries, and DLQ isolation.
- Throughput comes from worker autoscaling and decoupled processing.
- Status visibility comes from DynamoDB lifecycle tracking.
