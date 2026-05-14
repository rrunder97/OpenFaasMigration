data "aws_iam_policy_document" "apigw_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["apigateway.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "apigw_sqs_integration" {
  count = var.enable_api_gateway ? 1 : 0

  name               = "${local.name_prefix}-apigw-sqs-role"
  assume_role_policy = data.aws_iam_policy_document.apigw_assume_role.json

  tags = local.tags
}

data "aws_iam_policy_document" "apigw_sqs_send_message" {
  statement {
    sid       = "AllowApiGatewaySendMessage"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.jobs.arn]
  }
}

resource "aws_iam_role_policy" "apigw_sqs_send_message" {
  count = var.enable_api_gateway ? 1 : 0

  name   = "${local.name_prefix}-apigw-sqs-send-message"
  role   = aws_iam_role.apigw_sqs_integration[0].id
  policy = data.aws_iam_policy_document.apigw_sqs_send_message.json
}

resource "aws_api_gateway_rest_api" "jobs" {
  count = var.enable_api_gateway ? 1 : 0

  name = "${local.name_prefix}-jobs-api"

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  tags = local.tags
}

resource "aws_api_gateway_resource" "jobs" {
  count = var.enable_api_gateway ? 1 : 0

  rest_api_id = aws_api_gateway_rest_api.jobs[0].id
  parent_id   = aws_api_gateway_rest_api.jobs[0].root_resource_id
  path_part   = "jobs"
}

resource "aws_api_gateway_method" "jobs_post" {
  count = var.enable_api_gateway ? 1 : 0

  rest_api_id   = aws_api_gateway_rest_api.jobs[0].id
  resource_id   = aws_api_gateway_resource.jobs[0].id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "jobs_post_sqs" {
  count = var.enable_api_gateway ? 1 : 0

  rest_api_id             = aws_api_gateway_rest_api.jobs[0].id
  resource_id             = aws_api_gateway_resource.jobs[0].id
  http_method             = aws_api_gateway_method.jobs_post[0].http_method
  credentials             = aws_iam_role.apigw_sqs_integration[0].arn
  integration_http_method = "POST"
  type                    = "AWS"
  uri                     = "arn:aws:apigateway:${var.aws_region}:sqs:path/${data.aws_caller_identity.current.account_id}/${aws_sqs_queue.jobs.name}"

  request_parameters = {
    "integration.request.header.Content-Type" = "'application/x-www-form-urlencoded'"
  }

  # Push caller JSON directly to queue body.
  request_templates = {
    "application/json" = "Action=SendMessage&MessageBody=$util.urlEncode($input.body)"
  }
}

resource "aws_api_gateway_method_response" "jobs_post_202" {
  count = var.enable_api_gateway ? 1 : 0

  rest_api_id = aws_api_gateway_rest_api.jobs[0].id
  resource_id = aws_api_gateway_resource.jobs[0].id
  http_method = aws_api_gateway_method.jobs_post[0].http_method
  status_code = "202"
}

resource "aws_api_gateway_integration_response" "jobs_post_202" {
  count = var.enable_api_gateway ? 1 : 0

  rest_api_id = aws_api_gateway_rest_api.jobs[0].id
  resource_id = aws_api_gateway_resource.jobs[0].id
  http_method = aws_api_gateway_method.jobs_post[0].http_method
  status_code = aws_api_gateway_method_response.jobs_post_202[0].status_code

  # Keep response simple for async submission semantics.
  response_templates = {
    "application/json" = jsonencode({
      status = "ACCEPTED"
    })
  }
}

resource "aws_api_gateway_deployment" "jobs" {
  count = var.enable_api_gateway ? 1 : 0

  rest_api_id = aws_api_gateway_rest_api.jobs[0].id

  triggers = {
    redeploy = sha1(jsonencode({
      jobs_resource      = aws_api_gateway_resource.jobs[0].id
      jobs_method        = aws_api_gateway_method.jobs_post[0].id
      jobs_integration   = aws_api_gateway_integration.jobs_post_sqs[0].id
      integration_status = aws_api_gateway_integration_response.jobs_post_202[0].id
    }))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "jobs" {
  count = var.enable_api_gateway ? 1 : 0

  rest_api_id   = aws_api_gateway_rest_api.jobs[0].id
  deployment_id = aws_api_gateway_deployment.jobs[0].id
  stage_name    = var.api_gateway_stage_name

  tags = local.tags
}
