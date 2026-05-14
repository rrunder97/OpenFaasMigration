# ECS IAM and Secrets

Quick onboarding guide for how secrets and IAM work in this ECS deployment.

## What this solves

Cloud engineers often need to answer:

- How does Python code read secrets without calling Secrets Manager directly?
- Which ECS IAM role needs which permission?
- Where do Terraform variables, plain env vars, and secrets get wired together?

This document covers the core flow and role boundaries.

## TL;DR

- Store secret values in AWS Secrets Manager.
- Map secret ARNs in Terraform variable `secrets_manager_arns`.
- ECS task definition injects those into container env vars using `secrets`.
- Python reads env vars (`os.environ` / `os.getenv`) like normal.
- ECS **execution role** needs permission to read secrets.
- ECS **task role** is only for runtime AWS API calls from app code.

## End-to-end flow

1. Secret is created in AWS Secrets Manager.
2. Terraform sets `secrets_manager_arns = { ENV_VAR_NAME = SECRET_ARN }`.
3. ECS task definition renders each entry into container `secrets`:
   - `name` = env var name visible inside container.
   - `valueFrom` = Secrets Manager ARN.
4. At task startup, ECS agent uses the **execution role** to call Secrets Manager.
5. Secret value is injected into container environment.
6. Python reads env var (no direct Secrets Manager code required).

## IAM roles in ECS: who does what

### 1) Execution role (`execution_role_arn`)

Used by ECS/Fargate platform during startup and platform operations.

Typical permissions:

- Pull container image from ECR.
- Write logs to CloudWatch Logs.
- Read secrets for task-definition `secrets` injection:
  - `secretsmanager:GetSecretValue`
  - `kms:Decrypt` (if customer-managed KMS key is used)

In this repo:

- Role resource: `aws_iam_role.ecs_task_execution`
- Attached managed policy: `AmazonECSTaskExecutionRolePolicy`
- Extra secret-read policy: `aws_iam_policy.ecs_task_execution_secrets`

### 2) Task role (`task_role_arn`)

Used by the application process running inside the container.

Typical permissions:

- Any AWS SDK calls your code makes at runtime (SQS, DynamoDB, etc.).
- Secrets Manager read only if your app code directly calls Secrets Manager.

In this repo:

- Role resource: `aws_iam_role.ecs_task`
- Runtime app permissions include SQS and DynamoDB (`ecs_task_async_runtime`)
- Optional runtime secret-read policy is controlled by:
  - `enable_task_role_secrets_access` (default `false`)

## Terraform wiring map (project-specific)

- `terraform/ecs.tf`
  - `execution_role_arn = aws_iam_role.ecs_task_execution.arn`
  - `task_role_arn      = aws_iam_role.ecs_task.arn`
  - Container `environment` = plain config values
  - Container `secrets`     = Secrets Manager-backed env vars

- `terraform/iam.tf`
  - Defines both roles and their policies.
  - Adds secret-read permissions to execution role based on configured secret ARNs.
  - Optionally adds secret-read permissions to task role for direct runtime reads.

- `terraform/variables.tf`
  - `environment_variables` (plain env vars)
  - `secrets_manager_arns` (env var name -> secret ARN)
  - `enable_task_role_secrets_access` (runtime direct secret reads toggle)

## Referencing secrets in Python

Use environment variables only:

```python
import os

api_key = os.environ["SECOPS_API_TOKEN"]  # fail fast if missing
# or:
api_key = os.getenv("SECOPS_API_TOKEN")   # returns None if missing
```

Do not use `os.env()` (invalid).

## When to enable task-role Secrets Manager access

Keep `enable_task_role_secrets_access = false` when:

- Secrets are injected by ECS via task definition `secrets`.
- App code only needs env vars.

Set `enable_task_role_secrets_access = true` only when:

- App code must call Secrets Manager dynamically at runtime (for example, frequent re-fetch or version-aware logic).

## Operational notes

- Secret rotation does not automatically update running containers.
- Restart/redeploy ECS tasks to pick up new secret values.
- Use least privilege: scope secret permissions to only required ARNs.

## Quick onboarding checklist

- [ ] Secret exists in Secrets Manager.
- [ ] `secrets_manager_arns` maps correct env var names to correct ARNs.
- [ ] Task definition contains container `secrets` entries.
- [ ] Execution role has `GetSecretValue` (+ `kms:Decrypt` if needed).
- [ ] App code reads env vars via `os.environ` / `os.getenv`.
- [ ] Task role includes only runtime AWS permissions app actually needs.
