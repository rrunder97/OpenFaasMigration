## Global identification and region
variable "aws_region" {
  description = "AWS region to deploy resources into."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name used for resource naming."
  type        = string
  default     = "openfaas-aws-migration"
}

variable "environment" {
  description = "Environment name (for example: dev, staging, prod)."
  type        = string
  default     = "dev"
}

## Networking and VPC configuration
variable "create_vpc" {
  description = "If true, create a simple VPC with 2 public and 2 private subnets."
  type        = bool
  default     = false
}

variable "vpc_id" {
  description = "Existing VPC ID to use when create_vpc is false."
  type        = string
  default     = null

  validation {
    condition     = var.create_vpc || (var.vpc_id != null && trim(var.vpc_id) != "")
    error_message = "Set vpc_id when create_vpc is false."
  }
}

variable "public_subnet_ids" {
  description = "Existing public subnet IDs to use when create_vpc is false."
  type        = list(string)
  default     = []

  validation {
    condition     = var.create_vpc || length(var.public_subnet_ids) >= 2
    error_message = "Set at least two public_subnet_ids when create_vpc is false."
  }
}

variable "private_subnet_ids" {
  description = "Existing private subnet IDs to use when create_vpc is false."
  type        = list(string)
  default     = []

  validation {
    condition     = var.create_vpc || length(var.private_subnet_ids) >= 2
    error_message = "Set at least two private_subnet_ids when create_vpc is false."
  }
}

variable "vpc_cidr" {
  description = "CIDR block for VPC when create_vpc is true."
  type        = string
  default     = "10.42.0.0/16"
}

variable "availability_zones" {
  description = "Optional AZ list for subnet placement when create_vpc is true. Defaults to first two AZs."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.availability_zones) == 0 || length(var.availability_zones) == 2
    error_message = "availability_zones must be empty or contain exactly two AZ names."
  }
}

variable "public_subnet_cidrs" {
  description = "Two public subnet CIDRs when create_vpc is true."
  type        = list(string)
  default     = ["10.42.0.0/24", "10.42.1.0/24"]

  validation {
    condition     = length(var.public_subnet_cidrs) == 2
    error_message = "public_subnet_cidrs must contain exactly two CIDRs."
  }
}

variable "private_subnet_cidrs" {
  description = "Two private subnet CIDRs when create_vpc is true."
  type        = list(string)
  default     = ["10.42.10.0/24", "10.42.11.0/24"]

  validation {
    condition     = length(var.private_subnet_cidrs) == 2
    error_message = "private_subnet_cidrs must contain exactly two CIDRs."
  }
}

## ECS worker service capacity and task sizing
variable "worker_desired_count" {
  description = "Desired ECS task count for the async worker service."
  type        = number
  default     = 1
}

variable "worker_min_capacity" {
  description = "Minimum worker task count for autoscaling."
  type        = number
  default     = 1
}

variable "worker_max_capacity" {
  description = "Maximum worker task count for autoscaling."
  type        = number
  default     = 10
}

variable "cpu" {
  description = "Task CPU units."
  type        = number
  default     = 512
}

variable "memory" {
  description = "Task memory in MiB."
  type        = number
  default     = 1024
}

variable "image_tag" {
  description = "ECR image tag to deploy."
  type        = string
  default     = "latest"
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days."
  type        = number
  default     = 14
}

## Application runtime configuration
variable "environment_variables" {
  description = "Plain environment variables injected into the ECS container."
  type        = map(string)
  default     = {}
}

variable "secrets_manager_arns" {
  description = "Map of container env var name to Secrets Manager ARN (or ARN with json key suffix)."
  type        = map(string)
  default     = {}
}

variable "enable_task_role_secrets_access" {
  description = "Attach Secrets Manager read policy to task role (for runtime AWS SDK reads)."
  type        = bool
  default     = false
}

## SQS queue behavior and retry handling
variable "sqs_visibility_timeout_seconds" {
  description = "SQS visibility timeout. Set above max job runtime (for example, 3600 for 30-minute jobs)."
  type        = number
  default     = 3600
}

variable "sqs_message_retention_seconds" {
  description = "How long unprocessed messages remain in the queue."
  type        = number
  default     = 345600 # 4 days
}

variable "sqs_receive_wait_time_seconds" {
  description = "SQS long-poll duration."
  type        = number
  default     = 20
}

variable "sqs_max_receive_count" {
  description = "Number of receives before SQS moves message to DLQ."
  type        = number
  default     = 5
}

## Queue-based autoscaling and alert thresholds
variable "queue_scale_out_messages_threshold" {
  description = "Scale out worker tasks when visible messages are above this threshold."
  type        = number
  default     = 10
}

variable "queue_scale_in_messages_threshold" {
  description = "Scale in worker tasks when visible messages are at or below this threshold."
  type        = number
  default     = 0
}

variable "queue_alarm_oldest_message_age_seconds" {
  description = "Alarm threshold for oldest message age in queue."
  type        = number
  default     = 300
}

## API ingress
variable "enable_api_gateway" {
  description = "If true, create API Gateway HTTP API in front of the API ECS service."
  type        = bool
  default     = true
}

variable "api_gateway_stage_name" {
  description = "API Gateway stage name."
  type        = string
  default     = "prod"
}

## Common resource tags
variable "tags" {
  description = "Additional tags applied to all resources."
  type        = map(string)
  default     = {}
}

