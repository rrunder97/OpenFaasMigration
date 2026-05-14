# SQS Configuration Guide (Async ECS Worker)

This document summarizes the important SQS settings and operational metrics for this project.

## Current baseline in this repo

- `sqs_visibility_timeout_seconds = 3600`
- `sqs_message_retention_seconds = 345600` (4 days)
- `sqs_receive_wait_time_seconds = 20`
- `sqs_max_receive_count = 5`
- Worker task sizing defaults: `cpu = 512`, `memory = 1024`
- Worker polling defaults:
  - `SQS_WAIT_TIME_SECONDS = 20`
  - `SQS_MAX_MESSAGES = 1`

These are solid defaults for reliable at-least-once async processing.

## What each SQS setting controls

- `visibility_timeout_seconds`
  - Time a received message is hidden from other consumers.
  - Too low -> duplicate processing risk on long jobs.
  - Too high -> slower retries after failures.

- `message_retention_seconds`
  - How long unprocessed messages stay in queue before expiration.
  - Too low -> data loss risk during outages.
  - Higher values provide operational recovery buffer.

- `receive_wait_time_seconds`
  - Long polling duration.
  - `20` is recommended to reduce empty poll calls and cost.

- `maxReceiveCount` (DLQ redrive)
  - Number of failed receives before moving a message to DLQ.
  - Protects main queue from poison messages.

## Recommended settings by environment

- Production baseline:
  - `sqs_visibility_timeout_seconds = 1800` to `3600` (depends on runtime distribution)
  - `sqs_message_retention_seconds = 345600` (4 days) or `604800` (7 days)
  - `sqs_receive_wait_time_seconds = 20`
  - `sqs_max_receive_count = 5`

- Dev/test baseline:
  - `sqs_visibility_timeout_seconds = 600` to `1200`
  - `sqs_message_retention_seconds = 86400` to `172800`
  - `sqs_receive_wait_time_seconds = 20`
  - `sqs_max_receive_count = 3` to `5`

## How to set visibility timeout correctly

Use measured runtime data, not guesses.

1. Instrument job runtime from message receive to delete (or failure).
2. Track percentile runtime by job type (`p50`, `p90`, `p95`, `p99`).
3. Set initial timeout:
   - `visibility_timeout = 2 x p95` (default guidance), or
   - `visibility_timeout = 3 x p90` when runtime is noisy.
4. Revisit monthly or after workload changes.

Example:
- If `p95 = 8 minutes`, set visibility to about `16 to 24 minutes`.
- If `p95 = 20 minutes`, set visibility to about `40 to 60 minutes`.

## Metrics to monitor (CloudWatch + app)

Track these continuously:

- Queue health:
  - `ApproximateAgeOfOldestMessage`
  - `ApproximateNumberOfMessagesVisible`
  - `ApproximateNumberOfMessagesNotVisible`

- Processing quality:
  - `NumberOfMessagesReceived`
  - `NumberOfMessagesDeleted`
  - DLQ message count (visible messages on DLQ)

- Worker capacity:
  - ECS task CPU utilization
  - ECS task memory utilization
  - Task restarts/crash loops

- App-level metrics:
  - Job processing duration histogram (`p50/p90/p95/p99`)
  - Success/failure counts by job type
  - Duplicate detection count (same job ID observed multiple times)

## Alarm suggestions

- Queue backlog risk:
  - Alarm when `ApproximateAgeOfOldestMessage > 300s` for 5+ minutes.
  - Alarm when visible queue depth is above scale-out threshold for sustained periods.

- Retry/duplicate risk:
  - Alarm when `NumberOfMessagesReceived` grows much faster than `NumberOfMessagesDeleted`.
  - Alarm when DLQ has any visible messages (`> 0`) for critical workloads.

- Capacity pressure:
  - Alarm when worker CPU or memory stays above 80 to 85 percent.

## Exactly-once vs at-least-once reality

SQS standard queues provide at-least-once delivery. To avoid duplicate side effects:

- Make processing idempotent with a durable job ID check.
- Only delete message after successful processing.
- Keep DLQ enabled and triage quickly.

If strict ordering and broker-level dedup are needed, evaluate FIFO queue plus idempotency.

## Optional improvement for this worker

Current worker sets static visibility timeout per receive. To improve both safety and retry speed:

- Start with moderate visibility timeout.
- Add periodic `ChangeMessageVisibility` heartbeat while long jobs are still running.

This avoids premature re-delivery without forcing a very large static timeout.
