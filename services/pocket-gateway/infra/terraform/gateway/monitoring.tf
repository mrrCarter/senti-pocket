resource "aws_cloudwatch_log_metric_filter" "gateway_events" {
  for_each = var.enabled ? local.gateway_metric_alarms : {}

  name           = "${local.resource_name}-${each.key}"
  log_group_name = aws_cloudwatch_log_group.gateway_lambda[0].name
  pattern        = "\"${each.value.metric}\""

  metric_transformation {
    name      = each.value.metric
    namespace = "SentiPocket/Gateway"
    value     = "1"
    unit      = "Count"
  }
}

resource "aws_cloudwatch_metric_alarm" "lambda" {
  for_each = var.enabled ? local.lambda_alarms : {}

  alarm_name          = "${local.resource_name}-lambda-${each.key}"
  alarm_description   = "Gateway Lambda ${each.value.metric_name} breached its safe operating bound."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = each.value.threshold
  metric_name         = each.value.metric_name
  namespace           = "AWS/Lambda"
  period              = each.value.period
  statistic           = each.value.statistic
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.gateway[0].function_name
  }

  alarm_actions             = sort(tolist(var.alarm_topic_arns))
  ok_actions                = sort(tolist(var.alarm_topic_arns))
  insufficient_data_actions = []

  tags = merge(local.common_tags, {
    Name = "${local.resource_name}-lambda-${each.key}"
  })
}

resource "aws_cloudwatch_metric_alarm" "table" {
  for_each = var.enabled ? local.table_alarms : {}

  alarm_name          = "${local.resource_name}-table-${each.key}"
  alarm_description   = "Gateway DynamoDB ${each.value.metric_name} breached its safe operating bound."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = each.value.threshold
  metric_name         = each.value.metric_name
  namespace           = "AWS/DynamoDB"
  period              = each.value.period
  statistic           = each.value.statistic
  treat_missing_data  = "notBreaching"

  dimensions = {
    TableName = aws_dynamodb_table.gateway[0].name
  }

  alarm_actions             = sort(tolist(var.alarm_topic_arns))
  ok_actions                = sort(tolist(var.alarm_topic_arns))
  insufficient_data_actions = []

  tags = merge(local.common_tags, {
    Name = "${local.resource_name}-table-${each.key}"
  })
}

resource "aws_cloudwatch_metric_alarm" "gateway_events" {
  for_each = var.enabled ? local.gateway_metric_alarms : {}

  alarm_name          = "${local.resource_name}-${each.key}"
  alarm_description   = "Gateway emitted the redacted ${each.value.metric} safety metric."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = 0
  metric_name         = each.value.metric
  namespace           = "SentiPocket/Gateway"
  period              = 60
  statistic           = "Sum"
  treat_missing_data  = "notBreaching"

  alarm_actions             = sort(tolist(var.alarm_topic_arns))
  ok_actions                = sort(tolist(var.alarm_topic_arns))
  insufficient_data_actions = []

  depends_on = [aws_cloudwatch_log_metric_filter.gateway_events]

  tags = merge(local.common_tags, {
    Name = "${local.resource_name}-${each.key}"
  })
}
