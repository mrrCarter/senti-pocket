resource "aws_lambda_function" "gateway" {
  count = var.enabled ? 1 : 0

  function_name = local.resource_name
  description   = "Private Senti Pocket gateway with fail-closed optional APNs VoIP transport"
  role          = aws_iam_role.gateway[0].arn
  handler       = var.gateway_handler
  runtime       = "nodejs22.x"
  architectures = [var.gateway_architecture]

  s3_bucket         = var.gateway_package_s3_bucket
  s3_key            = var.gateway_package_s3_key
  s3_object_version = var.gateway_package_s3_object_version
  source_code_hash  = var.gateway_package_sha256

  publish                        = true
  memory_size                    = var.gateway_memory_mb
  timeout                        = var.gateway_timeout_seconds
  reserved_concurrent_executions = var.gateway_reserved_concurrency
  kms_key_arn                    = aws_kms_key.gateway[0].arn
  code_signing_config_arn        = local.production_gateway_enabled ? aws_lambda_code_signing_config.gateway[0].arn : null
  layers                         = var.gateway_layers

  ephemeral_storage {
    size = 512
  }

  environment {
    variables = local.lambda_environment
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
    aws_cloudwatch_log_group.gateway_lambda,
    aws_iam_role_policy.gateway,
  ]

  lifecycle {
    precondition {
      condition = startswith(
        var.signing_key_secret_arn,
        "arn:${var.aws_partition}:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:",
      )
      error_message = "The signing secret must belong to the configured partition, region, and account."
    }

    precondition {
      condition = startswith(
        var.signing_key_kms_key_arn,
        "arn:${var.aws_partition}:kms:${var.aws_region}:${var.aws_account_id}:key/",
      )
      error_message = "The signing-secret KMS key must belong to the configured partition, region, and account."
    }

    precondition {
      condition = !local.registry_v2_enabled || alltrue([
        var.device_registry_v1_purged == "1",
        var.device_registry_client_v2_ready == "1",
        var.device_registry_outcome_protocol_ready == "1",
        var.device_registry_owner_continuity_ready == "1",
      ])
      error_message = "Registry V2 requires all four explicit purge, client, outcome, and owner-continuity readiness proofs."
    }

    precondition {
      condition = !local.registry_v2_enabled || startswith(
        var.registry_hmac_secret_arn,
        "arn:${var.aws_partition}:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:",
      )
      error_message = "The Registry HMAC secret must belong to the configured partition, region, and account."
    }

    precondition {
      condition = !local.registry_v2_enabled || startswith(
        var.registry_hmac_kms_key_arn,
        "arn:${var.aws_partition}:kms:${var.aws_region}:${var.aws_account_id}:key/",
      )
      error_message = "The Registry HMAC KMS key must belong to the configured partition, region, and account."
    }

    precondition {
      condition = !local.apns_enabled || startswith(
        var.apns_private_key_secret_arn,
        "arn:${var.aws_partition}:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:",
      )
      error_message = "The APNs private-key secret must belong to the configured partition, region, and account."
    }

    precondition {
      condition = !local.apns_enabled || startswith(
        var.apns_private_key_kms_key_arn,
        "arn:${var.aws_partition}:kms:${var.aws_region}:${var.aws_account_id}:key/",
      )
      error_message = "The APNs private-key KMS key must belong to the configured partition, region, and account."
    }

    precondition {
      condition     = var.environment != "prod" || length(var.alarm_topic_arns) > 0
      error_message = "Production gateway provisioning requires at least one SNS alarm topic."
    }

    precondition {
      condition = alltrue([
        for arn in var.alarm_topic_arns : startswith(
          arn,
          "arn:${var.aws_partition}:sns:${var.aws_region}:${var.aws_account_id}:",
        )
      ])
      error_message = "Every SNS alarm topic must belong to the configured partition, region, and account."
    }

    postcondition {
      condition     = self.code_sha256 == var.gateway_package_sha256
      error_message = "The published gateway Lambda code SHA-256 does not match gateway_package_sha256."
    }

    postcondition {
      condition = (
        can(regex("^[1-9][0-9]*$", self.version)) &&
        endswith(self.qualified_arn, ":${self.version}")
      )
      error_message = "The gateway deployment must publish and expose one immutable numeric Lambda version."
    }
  }

  tags = merge(local.common_tags, {
    Name = local.resource_name
  })
}
