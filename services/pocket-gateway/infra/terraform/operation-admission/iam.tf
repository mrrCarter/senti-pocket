resource "aws_iam_role" "admission" {
  count = var.enabled ? 1 : 0

  name                 = local.resource_name
  path                 = "/senti-pocket/"
  permissions_boundary = var.iam_permissions_boundary_arn == "" ? null : var.iam_permissions_boundary_arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "LambdaAssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = merge(local.common_tags, {
    Name = local.resource_name
  })
}

resource "aws_iam_role_policy" "admission" {
  count = var.enabled ? 1 : 0

  name = "${local.resource_name}-runtime"
  role = aws_iam_role.admission[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "BoundedAdmissionLedger"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
        ]
        Resource = aws_dynamodb_table.operation_admission[0].arn
        Condition = {
          "ForAllValues:StringLike" = {
            "dynamodb:LeadingKeys" = ["dial:admission:v1:*"]
          }
        }
      },
      {
        Sid      = "ReadPinnedRegistryHmacVersion"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = var.registry_hmac_secret_arn
        Condition = {
          StringEquals = {
            "secretsmanager:VersionId" = var.registry_hmac_secret_version_id
          }
        }
      },
      {
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
      },
      {
        Sid      = "InvokeImmutableGatewayVersionOnly"
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = local.gateway_version_attestation.invoked_function_arn
      },
      {
        Sid      = "DecryptAdmissionEnvironment"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = aws_kms_key.operation_admission[0].arn
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
    ]
  })
}
