locals {
  resource_name         = "${var.name_prefix}-${var.environment}-gateway"
  lambda_log_group_name = "/aws/lambda/${local.resource_name}"
  dns_suffix            = var.aws_partition == "aws-cn" ? "amazonaws.com.cn" : "amazonaws.com"

  lambda_function_arn  = "arn:${var.aws_partition}:lambda:${var.aws_region}:${var.aws_account_id}:function:${local.resource_name}"
  lambda_log_group_arn = "arn:${var.aws_partition}:logs:${var.aws_region}:${var.aws_account_id}:log-group:${local.lambda_log_group_name}"

  production_gateway_enabled = var.enabled && var.environment == "prod"
  registry_v2_enabled        = var.enabled && var.device_registry_mode == "v2"
  apns_enabled               = var.enabled && var.apns_voip_enabled
  deployment_state           = var.enabled ? "provisioned-dark" : "disabled"

  common_tags = {
    DataClassification = "confidential"
    DeploymentState    = local.deployment_state
  }

  lambda_environment = merge(
    {
      APNS_VOIP_ENABLED             = var.apns_voip_enabled ? "1" : "0"
      DDB_TABLE                     = try(aws_dynamodb_table.gateway[0].name, "")
      DEVICE_REGISTRY_MODE          = var.device_registry_mode
      GATEWAY_PUBLIC_URL            = trimsuffix(var.gateway_public_url, "/")
      SENTI_API_BASE_URL            = trimsuffix(var.senti_api_base_url, "/")
      SIGNING_KEY_ID                = var.signing_key_id
      SIGNING_KEY_SECRET_ARN        = var.signing_key_secret_arn
      SIGNING_KEY_SECRET_VERSION_ID = var.signing_key_secret_version_id
    },
    local.registry_v2_enabled ? {
      DEVICE_REGISTRY_CLIENT_V2_READY        = var.device_registry_client_v2_ready
      DEVICE_REGISTRY_HMAC_SECRET_ARN        = var.registry_hmac_secret_arn
      DEVICE_REGISTRY_HMAC_SECRET_VERSION_ID = var.registry_hmac_secret_version_id
      DEVICE_REGISTRY_OUTCOME_PROTOCOL_READY = var.device_registry_outcome_protocol_ready
      DEVICE_REGISTRY_OWNER_CONTINUITY_READY = var.device_registry_owner_continuity_ready
      DEVICE_REGISTRY_V1_PURGED              = var.device_registry_v1_purged
    } : {},
    local.apns_enabled ? {
      APNS_BUNDLE_ID                     = var.apns_bundle_id
      APNS_KEY_ID                        = var.apns_key_id
      APNS_PRIVATE_KEY_SECRET_ARN        = var.apns_private_key_secret_arn
      APNS_PRIVATE_KEY_SECRET_VERSION_ID = var.apns_private_key_secret_version_id
      APNS_TEAM_ID                       = var.apns_team_id
      APNS_VOIP_ENVIRONMENT              = var.apns_voip_environment
    } : {},
  )

  secret_read_statements = concat(
    [{
      Sid      = "ReadPinnedSigningKeyVersion"
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = var.signing_key_secret_arn
      Condition = {
        StringEquals = {
          "secretsmanager:VersionId" = var.signing_key_secret_version_id
        }
      }
    }],
    local.registry_v2_enabled ? [{
      Sid      = "ReadPinnedRegistryHmacVersion"
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = var.registry_hmac_secret_arn
      Condition = {
        StringEquals = {
          "secretsmanager:VersionId" = var.registry_hmac_secret_version_id
        }
      }
    }] : [],
    local.apns_enabled ? [{
      Sid      = "ReadPinnedApnsPrivateKeyVersion"
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = var.apns_private_key_secret_arn
      Condition = {
        StringEquals = {
          "secretsmanager:VersionId" = var.apns_private_key_secret_version_id
        }
      }
    }] : [],
  )

  secret_decrypt_statements = concat(
    [{
      Sid      = "DecryptSigningKeyThroughSecretsManager"
      Effect   = "Allow"
      Action   = ["kms:Decrypt"]
      Resource = var.signing_key_kms_key_arn
      Condition = {
        StringEquals = {
          "kms:ViaService"                  = "secretsmanager.${var.aws_region}.${local.dns_suffix}"
          "kms:EncryptionContext:SecretARN" = var.signing_key_secret_arn
        }
      }
    }],
    local.registry_v2_enabled ? [{
      Sid      = "DecryptRegistryHmacThroughSecretsManager"
      Effect   = "Allow"
      Action   = ["kms:Decrypt"]
      Resource = var.registry_hmac_kms_key_arn
      Condition = {
        StringEquals = {
          "kms:ViaService"                  = "secretsmanager.${var.aws_region}.${local.dns_suffix}"
          "kms:EncryptionContext:SecretARN" = var.registry_hmac_secret_arn
        }
      }
    }] : [],
    local.apns_enabled ? [{
      Sid      = "DecryptApnsPrivateKeyThroughSecretsManager"
      Effect   = "Allow"
      Action   = ["kms:Decrypt"]
      Resource = var.apns_private_key_kms_key_arn
      Condition = {
        StringEquals = {
          "kms:ViaService"                  = "secretsmanager.${var.aws_region}.${local.dns_suffix}"
          "kms:EncryptionContext:SecretARN" = var.apns_private_key_secret_arn
        }
      }
    }] : [],
  )

  runtime_policy_statements = concat(
    [
      {
        Sid    = "GatewayTableExactActions"
        Effect = "Allow"
        Action = [
          "dynamodb:DeleteItem",
          "dynamodb:GetItem",
          "dynamodb:PutItem",
        ]
        Resource = try(aws_dynamodb_table.gateway[0].arn, "")
      },
      {
        Sid      = "DecryptGatewayEnvironment"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = try(aws_kms_key.gateway[0].arn, "")
      },
      {
        Sid      = "WritePrecreatedLambdaLogGroup"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${local.lambda_log_group_arn}:*"
      },
      {
        Sid      = "WriteXRaySegments"
        Effect   = "Allow"
        Action   = ["xray:PutTelemetryRecords", "xray:PutTraceSegments"]
        Resource = "*"
      },
    ],
    local.secret_read_statements,
    local.secret_decrypt_statements,
  )

  lambda_alarms = {
    errors = {
      metric_name = "Errors"
      statistic   = "Sum"
      period      = 60
      threshold   = 0
    }
    throttles = {
      metric_name = "Throttles"
      statistic   = "Sum"
      period      = 60
      threshold   = 0
    }
    duration = {
      metric_name = "Duration"
      statistic   = "Maximum"
      period      = 60
      threshold   = var.gateway_timeout_seconds * 800
    }
    concurrency = {
      metric_name = "ConcurrentExecutions"
      statistic   = "Maximum"
      period      = 60
      threshold   = max(1, floor(var.gateway_reserved_concurrency * 0.8))
    }
  }

  table_alarms = {
    system-errors = {
      metric_name = "SystemErrors"
      statistic   = "Sum"
      period      = 60
      threshold   = 0
    }
    throttled-requests = {
      metric_name = "ThrottledRequests"
      statistic   = "Sum"
      period      = 60
      threshold   = 0
    }
  }

  gateway_metric_alarms = {
    bootstrap-failure = { metric = "gateway_bootstrap_failure" }
    runtime-failure   = { metric = "gateway_runtime_failure" }
    apns-ambiguous    = { metric = "apns_ambiguous" }
    apns-negative     = { metric = "apns_negative_acknowledgement" }
    apns-not-sent     = { metric = "apns_not_sent" }
  }
}
