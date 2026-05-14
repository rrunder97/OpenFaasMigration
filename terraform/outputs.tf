output "api_gateway_url" {
  description = "API Gateway base invoke URL (null when disabled)."
  value       = var.enable_api_gateway ? "https://${aws_api_gateway_rest_api.jobs[0].id}.execute-api.${var.aws_region}.amazonaws.com/${aws_api_gateway_stage.jobs[0].stage_name}" : null
}

output "ecs_cluster_name" {
  description = "ECS cluster name."
  value       = aws_ecs_cluster.this.name
}

output "ecs_worker_service_name" {
  description = "ECS worker service name."
  value       = aws_ecs_service.worker.name
}

output "ecr_repository_url" {
  description = "ECR repository URL for container image push."
  value       = aws_ecr_repository.app.repository_url
}

output "jobs_queue_url" {
  description = "Primary SQS queue URL for async jobs."
  value       = aws_sqs_queue.jobs.id
}

output "jobs_queue_arn" {
  description = "Primary SQS queue ARN for async jobs."
  value       = aws_sqs_queue.jobs.arn
}

output "jobs_dlq_arn" {
  description = "DLQ ARN for async jobs."
  value       = aws_sqs_queue.jobs_dlq.arn
}

output "job_status_table_name" {
  description = "DynamoDB table name for async job state."
  value       = aws_dynamodb_table.job_status.name
}

output "api_jobs_submit_url" {
  description = "Submit jobs endpoint URL through API Gateway (null when disabled)."
  value       = var.enable_api_gateway ? "https://${aws_api_gateway_rest_api.jobs[0].id}.execute-api.${var.aws_region}.amazonaws.com/${aws_api_gateway_stage.jobs[0].stage_name}/jobs" : null
}
