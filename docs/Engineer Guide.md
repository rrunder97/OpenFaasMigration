# Engineer Guide: Containerize, Deploy, and Test on AWS

This guide is a practical, command-first runbook for taking this project from local IDE to a running AWS deployment.

## High-level summary

This platform is an async job-processing pipeline. The API is intentionally lightweight and returns quickly after enqueueing work, while background workers process jobs independently. This design avoids HTTP timeout pressure for long-running tasks and gives better reliability through retries, DLQ handling, and worker autoscaling.

## Read this guide in order (quick map)

Use this sequence to avoid deployment mistakes:

1. Complete prerequisites and AWS auth (`Section 1`).
2. Validate local app/tests (`Section 2` to `Section 4`).
3. Configure Terraform backend and vars (`Section 5`).
4. Run first Terraform apply to create base infra (`Section 6`).
5. Build/push worker image to ECR (`Section 7`).
6. Roll out image tag and worker count (`Section 8`).
7. Run API smoke tests and AWS health checks (`Section 9` and `Section 10`).
8. Complete release checklist and second-Mac round-trip check (`Section 11` and `Section 11.1`).

If you are onboarding operational ownership after deployment, continue with `docs/EngineeringHandoff.md`.

At a glance, Terraform deploys:

- API entrypoint: `API Gateway` with `POST /jobs`
- Durable buffer: `SQS` jobs queue (plus DLQ)
- Compute layer: `ECS/Fargate` worker service polling SQS
- State tracking: `DynamoDB` job status table
- Observability/operations: `CloudWatch` logs, metrics, and alarms

## Architecture flow (end-to-end)

1. Client sends `POST /jobs` with JSON payload to API Gateway.
2. API Gateway maps request body directly into an SQS message and returns async acceptance (`202` semantics).
3. ECS/Fargate worker continuously long-polls SQS for messages.
4. Worker validates/parses payload and runs business logic in the handler.
5. Worker writes job status transitions to DynamoDB (`PENDING` -> `RUNNING` -> `SUCCEEDED`/`FAILED`).
6. On success, worker deletes the SQS message; on failure, message retries and can move to DLQ per queue policy.
7. CloudWatch logs and alarms provide visibility into worker health, queue backlog, and DLQ events.

## 1) Prerequisites

Install and verify:

- Docker
- AWS CLI v2
- Terraform `>= 1.5`
- Python 3.11+ (for local tests)
- Git
- (macOS) Xcode Command Line Tools: `xcode-select --install`

Verify tools:

```bash
docker --version
aws --version
terraform version
python3 --version
```

Configure AWS access for your target account:

```bash
export AWS_PROFILE=<your-profile>
export AWS_REGION=us-east-1
aws sts get-caller-identity
```

## 1.1) GitHub-safe repository setup (do this before first push)

If this project is not yet a git repository:

```bash
cd openfaas-aws-migration
git init
git branch -M main
```

Create a root `.gitignore` that excludes local caches, Terraform state, and sensitive tfvars files.

Before first push, verify no secrets are staged:

```bash
git status
git diff --staged
```

Then create/push the repo:

```bash
git remote add origin <your-github-repo-url>
git add .
git commit -m "Initial infrastructure and worker deployment guide"
git push -u origin main
```

## 2) Clone/Open and prepare local workspace (Docker-first)

Clone the repo and move into it:

```bash
git clone <your-github-repo-url>
cd openfaas-aws-migration
```

Run tests with Docker (recommended, no local virtualenv needed):

```bash
cd openfaas-functions/openfaas-aws-migration
docker run --rm -v "$PWD":/app -w /app python:3.12-slim sh -lc \
  "pip install --no-cache-dir -r requirements.txt pytest && python -m pytest -q"
```

Expected: tests pass.

Optional local Python path (only if you prefer it):

```bash
cd openfaas-functions/openfaas-aws-migration
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
pip install pytest
python -m pytest -q
```

## 3) Understand the current payload contract

Current application validation enforces a 1:1 mapping:

- `customer` is required (non-empty)
- `Org_Ids` is required
- `Org_Ids` must contain exactly one ID

Valid payload:

```json
{"customer":"acme","Org_Ids":[101]}
```

Invalid payload (multiple org IDs for one customer):

```json
{"customer":"acme","Org_Ids":[101,102]}
```

## 3.1) Function and call flow (code-level)

The code uses adapter-style entry points with shared business flow:

- HTTP/raw entrypoint: `handler.handle(req: str)`
- Queue worker entrypoint: `sqs_worker.run()`
- Shared processing path: `handler.process_event(event, request_id=None)` -> `handler.function_handler(event, context)`

### A) Manual/direct invocation path (no queue)

Use this when testing locally or when directly calling Python functions.

1. Call `handle(req)` with raw JSON string.
2. `handle` calls `parse_request_body(req)`:
   - returns parse error tuple on invalid JSON/object shape
   - returns parsed dict payload on success
3. `handle` calls `process_event(payload)`.
4. `process_event` validates app contract (`customer`, `Org_Ids` length == 1).
5. On valid payload, `process_event` builds context and calls `function_handler(...)`.
6. `function_handler` loads env/config and executes business logic.
7. Response is returned immediately to caller.

### B) Queue-driven invocation path (async worker)

Use this for production long-running processing.

1. A message is placed on SQS (either by API Gateway `POST /jobs` integration or direct SQS send).
2. `sqs_worker.run()` long-polls queue and reads message.
3. `_load_message_payload(...)` extracts payload and `job_id`.
4. Worker calls `process_event(payload, request_id=job_id)`.
5. Shared flow continues in `process_event` -> `function_handler`.
6. Worker marks job status in DynamoDB and deletes message on success.
7. On failure, message is retried/DLQ per queue policy.

### Why share functions across `handler.py` and `sqs_worker.py`?

- Keeps validation/business behavior consistent across both entry paths.
- Prevents duplicate logic drift (two files implementing same rules differently).
- Keeps transport concerns separate:
  - `handler.py`: raw request parsing adapter
  - `sqs_worker.py`: queue polling/retry/delete adapter
  - shared core: `process_event` + `function_handler`

### Can I "just ping HTTP gateway" and still use queue processing?

Yes, in this architecture `POST /jobs` is queue-backed:

- API Gateway accepts request and enqueues to SQS (async acceptance).
- Worker later processes from queue.

So hitting the gateway is still queue-based processing, not direct synchronous execution of business logic in the request thread.

## 4) Build and run with Docker locally

From repo root:

```bash
cd openfaas-functions/openfaas-aws-migration
docker build -t openfaas-aws-migration:local .
```

Run unit tests inside the built app image:

```bash
docker run --rm openfaas-aws-migration:local sh -lc \
  "python -m pip install --no-cache-dir pytest && python -m pytest -q"
```

Quick local behavior check (without AWS runtime):

```bash
docker run --rm openfaas-aws-migration:local python - <<'PY'
from handler import handle
print("VALID:", handle('{"customer":"acme","Org_Ids":[101]}'))
print("INVALID:", handle('{"customer":"acme","Org_Ids":[101,102]}'))
PY
```

Expected:

- `VALID` returns `ok: True`
- `INVALID` returns `ok: False` and `code: INVALID_PAYLOAD`

Optional debug shell inside the image:

```bash
docker run --rm -it --entrypoint sh openfaas-aws-migration:local
```

## 5) Configure Terraform

From repo root:

```bash
cd terraform
cp backend.hcl.example backend.hcl
cp terraform.tfvars.example terraform.tfvars
```

Edit `backend.hcl` with your Terraform state bucket/table.

If the S3 bucket or DynamoDB lock table do not exist yet, create them once:

```bash
aws s3api create-bucket \
  --bucket <your-terraform-state-bucket> \
  --region "${AWS_REGION}" \
  --create-bucket-configuration LocationConstraint="${AWS_REGION}"

aws dynamodb create-table \
  --table-name <your-terraform-lock-table> \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region "${AWS_REGION}"
```

Notes:
- For `us-east-1`, omit `--create-bucket-configuration`.
- Bucket names are globally unique.

Edit `terraform.tfvars` minimum values:

- network (`create_vpc` or existing VPC/subnets)
- worker scaling (`worker_desired_count`, min/max)
- `environment_variables`
- `secrets_manager_arns`
- `image_tag` (use release tags for real deployments; bootstrap can stay on `latest`)

Recommended first-run bootstrap in `terraform.tfvars` before the initial apply:

```hcl
worker_desired_count = 0
image_tag            = "latest"
```

Why: first apply needs to create the ECR repository. Setting desired count to `0` avoids ECS task churn before a real image tag exists.

## 6) Deploy base infrastructure (first apply)

From `terraform/`:

```bash
terraform init -reconfigure -backend-config=backend.hcl
terraform plan -out tfplan
terraform apply tfplan
terraform output
```

Save these outputs:

- `ecr_repository_url`
- `api_jobs_submit_url`
- `ecs_worker_service_name`
- `job_status_table_name`

## 7) Build and push release image to ECR

From `terraform/`:

```bash
REPO_URL=$(terraform output -raw ecr_repository_url)
IMAGE_TAG=release-$(date +%Y%m%d-%H%M%S)
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

aws ecr get-login-password --region "${AWS_REGION}" \
  | docker login --username AWS --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

docker build -t "${REPO_URL}:${IMAGE_TAG}" ../openfaas-functions/openfaas-aws-migration
docker push "${REPO_URL}:${IMAGE_TAG}"
```

## 8) Roll out that image in ECS via Terraform

Set the exact tag in `terraform.tfvars` and enable workers:

```hcl
image_tag = "release-YYYYMMDD-HHMMSS"
worker_desired_count = 1
```

Then deploy:

```bash
terraform plan -out tfplan
terraform apply tfplan
```

## 9) Smoke test API after deployment

From `terraform/`:

```bash
API_JOBS_SUBMIT_URL=$(terraform output -raw api_jobs_submit_url)
echo "${API_JOBS_SUBMIT_URL}"
```

Test valid payload:

```bash
curl -i -X POST "${API_JOBS_SUBMIT_URL}" \
  -H "Content-Type: application/json" \
  -d '{"customer":"acme","Org_Ids":[101]}'
```

Test invalid payload (should fail app validation in worker):

```bash
curl -i -X POST "${API_JOBS_SUBMIT_URL}" \
  -H "Content-Type: application/json" \
  -d '{"customer":"acme","Org_Ids":[101,102]}'
```

Note: API submit is async (`202` acceptance semantics). Final processing result is confirmed in logs and job status storage.

## 10) Verify runtime health in AWS

### ECS service

```bash
aws ecs describe-services \
  --cluster "$(terraform output -raw ecs_cluster_name)" \
  --services "$(terraform output -raw ecs_worker_service_name)" \
  --region "${AWS_REGION}"
```

### Worker logs

```bash
PROJECT_NAME=openfaas-aws-migration
ENVIRONMENT=dev
aws logs tail "/ecs/${PROJECT_NAME}-${ENVIRONMENT}" --follow --region "${AWS_REGION}"
```

### Queue depth

```bash
aws sqs get-queue-attributes \
  --queue-url "$(terraform output -raw jobs_queue_url)" \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
  --region "${AWS_REGION}"
```

## 11) Release checklist (copy/paste)

- [ ] Local tests pass (Docker path or local Python path)
- [ ] Local Docker build succeeds
- [ ] Terraform plan/apply succeeds
- [ ] New image pushed to ECR with unique tag
- [ ] Terraform rollout applied with that tag
- [ ] Valid payload accepted and processed
- [ ] Invalid payload rejected by validation logic
- [ ] ECS healthy and queue drains

## 11.1) GitHub round-trip checklist (new Mac recovery)

On a second Mac, confirm you can pull and deploy without local drift:

```bash
git clone <your-github-repo-url>
cd openfaas-aws-migration
```

Re-create local-only config files (never commit these):

```bash
cd terraform
cp backend.hcl.example backend.hcl
cp terraform.tfvars.example terraform.tfvars
```

Re-authenticate and verify account/region:

```bash
export AWS_PROFILE=<your-profile>
export AWS_REGION=us-east-1
aws sts get-caller-identity
```

Re-hydrate Terraform state and confirm parity with cloud:

```bash
terraform init -reconfigure -backend-config=backend.hcl
terraform plan
```

Expected: `No changes` (or only intentional pending changes such as a new `image_tag` rollout).

Smoke test from the second Mac:

```bash
API_JOBS_SUBMIT_URL=$(terraform output -raw api_jobs_submit_url)
curl -i -X POST "${API_JOBS_SUBMIT_URL}" \
  -H "Content-Type: application/json" \
  -d '{"customer":"acme","Org_Ids":[101]}'
```

## 12) Most common failure points

- ECR push denied: wrong account/region/profile during `docker login`
- ECS task not starting: missing/invalid environment variables or secret ARNs
- Queue backlog increasing: worker task count too low or worker runtime errors
- No API URL output: `enable_api_gateway` disabled in `terraform.tfvars`

