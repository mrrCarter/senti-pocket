locals {
  lambda_alarm_definitions = {
    errors = {
      metric_name         = "Errors"
      statistic           = "Sum"
      extended_statistic  = null
      period              = 60
      evaluation_periods  = 1
      datapoints_to_alarm = 1
      threshold           = 0
      unit                = "Count"
    }
    throttles = {
      metric_name         = "Throttles"
      statistic           = "Sum"
      extended_statistic  = null
      period              = 60
      evaluation_periods  = 1
      datapoints_to_alarm = 1
      threshold           = 0
      unit                = "Count"
    }
    duration-p95 = {
      metric_name         = "Duration"
      statistic           = null
      extended_statistic  = "p95"
      period              = 60
      evaluation_periods  = 3
      datapoints_to_alarm = 2
      threshold           = var.admission_timeout_seconds * 800
      unit                = "Milliseconds"
    }
    concurrency = {
      metric_name         = "ConcurrentExecutions"
      statistic           = "Maximum"
      extended_statistic  = null
      period              = 60
      evaluation_periods  = 3
      datapoints_to_alarm = 2
      threshold           = max(1, floor(var.admission_reserved_concurrency * 0.8))
      unit                = "Count"
    }
  }

  api_alarm_definitions = {
    "5xx" = {
      metric_name         = "5xx"
      statistic           = "Sum"
      extended_statistic  = null
      period              = 60
      evaluation_periods  = 1
      datapoints_to_alarm = 1
      threshold           = 0
      unit                = "Count"
    }
    integration-latency-p95 = {
      metric_name         = "IntegrationLatency"
      statistic           = null
      extended_statistic  = "p95"
      period              = 60
      evaluation_periods  = 3
      datapoints_to_alarm = 2
      threshold           = var.admission_timeout_seconds * 800
      unit                = "Milliseconds"
    }
  }

  dynamodb_alarm_definitions = {
    system-errors = {
      metric_name         = "SystemErrors"
      statistic           = "Sum"
      extended_statistic  = null
      period              = 60
      evaluation_periods  = 1
      datapoints_to_alarm = 1
      threshold           = 0
      unit                = "Count"
    }
    throttled-requests = {
      metric_name         = "ThrottledRequests"
      statistic           = "Sum"
      extended_statistic  = null
      period              = 60
      evaluation_periods  = 1
      datapoints_to_alarm = 1
      threshold           = 0
      unit                = "Count"
    }
  }

  enabled_lambda_alarms = var.enabled ? local.lambda_alarm_definitions : {}
  enabled_api_alarms    = var.enabled ? local.api_alarm_definitions : {}
  enabled_table_alarms  = var.enabled ? local.dynamodb_alarm_definitions : {}
}

resource "aws_cloudwatch_log_metric_filter" "protected_rate_limited" {
  count = var.enabled ? 1 : 0

  name           = "${local.resource_name}-protected-rate-limited"
  log_group_name = aws_cloudwatch_log_group.api_access[0].name
  pattern        = "{ ($.status = \"429\") && (($.routeKey = \"POST /dial/register\") || ($.routeKey = \"POST /dial/register/reconcile\")) }"

  metric_transformation {
    name          = "ProtectedRateLimitedResponses"
    namespace     = "SentiPocket/OperationAdmission"
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

resource "aws_cloudwatch_log_metric_filter" "protected_unavailable" {
  count = var.enabled ? 1 : 0

  name           = "${local.resource_name}-protected-unavailable"
  log_group_name = aws_cloudwatch_log_group.api_access[0].name
  pattern        = "{ ($.status = \"503\") && (($.routeKey = \"POST /dial/register\") || ($.routeKey = \"POST /dial/register/reconcile\")) }"

  metric_transformation {
    name          = "ProtectedUnavailableResponses"
    namespace     = "SentiPocket/OperationAdmission"
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

resource "aws_cloudwatch_metric_alarm" "lambda" {
  for_each = local.enabled_lambda_alarms

  alarm_name          = "${local.resource_name}-lambda-${each.key}"
  alarm_description   = "Operation-admission Lambda ${each.value.metric_name} breached its safe operating bound."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = each.value.evaluation_periods
  datapoints_to_alarm = each.value.datapoints_to_alarm
  threshold           = each.value.threshold
  metric_name         = each.value.metric_name
  namespace           = "AWS/Lambda"
  period              = each.value.period
  statistic           = each.value.statistic
  extended_statistic  = each.value.extended_statistic
  unit                = each.value.unit
  treat_missing_data  = "notBreaching"
  actions_enabled     = length(var.alarm_topic_arns) > 0

  dimensions = {
    FunctionName = aws_lambda_function.admission[0].function_name
    Resource     = "${aws_lambda_function.admission[0].function_name}:${aws_lambda_function.admission[0].version}"
  }

  alarm_actions             = var.alarm_topic_arns
  ok_actions                = var.alarm_topic_arns
  insufficient_data_actions = []

  tags = merge(local.common_tags, {
    Name = "${local.resource_name}-lambda-${each.key}"
  })
}

resource "aws_cloudwatch_metric_alarm" "api" {
  for_each = local.enabled_api_alarms

  alarm_name          = "${local.resource_name}-api-${each.key}"
  alarm_description   = "Operation-admission HTTP API ${each.value.metric_name} breached its safe operating bound."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = each.value.evaluation_periods
  datapoints_to_alarm = each.value.datapoints_to_alarm
  threshold           = each.value.threshold
  metric_name         = each.value.metric_name
  namespace           = "AWS/ApiGateway"
  period              = each.value.period
  statistic           = each.value.statistic
  extended_statistic  = each.value.extended_statistic
  unit                = each.value.unit
  treat_missing_data  = "notBreaching"
  actions_enabled     = length(var.alarm_topic_arns) > 0

  dimensions = {
    ApiId = aws_apigatewayv2_api.operation_admission[0].id
    Stage = aws_apigatewayv2_stage.live[0].name
  }

  alarm_actions             = var.alarm_topic_arns
  ok_actions                = var.alarm_topic_arns
  insufficient_data_actions = []

  tags = merge(local.common_tags, {
    Name = "${local.resource_name}-api-${each.key}"
  })
}

resource "aws_cloudwatch_metric_alarm" "table" {
  for_each = local.enabled_table_alarms

  alarm_name          = "${local.resource_name}-table-${each.key}"
  alarm_description   = "Operation-admission DynamoDB ${each.value.metric_name} breached its safe operating bound."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = each.value.evaluation_periods
  datapoints_to_alarm = each.value.datapoints_to_alarm
  threshold           = each.value.threshold
  metric_name         = each.value.metric_name
  namespace           = "AWS/DynamoDB"
  period              = each.value.period
  statistic           = each.value.statistic
  extended_statistic  = each.value.extended_statistic
  unit                = each.value.unit
  treat_missing_data  = "notBreaching"
  actions_enabled     = length(var.alarm_topic_arns) > 0

  dimensions = {
    TableName = aws_dynamodb_table.operation_admission[0].name
  }

  alarm_actions             = var.alarm_topic_arns
  ok_actions                = var.alarm_topic_arns
  insufficient_data_actions = []

  tags = merge(local.common_tags, {
    Name = "${local.resource_name}-table-${each.key}"
  })
}

resource "aws_cloudwatch_metric_alarm" "protected_rate_limited" {
  count = var.enabled ? 1 : 0

  alarm_name          = "${local.resource_name}-protected-rate-limited"
  alarm_description   = "Protected Registry V2 routes returned at least ten rate-limit responses in five minutes."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = 9
  metric_name         = "ProtectedRateLimitedResponses"
  namespace           = "SentiPocket/OperationAdmission"
  period              = 300
  statistic           = "Sum"
  unit                = "Count"
  treat_missing_data  = "notBreaching"
  actions_enabled     = length(var.alarm_topic_arns) > 0

  alarm_actions             = var.alarm_topic_arns
  ok_actions                = var.alarm_topic_arns
  insufficient_data_actions = []

  tags = merge(local.common_tags, {
    Name = "${local.resource_name}-protected-rate-limited"
  })
}

resource "aws_cloudwatch_metric_alarm" "protected_unavailable" {
  count = var.enabled ? 1 : 0

  alarm_name          = "${local.resource_name}-protected-unavailable"
  alarm_description   = "A protected Registry V2 route returned a fail-closed operation-admission 503."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = 0
  metric_name         = "ProtectedUnavailableResponses"
  namespace           = "SentiPocket/OperationAdmission"
  period              = 60
  statistic           = "Sum"
  unit                = "Count"
  treat_missing_data  = "notBreaching"
  actions_enabled     = length(var.alarm_topic_arns) > 0

  alarm_actions             = var.alarm_topic_arns
  ok_actions                = var.alarm_topic_arns
  insufficient_data_actions = []

  tags = merge(local.common_tags, {
    Name = "${local.resource_name}-protected-unavailable"
  })
}
