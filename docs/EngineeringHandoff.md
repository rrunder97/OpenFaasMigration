# Engineering Handoff

This document is the operational handoff for `openfaas-aws-migration`.

It is written for engineers who need to own day-2 operations and feature work on the current async AWS architecture:

- `POST /jobs` on API Gateway
- API Gateway -> SQS message enqueue
- ECS/Fargate worker (`sqs_worker.py`) processes queue messages
- DynamoDB stores job status
- CloudWatch logs/alarms + autoscaling protect operations

## 1) Prerequisites

## Access and permissions

- AWS credentials configured for the target account/region.
- IAM permissions for: VPC, ECS, ECR, IAM, SQS, DynamoDB, API Gateway, CloudWatch, and Terraform backend resources (S3 + DynamoDB lock table).
- Ability to read and update AWS Secrets Manager secrets used by the worker.

## Local tooling

- Terraform `>= 1.5`
- Docker (for building/pushing worker image)
- AWS CLI v2
- Python 3.11+ (for local lint/test scaffolding and `tox`)

## Repo-specific configuration inputs

- `terraform/backend.hcl` (copied from `terraform/backend.hcl.example`)
- `terraform/terraform.tfvars` (copied from `terraform/terraform.tfvars.example`)
- Non-secret runtime values in `environment_variables`
- Secret ARN mappings in `secrets_manager_arns`

Helpful references:

- `terraform/README.md`
- `docs/README.md`
- `docs/SecretsProcess.md`
- `docs/ECS-IAM-and-Secrets.md`

## 2) Deployment Steps

Use this sequence for new environments and regular releases.

## Step A: Configure Terraform backend and variables

From `terraform/`:

```bash
cp backend.hcl.example backend.hcl
cp terraform.tfvars.example terraform.tfvars
```

Edit `backend.hcl` for your state bucket/lock table and `terraform.tfvars` for environment-specific settings.

Critical values to verify before apply:

- Networking (`create_vpc` vs existing `vpc_id` + subnets)
- `worker_desired_count`, `worker_min_capacity`, `worker_max_capacity`
- SQS durability/retry settings (`sqs_visibility_timeout_seconds`, `sqs_max_receive_count`, etc.)
- `environment_variables`
- `secrets_manager_arns`

## Step B: Initialize and apply infrastructure

```bash
terraform init -reconfigure -backend-config=backend.hcl
terraform plan -out tfplan
terraform apply tfplan
```

Capture outputs after apply:

```bash
terraform output
```

Important outputs:

- `api_jobs_submit_url`
- `ecr_repository_url`
- `ecs_cluster_name`
- `ecs_worker_service_name`
- `jobs_queue_url`
- `job_status_table_name`

## Step C: Build and push worker image

From `terraform/` (or adjust paths if running elsewhere):

```bash
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=us-east-1
REPO_NAME=openfaas-aws-migration-dev
IMAGE_TAG=<release-tag>

aws ecr get-login-password --region "${AWS_REGION}" \
  | docker login --username AWS --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

docker build -t "${REPO_NAME}:${IMAGE_TAG}" ../openfaas-functions/openfaas-aws-migration
docker tag "${REPO_NAME}:${IMAGE_TAG}" "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${REPO_NAME}:${IMAGE_TAG}"
docker push "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${REPO_NAME}:${IMAGE_TAG}"
```

## Step D: Roll out the new image

Set `image_tag = "<release-tag>"` in `terraform.tfvars`, then:

```bash
terraform plan -out tfplan
terraform apply tfplan
```

This updates the ECS task definition image and deploys the worker service.

## 3) Testing and Validation

Current repo state: there is no full automated test suite yet. `tox.ini` is a placeholder that only validates environment setup.

## Minimal local checks

From `openfaas-functions/openfaas-aws-migration/`:

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
tox
```

Expected `tox` behavior today: prints placeholder output. Treat this as a smoke check, not a correctness test.

## Post-deploy functional verification

1. Submit a sample job:

```bash
curl -sS -X POST "$API_JOBS_SUBMIT_URL" \
  -H "Content-Type: application/json" \
  -d '{"customer":"acme","Org_Ids":[101,102]}'
```

2. Verify response indicates async acceptance.
3. Verify queue drains and worker logs show processing.
4. Verify DynamoDB status record transitions through expected states.

Example DynamoDB lookup (job id known):

```bash
aws dynamodb get-item \
  --table-name "$JOB_STATUS_TABLE_NAME" \
  --key '{"job_id":{"S":"<job-id>"}}'
```

## 4) Logs, Metrics, and Day-2 Ops

## CloudWatch logs

- Worker log group: `/ecs/<project>-<env>` (from `terraform/logs.tf`)
- Stream prefix: `ecs-worker`

Tail logs:

```bash
aws logs tail "/ecs/<project>-<env>" --follow
```

## Core health signals

- SQS queue depth (`ApproximateNumberOfMessagesVisible`)
- SQS oldest message age (`ApproximateAgeOfOldestMessage`)
- DLQ visible messages (`ApproximateNumberOfMessagesVisible` on DLQ)
- ECS task count + restarts
- Worker error/exception rate in logs

Terraform alarms already provision:

- scale-out trigger on queue depth
- scale-in trigger on queue depth
- backlog age alarm
- DLQ has-messages alarm

## Typical incident triage order

1. Check DLQ > 0 and oldest message age alarms.
2. Inspect worker logs for parse/runtime errors.
3. Confirm ECS service has healthy running tasks.
4. Validate secrets/env var wiring in task definition.
5. If queue is growing, evaluate scale-out thresholds and task CPU/memory pressure.

## 5) Rollback Playbooks

Choose the least-disruptive rollback that restores service quickly.

## A) Bad application release (most common)

1. Revert `image_tag` in `terraform.tfvars` to last known good tag.
2. `terraform plan && terraform apply`
3. Verify new tasks start and queue begins draining.

Notes:

- ECS deployment circuit breaker is enabled with rollback, which helps failed rollout recovery.
- Keep immutable, versioned tags (`vYYYYMMDD-N`) instead of relying on `latest`.

## B) Misconfiguration (env vars/secrets/thresholds)

1. Revert only bad variables in `terraform.tfvars`.
2. Re-apply Terraform.
3. Validate worker startup and log health.

## C) Emergency traffic pause

Use only during severe incidents:

1. Temporarily set `worker_desired_count = 0` and apply to stop processing.
2. Investigate/fix issue while messages remain buffered in SQS.
3. Restore desired count and monitor controlled recovery.

## D) Infrastructure regression

1. Revert the Terraform change in version control.
2. Re-run `terraform plan` and validate only expected rollback diffs.
3. Apply and confirm endpoint + queue + worker health.

## 6) Extension Guidance (How to Evolve Safely)

## Where to add business behavior

- Add core logic in `openfaas-functions/openfaas-aws-migration/handler.py` (`process_event` / `function_handler` path).
- Keep transport/runtime concerns in `sqs_worker.py`.
- Keep persistence concerns in `job_status_store.py`.

## Config and secrets rules

- Non-secret env-specific settings -> Terraform `environment_variables`.
- Sensitive values -> Secrets Manager + Terraform `secrets_manager_arns`.
- Static non-sensitive defaults -> `Config.yaml`.

Do not hardcode credentials/tokens in code or `Config.yaml`.

## Scaling and performance tuning

- Tune `sqs_visibility_timeout_seconds` based on observed runtime percentiles.
- Keep long polling enabled (`sqs_receive_wait_time_seconds = 20` is default).
- If jobs become highly variable, consider heartbeat-based `ChangeMessageVisibility` extension in worker code.
- Adjust autoscaling thresholds to match backlog SLOs.

## Idempotency and duplicate safety

SQS is at-least-once delivery. New side effects must be idempotent:

- Use stable job identifiers
- Protect external writes from duplicate execution
- Delete messages only after successful processing

## Safe feature delivery pattern

1. Add code path behind config flag.
2. Deploy dark/inactive.
3. Validate logs + status transitions.
4. Enable per environment.
5. Add automated tests as part of feature completion.

## Recommended near-term hardening

- Add real unit/integration tests (replace placeholder `tox` command).
- Add CI pipeline for lint/test + Terraform validation.
- Add runbook scripts for DLQ replay and failed-job reprocessing.
- Add explicit job status query API if consumers need first-class status polling.

## 7) Ownership and Handshake Checklist

Before handoff is considered complete:

- [ ] New owner can run Terraform plan/apply in a non-prod environment.
- [ ] New owner can build/push image and roll forward/backward by `image_tag`.
- [ ] New owner can submit a test job and verify end-to-end completion.
- [ ] New owner can find worker logs and diagnose a synthetic failure.
- [ ] New owner understands config/secrets ownership boundaries.

