# OpenFaaS to ECS/Fargate Migration Overview

This repository runs an async-first AWS job pipeline for long-running work. Requests are accepted quickly at the API edge, queued durably in SQS, and processed by ECS/Fargate workers independent of HTTP request lifetime. This design reduces timeout risk, improves resilience with retries + DLQ, and gives controlled scaling with queue-driven autoscaling.

## Primary Docs (Use These First)

- `docs/Engineer Guide.md`: command-first build, deploy, rollout, smoke test, and GitHub round-trip flow
- `docs/EngineeringHandoff.md`: day-2 ownership, rollback playbooks, and operational triage
- `docs/Day1Onboarding.md`: first-day setup and orientation
- `docs/SecretsProcess.md`: secrets lifecycle and ownership
- `docs/ECS-IAM-and-Secrets.md`: IAM role and secret injection details
- `docs/AWSAsyncArchitectureDetailed.md` and `docs/AWSServiceFlowHighLevel.md`: architecture visuals

## 1) Architecture at a Glance

1. Client submits `POST /jobs` with JSON payload.
2. API Gateway enqueues the request body into SQS.
3. ECS/Fargate worker polls SQS and loads the payload.
4. Shared business flow executes in `handler.process_event(...)`.
5. Worker tracks job state in DynamoDB (`PENDING` -> `RUNNING` -> `SUCCEEDED`/`FAILED`).

Core AWS services:

- API Gateway (ingestion)
- SQS + DLQ (buffer and failure isolation)
- ECS/Fargate (worker compute)
- DynamoDB (job status tracking)
- ECR (image registry)
- CloudWatch (logs, alarms, autoscaling signals)
- IAM (least-privilege runtime/integration access)

## 2) Payload and Invocation Contract

Public invocation endpoint:

- `POST /jobs`

Payload contract currently enforced by app logic:

- `customer` is required and non-empty
- `Org_Ids` is required
- `Org_Ids` must contain exactly one ID

Valid example:

```json
{"customer":"acme","Org_Ids":[101]}
```

Invalid example:

```json
{"customer":"acme","Org_Ids":[101,102]}
```

Invocation semantics:

- API response is async acceptance (`202` behavior)
- final outcome is observed via worker logs and DynamoDB job status

## 3) Process Flow (Code-Level Mental Model)

- Queue worker entrypoint: `openfaas-functions/openfaas-aws-migration/sqs_worker.py`
- Shared validation/business flow: `openfaas-functions/openfaas-aws-migration/handler.py`
- Job status persistence: `openfaas-functions/openfaas-aws-migration/job_status_store.py`

End-to-end processing:

- `sqs_worker.run()` long-polls SQS
- `_load_message_payload(...)` extracts payload + `job_id`
- worker calls `process_event(payload, request_id=job_id)`
- status transitions are written to DynamoDB
- message is deleted on success, retried/DLQ on failure

## 4) Quick Deployment Steps (Reference Full Guides)

Use this as the short path, then follow the detailed commands in `docs/Engineer Guide.md` and operational context in `docs/EngineeringHandoff.md`.

1. Prepare `terraform/backend.hcl` and `terraform/terraform.tfvars` from examples.
2. Run Terraform bootstrap/apply for base infrastructure (`terraform init`, `plan`, `apply`).
3. Build and push worker image to ECR with a unique tag.
4. Set `image_tag` + desired worker count in `terraform.tfvars`, then apply again.
5. Smoke test `api_jobs_submit_url` with valid payload and confirm processing in logs/status table.

## 5) Summary

This system is built for reliable async execution, not synchronous request/response compute. API Gateway is a fast intake layer, SQS is the durable work queue, ECS workers run the real business logic, and DynamoDB records lifecycle state.

Reliability and operations controls currently configured:

- **DLQ**: `terraform/sqs.tf` defines a dedicated DLQ (`aws_sqs_queue.jobs_dlq`) and redrive policy on the primary queue.
- **Visibility timeout controls**: `terraform/sqs.tf` sets queue visibility timeout from `sqs_visibility_timeout_seconds`, and `sqs_worker.py` requires `SQS_VISIBILITY_TIMEOUT` at runtime and fails fast if it is missing or too low for expected job duration.
- **Retries**: SQS retries are controlled by `sqs_max_receive_count` before DLQ handoff; worker exceptions intentionally leave messages undeleted so SQS can retry, while malformed non-retryable messages are deleted to avoid poison loops.
- **Autoscaling**: `terraform/autoscaling.tf` configures ECS service desired-count autoscaling with scale-out and scale-in policies bounded by `worker_min_capacity` and `worker_max_capacity`.
- **CloudWatch alarms**: `terraform/monitoring.tf` and `terraform/autoscaling.tf` create queue health alarms (oldest message age, DLQ presence, backlog thresholds) and wire scaling alarms to autoscaling actions.

Together, these controls make the platform safer for long-running, variable-load workloads and easier to operate in production.
