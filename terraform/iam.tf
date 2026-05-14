data "aws_iam_policy_document" "ecs_task_execution_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_task_execution" {
  name               = "${local.name_prefix}-ecs-task-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_execution_assume_role.json

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_managed" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "ecs_task_execution_secrets" {
  count = length(local.secrets_arns_unique) > 0 ? 1 : 0

  statement {
    sid       = "ReadConfiguredSecrets"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = local.secrets_arns_unique
  }

  statement {
    sid = "DecryptSecretsIfKmsUsed"
    actions = [
      "kms:Decrypt"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "ecs_task_execution_secrets" {
  count = length(local.secrets_arns_unique) > 0 ? 1 : 0

  name   = "${local.name_prefix}-ecs-task-execution-secrets"
  policy = data.aws_iam_policy_document.ecs_task_execution_secrets[0].json

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_secrets" {
  count = length(local.secrets_arns_unique) > 0 ? 1 : 0

  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = aws_iam_policy.ecs_task_execution_secrets[0].arn
}

resource "aws_iam_role" "ecs_task" {
  name               = "${local.name_prefix}-ecs-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_execution_assume_role.json

  tags = local.tags
}

data "aws_iam_policy_document" "ecs_task_secrets_runtime" {
  count = var.enable_task_role_secrets_access && length(local.secrets_arns_unique) > 0 ? 1 : 0

  statement {
    sid       = "ReadConfiguredSecretsAtRuntime"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = local.secrets_arns_unique
  }

  statement {
    sid = "DecryptSecretsAtRuntime"
    actions = [
      "kms:Decrypt"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "ecs_task_secrets_runtime" {
  count = var.enable_task_role_secrets_access && length(local.secrets_arns_unique) > 0 ? 1 : 0

  name   = "${local.name_prefix}-ecs-task-runtime-secrets"
  policy = data.aws_iam_policy_document.ecs_task_secrets_runtime[0].json

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "ecs_task_secrets_runtime" {
  count = var.enable_task_role_secrets_access && length(local.secrets_arns_unique) > 0 ? 1 : 0

  role       = aws_iam_role.ecs_task.name
  policy_arn = aws_iam_policy.ecs_task_secrets_runtime[0].arn
}

data "aws_iam_policy_document" "ecs_task_async_runtime" {
  statement {
    sid = "AllowSqsAsyncJobProcessing"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:ChangeMessageVisibility",
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
    ]
    resources = [aws_sqs_queue.jobs.arn]
  }

  statement {
    sid = "AllowDynamoDbJobStatusUpdates"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
    ]
    resources = [aws_dynamodb_table.job_status.arn]
  }
}

resource "aws_iam_policy" "ecs_task_async_runtime" {
  name   = "${local.name_prefix}-ecs-task-async-runtime"
  policy = data.aws_iam_policy_document.ecs_task_async_runtime.json

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "ecs_task_async_runtime" {
  role       = aws_iam_role.ecs_task.name
  policy_arn = aws_iam_policy.ecs_task_async_runtime.arn
}
