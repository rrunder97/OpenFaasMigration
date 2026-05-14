# ECS Config and Secrets Guide (Developer Friendly)

Use this guide to decide where each value should live when deploying a function on ECS/Fargate.

- Flow: caller -> API Gateway -> SQS -> ECS worker task -> `process_event(...)`
- Goal: keep code simple, keep secrets secure, keep environment changes out of code

## Quick Rule

- If it is a **secret**: store in **AWS Secrets Manager** (not in code or `Config.yaml`).
- If it is **environment-specific but not secret**: store in **ECS env vars** (Terraform).
- If it is **static app behavior** and non-sensitive: keep in **`Config.yaml`** (containerized with code).

## Ownership by Team

- **Software Engineering owns**
  - Worker code (`sqs_worker.py`, `handler.py`)
  - `Config.yaml` non-secret defaults
  - Config key names used by code (`ENV`, `LOG_LEVEL`, etc.)
  - Required config contract for each service (what keys are needed)

- **Cloud Engineering owns**
  - Terraform and ECS task definition wiring
  - Env var and Secrets Manager mapping in deployment config
  - IAM roles/policies for ECS secret access
  - Networking and security guardrails

## Where Values Should Go

### Put in code package (`Config.yaml`) when ALL are true:

- Non-secret
- Mostly static across environments
- Part of app behavior defaults

Examples:
- `features.enable_debug_mode = false`
- non-sensitive static lists
- app metadata

### Put in ECS env vars (Terraform `environment_variables`) when:

- Non-secret
- Different per environment (dev/stage/prod)
- Should be changed without rebuilding container

Examples:
- `ENV=dev`
- `LOG_LEVEL=INFO`
- `REQUEST_TIMEOUT=60`
- Internal service base URLs

### Put in Secrets Manager (Terraform `secrets_manager_arns`) when:

- Sensitive (token, password, key, credential)
- Must not appear in source control or image

Examples:
- `SECOPS_API_TOKEN`
- `SOAR_API_TOKEN`
- API passwords/keys

## Decision Checklist (for developers)

Ask these in order:

1. Is the value sensitive?
   - Yes -> Secrets Manager
   - No -> continue
2. Does it change by environment?
   - Yes -> ECS env var
   - No -> continue
3. Is it static app behavior/config default?
   - Yes -> `Config.yaml`
   - No -> ECS env var

## How This Maps to Current Repo

- Code reads static config from `Config.yaml` using `load_app_config()`
- Code reads runtime values from environment using `get_env()`
- ECS injects:
  - non-secret env vars from Terraform `environment_variables`
  - secrets from Terraform `secrets_manager_arns`

## Standard Secret Pattern

Default pattern (recommended):

1. Cloud team stores secret in AWS Secrets Manager
2. Cloud team maps env var name -> secret ARN in Terraform
3. ECS injects secret as env var at task startup
4. App reads value with `get_env("SECRET_NAME")`

Use direct SDK secret fetch in app only if you need dynamic runtime retrieval.

## Example Mapping

- `ENV`, `LOG_LEVEL`, `SECOPS_URL`, `SOAR_URL`, `REQUEST_TIMEOUT` -> ECS env vars
- `SECOPS_API_TOKEN`, `SOAR_API_TOKEN` -> Secrets Manager
- Static feature flags and app defaults -> `Config.yaml`

## Delivery Process (Simple)

1. Software team updates code and documents required config keys.
2. Cloud team updates Terraform values for env vars and secrets.
3. Build and push image to ECR.
4. Deploy ECS worker service update.
5. Submit sample payload through `POST /jobs` and verify worker logs/DynamoDB status.

## Non-Negotiables

- No secrets in `Config.yaml`
- No secrets in git
- No secrets baked into container image
- All secret access through IAM-controlled AWS mechanisms
