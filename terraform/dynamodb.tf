resource "aws_dynamodb_table" "job_status" {
  name         = "${local.name_prefix}-job-status"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "job_id"

  attribute {
    name = "job_id"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  tags = merge(local.tags, {
    Name = "${local.name_prefix}-job-status"
  })
}
