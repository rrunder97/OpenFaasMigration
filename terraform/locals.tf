locals {
  name_prefix = "${var.project_name}-${var.environment}"

  default_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  tags = merge(local.default_tags, var.tags)

  selected_azs = length(var.availability_zones) > 0 ? var.availability_zones : slice(data.aws_availability_zones.available.names, 0, 2)

  vpc_id              = var.create_vpc ? aws_vpc.this[0].id : var.vpc_id
  public_subnet_ids   = var.create_vpc ? aws_subnet.public[*].id : var.public_subnet_ids
  private_subnet_ids  = var.create_vpc ? aws_subnet.private[*].id : var.private_subnet_ids
  container_name      = var.project_name
  ecr_image           = "${aws_ecr_repository.app.repository_url}:${var.image_tag}"
  secrets_arns_unique = distinct(values(var.secrets_manager_arns))
}
