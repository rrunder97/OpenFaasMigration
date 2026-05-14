resource "aws_ecs_cluster" "this" {
  name = "${local.name_prefix}-cluster"

  tags = merge(local.tags, {
    Name = "${local.name_prefix}-cluster"
  })
}

resource "aws_ecs_task_definition" "worker" {
  family                   = "${local.name_prefix}-worker-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = tostring(var.cpu)
  memory                   = tostring(var.memory)
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    {
      name      = "${local.container_name}-worker"
      image     = local.ecr_image
      essential = true
      environment = [
        for k, v in merge(var.environment_variables, {
          SQS_QUEUE_URL           = aws_sqs_queue.jobs.id
          JOB_STATUS_TABLE        = aws_dynamodb_table.job_status.name
          SQS_VISIBILITY_TIMEOUT  = tostring(var.sqs_visibility_timeout_seconds)
        }) : {
          name  = k
          value = v
        }
      ]
      secrets = [
        for k, v in var.secrets_manager_arns : {
          name      = k
          valueFrom = v
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.ecs.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "ecs-worker"
        }
      }
    }
  ])

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  tags = merge(local.tags, {
    Name = "${local.name_prefix}-worker-task-def"
  })
}

resource "aws_ecs_service" "worker" {
  name                               = "${local.name_prefix}-worker-service"
  cluster                            = aws_ecs_cluster.this.id
  task_definition                    = aws_ecs_task_definition.worker.arn
  launch_type                        = "FARGATE"
  desired_count                      = var.worker_desired_count
  enable_execute_command             = true
  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = local.private_subnet_ids
    security_groups  = [aws_security_group.ecs_workers.id]
    assign_public_ip = false
  }

  tags = merge(local.tags, {
    Name = "${local.name_prefix}-worker-service"
  })
}
