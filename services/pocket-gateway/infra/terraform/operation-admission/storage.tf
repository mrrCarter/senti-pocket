resource "aws_dynamodb_table" "operation_admission" {
  count = var.enabled ? 1 : 0

  name                        = local.resource_name
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "pk"
  range_key                   = "sk"
  deletion_protection_enabled = var.table_deletion_protection_enabled

  attribute {
    name = "pk"
    type = "S"
  }

  attribute {
    name = "sk"
    type = "S"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.operation_admission[0].arn
  }

  tags = merge(local.common_tags, {
    Name      = local.resource_name
    DataStore = "bounded-operation-ledger"
  })

  lifecycle {
    prevent_destroy = true
  }

}
