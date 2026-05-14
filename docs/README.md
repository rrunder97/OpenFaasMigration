# OpenFaaS to ECS/Fargate Migration Overview

This project now uses a direct async architecture designed for long-running jobs.

For first-day setup and first deploy steps, see `docs/Day1Onboarding.md`.
For a command-by-command junior engineer handoff (local -> AWS deploy -> test), see `docs/JuniorEngineerContainerizeDeployTestGuide.md`.
For operational ownership and runbook guidance, see `docs/EngineeringHandoff.md`.
For config and secrets ownership details, see `docs/SecretsProcess.md`.
For ECS IAM role and secret-injection onboarding, see `docs/ECS-IAM-and-Secrets.md`.
For architecture diagrams and presentation assets, see:

- `docs/AWSAsyncArchitectureDetailed.md`
- `docs/AWSServiceFlowHighLevel.md`

## 1) Current Target Architecture

1. Caller sends `POST /jobs` with JSON payload.
2. API Gateway writes the payload directly to SQS.
3. ECS/Fargate worker service polls the queue.
4. Worker executes business logic in `handler.py`.
5. Worker writes status updates to DynamoDB.
6. CloudWatch captures worker logs and queue alarms monitor backlog/DLQ.

AWS services in the path:

- API Gateway (REST API)
- SQS queue + DLQ
- ECS/Fargate worker service
- DynamoDB status table
- CloudWatch logs/alarms
- ECR image registry
- IAM roles/policies

## 2) Invocation Contract

Endpoint:

- `POST /jobs` via API Gateway

Body:

- JSON object (worker accepts direct object payload)

Example:

```json
{"customer":"acme","Org_Ids":[101,102]}
```

Response:

- Async acceptance response (`202` semantics)

## 3) Processing Model

- Worker receives message from SQS.
- Worker extracts payload from message body.
- Worker uses shared core logic (`process_event` in `handler.py`).
- Worker updates DynamoDB status:
  - `PENDING`
  - `RUNNING`
  - `SUCCEEDED` or `FAILED`

## 4) Reliability Controls

- SQS visibility timeout tuned for long jobs.
- DLQ captures poison/unrecoverable retries.
- Worker deletes messages after successful processing.
- Worker deletes malformed non-retryable messages to prevent poison loops.
- Failed processing leaves message for retry/DLQ handling.

## 5) Scaling and Observability

- Worker desired count is configurable.
- ECS worker autoscaling is driven by SQS backlog alarms.
- CloudWatch alarms include:
  - queue backlog thresholds
  - oldest message age
  - DLQ message presence
- Worker logs stream to CloudWatch log group `/ecs/<name_prefix>`.

## 6) Code Entry Points

- Worker runtime: `openfaas-functions/openfaas-aws-migration/sqs_worker.py`
- Business logic: `openfaas-functions/openfaas-aws-migration/handler.py`
- Status persistence: `openfaas-functions/openfaas-aws-migration/job_status_store.py`

## 7) Summary

The deployment is now async-first and avoids long-lived HTTP request coupling:

- HTTP request submits work to queue quickly.
- ECS worker runs long tasks independently of request lifetime.
- DynamoDB tracks processing state.
- SQS + DLQ + autoscaling + alarms provide production safety for variable load.
