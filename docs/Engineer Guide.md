# Engineer Guide: Deploy to AWS (Containerized Worker)

This guide is a practical, command-first runbook for taking this project from local IDE to a running AWS deployment.

## High-level summary

This is a deployment-only runbook for shipping the containerized worker to AWS. It focuses on image build, infrastructure apply, release rollout, and runtime verification.

## Read this guide in order (quick map)

Use this sequence to avoid deployment mistakes:

1. Complete prerequisites and AWS auth (`Section 1`).
2. Clone, containerize, and run local build checks (`Section 2`).
3. Configure Terraform backend and deployment variables (`Section 3`).
4. Apply base infrastructure (`Section 4`).
5. Build and push release image to ECR (`Section 5`).
6. Roll out image tag in ECS via Terraform (`Section 6`).
7. Smoke test API and verify runtime health (`Section 7` and `Section 8`).
8. Complete release checklist (`Section 9`).

For architecture context, payload contract, invocation flow, and day-2 operations, use `docs/EngineeringHandoff.md`.

## 1) Prerequisites

Install and verify:

- Docker
- AWS CLI v2
- Terraform `>= 1.5`
- Python 3.11+ (optional, only for non-container local tests)
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

## 2) Clone/Open and containerize locally on macOS (Docker-first)

Clone the repo and move into it:

```bash
git clone <your-github-repo-url>
cd openfaas-aws-migration
```

On macOS, make sure Docker Desktop is installed and running before continuing.

Quick verification:

```bash
docker --version
docker info
```

Build the application container first (required for deployment flow):

```bash
cd openfaas-functions/openfaas-aws-migration
docker build -t openfaas-aws-migration:local .
```

Run tests inside the built application image:

```bash
docker run --rm openfaas-aws-migration:local sh -lc \
  "python -m pip install --no-cache-dir pytest && python -m pytest -q"
```

Expected:

- Docker image builds successfully.
- Tests pass.

Optional local Python path (secondary option if you prefer non-container local tests):

```bash
cd openfaas-functions/openfaas-aws-migration
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
pip install pytest
python -m pytest -q
```

## 3) Configure Terraform

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

## 4) Deploy base infrastructure (first apply)

From `terraform/`:

```bash
terraform init -reconfigure -backend-config=backend.hcl
terraform plan -out tfplan
terraform apply tfplan
terraform output
```

Safety check: if `terraform plan` includes unexpected resource replacement/deletion, stop and review `terraform.tfvars` and backend/workspace settings before applying.

Save these outputs:

- `ecr_repository_url`
- `api_jobs_submit_url`
- `ecs_worker_service_name`
- `job_status_table_name`

## 5) Build and push release image to ECR

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

## 6) Roll out that image in ECS via Terraform

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

Tip: only apply if the plan reflects the intended rollout (primarily task definition/image tag and expected worker service changes).

## 7) Smoke test API after deployment

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

## 8) Verify runtime health in AWS

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

## 9) Release checklist (copy/paste)

- [ ] Local tests pass (Docker path or local Python path)
- [ ] Local Docker build succeeds
- [ ] Terraform plan/apply succeeds
- [ ] New image pushed to ECR with unique tag
- [ ] Terraform rollout applied with that tag
- [ ] Valid payload accepted and processed
- [ ] Invalid payload rejected by validation logic
- [ ] ECS healthy and queue drains

## 10) Most common failure points

- ECR push denied: wrong account/region/profile during `docker login`
- ECS task not starting: missing/invalid environment variables or secret ARNs
- Queue backlog increasing: worker task count too low or worker runtime errors
- No API URL output: `enable_api_gateway` disabled in `terraform.tfvars`

