resource "aws_cloudwatch_log_group" "admission_lambda" {
  count = var.enabled ? 1 : 0

  name              = local.lambda_log_group_name
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.operation_admission[0].arn
  skip_destroy      = true

  tags = merge(local.common_tags, {
    Name    = local.lambda_log_group_name
    LogType = "application"
  })

  lifecycle {
    prevent_destroy = true
  }

}

resource "aws_cloudwatch_log_group" "api_access" {
  count = var.enabled ? 1 : 0

  name              = local.api_access_log_group_name
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.operation_admission[0].arn
  skip_destroy      = true

  tags = merge(local.common_tags, {
    Name    = local.api_access_log_group_name
    LogType = "access"
  })

  lifecycle {
    prevent_destroy = true
  }

}
