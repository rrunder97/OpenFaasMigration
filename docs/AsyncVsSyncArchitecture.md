# Async vs Sync Architecture (AWS Reference)

This is a practical reference for deciding between synchronous HTTP invocation and asynchronous queue-driven processing for ECS/Fargate workloads.

## 1) Two Patterns at a Glance

### Synchronous (`ALB -> ECS service -> response`)

- Best for short requests where the caller can wait for the full result.
- Request stays open until function logic finishes.
- Simpler flow, but long-running jobs are more fragile.

### Asynchronous (`HTTP submit -> SQS -> ECS worker`)

- Best for long-running workloads (for example, ~30 minutes).
- HTTP request returns quickly (`202 Accepted` + `job_id`).
- Worker processes in background and status is read separately.

## 2) AWS Services Used

### Sync path

- **Application Load Balancer (ALB)**: receives HTTP traffic and forwards to ECS.
- **ECS/Fargate Service**: runs the worker container (`sqs_worker.py`) and business logic (`handler.py`).
- **ECR**: container image registry.
- **CloudWatch Logs/Metrics**: runtime logs and service metrics.

### Async path

- **API Gateway or ALB**: front door for `POST /jobs` and `GET /jobs/{id}`.
- **Submit API (FastAPI/Lambda/ECS endpoint)**: validates payload, creates `job_id`, enqueues message.
- **SQS Queue + DLQ**: durable buffering, retry handling, dead-letter routing.
- **ECS/Fargate Worker Service**: polls queue and executes work.
- **DynamoDB (recommended)**: job status/result store (`PENDING`, `RUNNING`, `SUCCEEDED`, `FAILED`).
- **IAM Roles/Policies**: controlled access for queue, logs, and status store.
- **CloudWatch**: worker and API observability.

## 3) Request and Traffic Flow

### Sync traffic flow

1. Client sends HTTP request.
2. ALB forwards request to ECS task.
3. App executes function logic inline.
4. Response returns on the same HTTP connection.

Key point: caller waits for completion.

### Async traffic flow

1. Client sends `POST /jobs` with payload.
2. Submit API validates request, creates `job_id`, writes initial status (`PENDING`), enqueues SQS message.
3. Submit API returns `202` immediately with `job_id`.
4. ECS worker polls SQS, sets status to `RUNNING`, executes logic, then updates terminal status (`SUCCEEDED` or `FAILED`).
5. Client checks progress via `GET /jobs/{id}` (or callback/webhook pattern).

Key point: job execution is decoupled from the HTTP connection.

## 4) Timeouts and Reliability

### Sync model risks for long jobs

- Depends on end-to-end timeout alignment (client, proxy, ALB, app server).
- If connection drops, caller may not know final job outcome.
- Retries can create duplicate processing without idempotency controls.

### Async model strengths

- No long-held HTTP connection required.
- SQS + DLQ improves resilience and controlled retries.
- Queue absorbs bursts and provides backpressure.
- Easier horizontal scaling based on queue depth/age.

## 5) Function Code Structure (Do Not Duplicate Business Logic)

Use one shared core function and thin transport adapters:

- **Core logic**: business behavior in shared module (for example, `process_event(...)` in `handler.py`).
- **Sync adapter**: optional HTTP route parses body and calls core logic.
- **Async adapter**: SQS worker loop parses message and calls same core logic, then writes status.

This avoids maintaining separate implementations per function.

## 6) Recommended Choice for ~30 Minute Jobs

For workloads that regularly run around 30 minutes, use async as the primary architecture:

- `POST /jobs` -> enqueue -> return `202`
- Worker executes from SQS
- `GET /jobs/{id}` for status/result

Keep sync invocation only as a temporary migration path where necessary.

## 7) Minimal Contracts to Standardize

### Submit API contract (`POST /jobs`)

- Request: `job_type`, `payload`, optional `idempotency_key`
- Response: `job_id`, `status=PENDING`, `submitted_at`

### Queue message contract

- `job_id`
- `job_type`
- `payload`
- `submitted_at`
- `correlation_id` (recommended for tracing)

### Status contract (`GET /jobs/{id}`)

- `job_id`
- `status`
- `submitted_at`
- `started_at` (optional)
- `completed_at` (optional)
- `result` (optional)
- `error` (optional)

## 8) Production Weak Points for Long-Running Async Jobs

Focus checks before go-live:

- **No persistent status store**
  - Risk: callers cannot reliably determine final success/failure.
  - Mitigation: persist lifecycle state in DynamoDB and expose `GET /jobs/{id}`.
- **Missing IAM permissions for runtime calls**
  - Risk: enqueue, receive/delete, or status updates fail at runtime.
  - Mitigation: explicit ECS task role permissions for SQS and DynamoDB.
- **Worker not packaged or not started in worker mode**
  - Risk: messages queue up forever with no consumers.
  - Mitigation: include worker in image and run dedicated ECS service/task with worker entry mode.
- **SQS visibility timeout lower than job runtime**
  - Risk: duplicate processing while first attempt is still running.
  - Mitigation: set visibility timeout above worst-case runtime (or heartbeat with visibility extensions).
- **No DLQ / redrive policy**
  - Risk: poison messages cause infinite retries and queue churn.
  - Mitigation: configure DLQ and max receive count.
- **No idempotency controls**
  - Risk: retries or duplicate submits repeat side effects.
  - Mitigation: use idempotency keys and duplicate-safe write logic.
- **No queue-driven autoscaling**
  - Risk: backlog growth under burst traffic.
  - Mitigation: scale workers on queue depth and message age alarms.

## 9) Current Repo Hardening Changes (Async)

Implemented in this repo to reduce async production risk:

- Added DynamoDB job state integration directly in worker processing flow.
- Updated worker payload handling to support direct API Gateway -> SQS message bodies.
- Updated Docker image to run worker-only runtime (`sqs_worker.py`).
- Removed API service routing dependencies (no ALB or VPC Link in active async path).
- Added API Gateway direct integration to SQS submit route.
- Added Terraform-managed SQS queue, DLQ, and DynamoDB status table.
- Added Terraform IAM task-role policy for SQS + DynamoDB runtime access.

## 10) Common Mistakes to Avoid (Now Addressed)

- **Forgetting to delete messages after processing**
  - Why it matters: if successful messages are not deleted, they reappear and run again.
  - How addressed now:
    - Worker explicitly deletes SQS message on successful processing.
    - Worker also deletes malformed/non-retryable messages to prevent poison-message loops.
    - Worker intentionally does not delete on processing exceptions so retries and DLQ behavior still work.

- **Visibility timeout too short**
  - Why it matters: message becomes visible while first worker is still running, causing duplicate processing.
  - How addressed now:
    - Terraform defaults queue visibility timeout to `3600` seconds for long-running jobs.
    - Worker startup now validates `SQS_VISIBILITY_TIMEOUT >= MIN_EXPECTED_JOB_DURATION_SECONDS` and fails fast if misconfigured.
    - Worker service injects `SQS_VISIBILITY_TIMEOUT` from Terraform so runtime config stays aligned.
