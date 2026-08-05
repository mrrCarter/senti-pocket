resource "aws_lambda_function" "admission" {
  count = var.enabled ? 1 : 0

  function_name = local.resource_name
  description   = "Body-aware, replay-aware Registry V2 operation admission"
  role          = aws_iam_role.admission[0].arn
  handler       = var.admission_handler
  runtime       = "nodejs22.x"
  architectures = [var.admission_architecture]

  s3_bucket         = var.admission_package_s3_bucket
  s3_key            = var.admission_package_s3_key
  s3_object_version = var.admission_package_s3_object_version
  source_code_hash  = var.admission_package_sha256

  publish                        = true
  memory_size                    = var.admission_memory_mb
  timeout                        = var.admission_timeout_seconds
  reserved_concurrent_executions = var.admission_reserved_concurrency
  kms_key_arn                    = aws_kms_key.operation_admission[0].arn
  code_signing_config_arn        = local.production_admission_enabled ? aws_lambda_code_signing_config.admission[0].arn : null
  layers                         = var.admission_layers

  ephemeral_storage {
    size = 512
  }

  environment {
    variables = {
      DEVICE_REGISTRY_HMAC_SECRET_ARN        = var.registry_hmac_secret_arn
      DEVICE_REGISTRY_HMAC_SECRET_VERSION_ID = var.registry_hmac_secret_version_id
      GATEWAY_LAMBDA_VERSION_ARN             = local.gateway_version_attestation.invoked_function_arn
      GATEWAY_LAMBDA_VERSION                 = local.gateway_version_attestation.function_version
      OPERATION_ADMISSION_DDB_TABLE          = aws_dynamodb_table.operation_admission[0].name
      REGISTRY_OPERATION_ADMISSION_AUTH_MODE = "senti_session_reusable_v1"
      SENTI_API_BASE_URL                     = trimsuffix(var.senti_api_base_url, "/")
    }
  }

  logging_config {
    application_log_level = "INFO"
    log_format            = "JSON"
    system_log_level      = "WARN"
  }

  tracing_config {
    mode = "Active"
  }

  depends_on = [
    aws_cloudwatch_log_group.admission_lambda,
    aws_iam_role_policy.admission,
  ]

  lifecycle {
    precondition {
      condition     = var.registry_hmac_secret_version_id == var.gateway_registry_hmac_secret_version_id
      error_message = "Admission and the attested gateway version must pin the identical Registry HMAC secret version before cutover."
    }

    precondition {
      condition     = var.registry_hmac_secret_arn == var.gateway_registry_hmac_secret_arn
      error_message = "Admission and the attested gateway version must pin the identical Registry HMAC secret ARN before cutover."
    }

    precondition {
      condition = startswith(
        var.registry_hmac_secret_arn,
        "arn:${var.aws_partition}:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:",
      )
      error_message = "registry_hmac_secret_arn must be in the configured partition, region, and account."
    }

    precondition {
      condition = startswith(
        var.registry_hmac_kms_key_arn,
        "arn:${var.aws_partition}:kms:${var.aws_region}:${var.aws_account_id}:key/",
      )
      error_message = "registry_hmac_kms_key_arn must be in the configured partition, region, and account."
    }

    precondition {
      condition = startswith(
        var.api_certificate_arn,
        "arn:${var.aws_partition}:acm:${var.aws_region}:${var.aws_account_id}:certificate/",
      )
      error_message = "api_certificate_arn must be a regional certificate in the configured partition and account."
    }

    precondition {
      condition     = var.environment != "prod" || var.table_deletion_protection_enabled
      error_message = "Production activation requires DynamoDB deletion protection."
    }

    precondition {
      condition     = var.environment != "prod" || length(var.alarm_topic_arns) > 0
      error_message = "Production activation requires at least one SNS alarm topic ARN."
    }

    precondition {
      condition = alltrue([
        for arn in var.alarm_topic_arns : startswith(
          arn,
          "arn:${var.aws_partition}:sns:${var.aws_region}:${var.aws_account_id}:",
        )
      ])
      error_message = "Every SNS alarm topic must be in the configured partition, region, and account."
    }

    postcondition {
      condition     = self.code_sha256 == var.admission_package_sha256
      error_message = "The published admission Lambda code SHA-256 does not match admission_package_sha256."
    }
  }

  tags = merge(local.common_tags, {
    Name = local.resource_name
  })
}
