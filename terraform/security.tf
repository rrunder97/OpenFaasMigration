resource "aws_security_group" "ecs_workers" {
  name        = "${local.name_prefix}-ecs-workers-sg"
  description = "Worker tasks do not accept inbound traffic"
  vpc_id      = local.vpc_id

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, {
    Name = "${local.name_prefix}-ecs-workers-sg"
  })
}
