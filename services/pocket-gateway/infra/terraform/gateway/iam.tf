resource "aws_iam_role" "gateway" {
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

  lifecycle {
    precondition {
      condition = var.iam_permissions_boundary_arn == "" || startswith(
        var.iam_permissions_boundary_arn,
        "arn:${var.aws_partition}:iam::${var.aws_account_id}:policy/",
      )
      error_message = "The IAM permissions boundary must belong to the configured partition and account."
    }
  }
}

resource "aws_iam_role_policy" "gateway" {
  count = var.enabled ? 1 : 0

  name = "${local.resource_name}-runtime"
  role = aws_iam_role.gateway[0].id

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.runtime_policy_statements
  })
}
