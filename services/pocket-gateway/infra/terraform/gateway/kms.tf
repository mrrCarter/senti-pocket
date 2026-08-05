resource "aws_kms_key" "gateway" {
  count = var.enabled ? 1 : 0

  description             = "Senti Pocket gateway table, Lambda environment, and log encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  key_usage               = "ENCRYPT_DECRYPT"
  multi_region            = false

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableAccountAdministration"
        Effect = "Allow"
        Principal = {
          AWS = "arn:${var.aws_partition}:iam::${var.aws_account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowCloudWatchLogsEncryption"
        Effect = "Allow"
        Principal = {
          Service = "logs.${var.aws_region}.${local.dns_suffix}"
        }
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey",
          "kms:Encrypt",
          "kms:GenerateDataKey*",
          "kms:ReEncrypt*",
        ]
        Resource = "*"
        Condition = {
          ArnEquals = {
            "kms:EncryptionContext:aws:logs:arn" = local.lambda_log_group_arn
          }
        }
      },
    ]
  })

  tags = merge(local.common_tags, {
    Name = local.resource_name
  })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "gateway" {
  count = var.enabled ? 1 : 0

  name          = "alias/${local.resource_name}"
  target_key_id = aws_kms_key.gateway[0].key_id
}
