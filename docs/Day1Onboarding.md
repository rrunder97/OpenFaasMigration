# Day 1 Onboarding Guide

This guide gets a new engineer from clone to first successful smoke test.

Scope:

1. Run locally with Docker (quick code-path check)
2. Build Docker image
3. Push image to ECR
4. Deploy with Terraform
5. Smoke test `POST /jobs`

## 0) Prerequisites

- AWS CLI v2 installed and authenticated
- Docker installed and running
- Terraform `>= 1.5`
- AWS permissions for ECR, ECS, IAM, API Gateway, SQS, DynamoDB, CloudWatch, and Terraform backend (S3 + lock table)

Set default environment variables for the session:

```bash
export AWS_REGION=us-east-1
export AWS_PROFILE=<your-profile>
```

## 1) Run locally with Docker (quick validation)

This repo does not currently include a full local API stack. For Day 1, validate the core handler path by building the worker image and running a one-off command in the container.

From repo root:

```bash
cd openfaas-functions/openfaas-aws-migration
docker build -t openfaas-aws-migration:local .
```

Run a direct local call inside the built container:

```bash
docker run --rm openfaas-aws-migration:local python - <<'PY'
from handler import handle
print(handle('{"customer":"acme","Org_Ids":[101,102]}'))
PY
```

Expected result: a success payload (dict) showing accepted input fields and metadata.

Why this command is needed: container default startup runs `sqs_worker.py`, which requires AWS/SQS runtime environment variables. The one-off `python` command above validates app logic without requiring local SQS infrastructure.

## 2) Configure Terraform for your environment

From repo root:

```bash
cd terraform
cp backend.hcl.example backend.hcl
cp terraform.tfvars.example terraform.tfvars
```

Update `backend.hcl` with your remote-state bucket and lock table.

Update `terraform.tfvars` at minimum:

- Networking (`create_vpc` or existing VPC/subnets)
- Capacity (`worker_desired_count`, `worker_min_capacity`, `worker_max_capacity`)
- Runtime config (`environment_variables`)
- Secrets (`secrets_manager_arns`)
- `image_tag` (set to a real release tag, not only `latest`)

## 3) Deploy infrastructure baseline (first apply)

From `terraform/`:

```bash
terraform init -reconfigure -backend-config=backend.hcl
terraform plan -out tfplan
terraform apply tfplan
```

Capture outputs:

```bash
terraform output
```

You will need at least:

- `ecr_repository_url`
- `api_jobs_submit_url`

## 4) Build Docker image

From `terraform/` (keeps relative path simple):

```bash
IMAGE_TAG=day1-$(date +%Y%m%d-%H%M%S)
REPO_URL=$(terraform output -raw ecr_repository_url)

docker build -t "${REPO_URL}:${IMAGE_TAG}" ../openfaas-functions/openfaas-aws-migration
```

Note: this is the release-tagged build for ECR. It can reuse the same source as the local image.

## 5) Push Docker image to ECR

Authenticate Docker to ECR, then push:

```bash
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws ecr get-login-password --region "${AWS_REGION}" \
  | docker login --username AWS --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

docker push "${REPO_URL}:${IMAGE_TAG}"
```

## 6) Deploy the new image with Terraform

Set the same tag in `terraform.tfvars`:

```hcl
image_tag = "day1-YYYYMMDD-HHMMSS"
```

Then apply:

```bash
terraform plan -out tfplan
terraform apply tfplan
```

## 7) Smoke test API

Get endpoint:

```bash
API_JOBS_SUBMIT_URL=$(terraform output -raw api_jobs_submit_url)
echo "${API_JOBS_SUBMIT_URL}"
```

Submit a test request:

```bash
curl -i -X POST "${API_JOBS_SUBMIT_URL}" \
  -H "Content-Type: application/json" \
  -d '{"customer":"acme","Org_Ids":[101,102]}'
```

Expected smoke-test signals:

- HTTP response is acceptance-style (async semantics)
- Response body indicates accepted submission
- CloudWatch worker logs show message processing
- Queue depth does not grow continuously

## 8) Quick troubleshooting checklist

- **`terraform output -raw api_jobs_submit_url` fails**: confirm `enable_api_gateway = true`.
- **`docker push` denied**: re-check ECR login/account/region mismatch.
- **No worker processing logs**: check ECS service desired/running count and task startup errors.
- **Messages stuck in queue**: inspect worker logs, IAM permissions, and visibility timeout settings.
- **DLQ receives messages**: inspect malformed payloads or runtime exceptions before replaying.

## 9) Day-1 done when

- You can run local Docker-based handler validation successfully.
- You can deploy Terraform without drift/errors.
- You can build/push an image and roll it out via `image_tag`.
- You can submit `POST /jobs` and verify end-to-end processing signals.
