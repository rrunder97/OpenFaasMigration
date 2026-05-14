resource "aws_cloudwatch_metric_alarm" "jobs_queue_oldest_message_age" {
  alarm_name          = "${local.name_prefix}-jobs-oldest-message-age"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "ApproximateAgeOfOldestMessage"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Maximum"
  threshold           = var.queue_alarm_oldest_message_age_seconds
  alarm_description   = "Oldest job message age is too high."

  dimensions = {
    QueueName = aws_sqs_queue.jobs.name
  }
}

resource "aws_cloudwatch_metric_alarm" "jobs_dlq_has_messages" {
  alarm_name          = "${local.name_prefix}-jobs-dlq-has-messages"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  alarm_description   = "DLQ has failed messages requiring investigation."

  dimensions = {
    QueueName = aws_sqs_queue.jobs_dlq.name
  }
}
