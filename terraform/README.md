# OpenFaaS to ECS/Fargate Terraform (Direct API Gateway -> SQS)

This Terraform project deploys an async, long-running processing architecture:

- `API Gateway (POST /jobs) -> SQS queue`
- `ECS/Fargate worker service -> poll SQS -> process`
- `DynamoDB job status table`
- `SQS DLQ + queue alarms + worker autoscaling`
- `ECR image + CloudWatch logs + IAM roles`

## Request Flow

1. Caller sends JSON to `POST /jobs` on API Gateway.
2. API Gateway sends message directly to SQS.
3. ECS/Fargate worker polls queue and executes `sqs_worker.py`.
4. Worker updates DynamoDB job status (`PENDING` -> `RUNNING` -> `SUCCEEDED`/`FAILED`).
5. CloudWatch captures worker logs and queue alarms track backlog/DLQ.

## Infrastructure Created

- Optional VPC stack (when `create_vpc = true`)
- ECR repository
- CloudWatch log group for ECS
- ECS cluster + worker task definition + worker service
- SQS queue + DLQ
- DynamoDB status table
- API Gateway REST API (`POST /jobs`)
- Worker autoscaling policies and SQS-backed alarms
- IAM roles:
  - ECS execution role
  - ECS task role (SQS + DynamoDB runtime)
  - API Gateway integration role (SQS send)

## Prerequisites

- Terraform `>= 1.5`
- AWS credentials configured
- Permissions for VPC, ECS, IAM, ECR, SQS, DynamoDB, API Gateway, CloudWatch
- Existing VPC/subnet IDs when `create_vpc = false`

## Configure Remote State (S3)

```bash
cp backend.hcl.example backend.hcl
```

Fill real backend values, then:

```bash
terraform init -reconfigure -backend-config=backend.hcl
```

## Configure Variables

```bash
cp terraform.tfvars.example terraform.tfvars
```

Set at minimum:
- VPC/subnet values (if not creating VPC)
- `worker_desired_count`, `worker_min_capacity`, `worker_max_capacity`
- queue/alarm thresholds as needed
- `environment_variables` and `secrets_manager_arns`

## Deploy

```bash
terraform plan -out tfplan
terraform apply tfplan
```

## Build and Push Worker Image

Use output `ecr_repository_url` after first apply.

```bash
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=us-east-1
REPO_NAME=openfaas-aws-migration-dev
IMAGE_TAG=latest

aws ecr get-login-password --region "${AWS_REGION}" \
  | docker login --username AWS --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

docker build -t "${REPO_NAME}:${IMAGE_TAG}" ../openfaas-functions/openfaas-aws-migration
docker tag "${REPO_NAME}:${IMAGE_TAG}" "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${REPO_NAME}:${IMAGE_TAG}"
docker push "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${REPO_NAME}:${IMAGE_TAG}"
```

Then update `image_tag` and apply again.

## Outputs

- `api_gateway_url`
- `api_jobs_submit_url`
- `jobs_queue_url`
- `jobs_dlq_arn`
- `job_status_table_name`
- `ecs_worker_service_name`

## Notes

- This stack intentionally removes ALB, VPC Link, and API ECS service.
- Submission is async-only (`202` acceptance semantics at API edge).
