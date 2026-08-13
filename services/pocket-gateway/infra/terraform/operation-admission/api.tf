resource "aws_apigatewayv2_api" "operation_admission" {
  count = var.enabled ? 1 : 0

  name                         = local.resource_name
  description                  = "Explicit Senti Pocket gateway routes with body-aware admission on Registry V2 writes"
  protocol_type                = "HTTP"
  disable_execute_api_endpoint = true

  tags = merge(local.common_tags, {
    Name = local.resource_name
  })
}

resource "aws_apigatewayv2_integration" "admission" {
  count = var.enabled ? 1 : 0

  api_id                 = aws_apigatewayv2_api.operation_admission[0].id
  description            = "Protected registration routes pinned to the published admission version"
  integration_type       = "AWS_PROXY"
  integration_method     = "POST"
  integration_uri        = aws_lambda_function.admission[0].qualified_invoke_arn
  payload_format_version = "2.0"
  timeout_milliseconds   = 29000

  depends_on = [aws_lambda_permission.admission_from_api]
}

resource "aws_apigatewayv2_integration" "gateway" {
  count = var.enabled ? 1 : 0

  api_id                 = aws_apigatewayv2_api.operation_admission[0].id
  description            = "Direct non-protected routes pinned to the attested numeric gateway version"
  integration_type       = "AWS_PROXY"
  integration_method     = "POST"
  integration_uri        = local.gateway_version_invoke_arn
  payload_format_version = "2.0"
  timeout_milliseconds   = 29000

  depends_on = [aws_lambda_permission.gateway_from_api]
}

resource "aws_apigatewayv2_route" "protected" {
  for_each = local.enabled_protected_routes

  api_id             = aws_apigatewayv2_api.operation_admission[0].id
  route_key          = each.key
  authorization_type = "NONE"
  target             = "integrations/${aws_apigatewayv2_integration.admission[0].id}"
}

resource "aws_apigatewayv2_route" "gateway" {
  for_each = local.enabled_gateway_routes

  api_id             = aws_apigatewayv2_api.operation_admission[0].id
  route_key          = each.key
  authorization_type = "NONE"
  target             = "integrations/${aws_apigatewayv2_integration.gateway[0].id}"
}

resource "aws_lambda_permission" "admission_from_api" {
  for_each = local.enabled_protected_routes

  statement_id   = "HttpApiProtected${substr(sha1(each.key), 0, 16)}"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.admission[0].function_name
  qualifier      = aws_lambda_function.admission[0].version
  principal      = "apigateway.amazonaws.com"
  source_account = var.aws_account_id
  source_arn = format(
    "%s/%s/%s%s",
    aws_apigatewayv2_api.operation_admission[0].execution_arn,
    var.api_stage_name,
    split(" ", each.key)[0],
    split(" ", each.key)[1],
  )

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lambda_permission" "gateway_from_api" {
  for_each = local.enabled_gateway_routes

  statement_id   = "HttpApiGateway${substr(sha1(each.key), 0, 16)}"
  action         = "lambda:InvokeFunction"
  function_name  = var.gateway_lambda_function_name
  qualifier      = local.gateway_version_attestation.function_version
  principal      = "apigateway.amazonaws.com"
  source_account = var.aws_account_id
  source_arn = format(
    "%s/%s/%s%s",
    aws_apigatewayv2_api.operation_admission[0].execution_arn,
    var.api_stage_name,
    split(" ", each.key)[0],
    split(" ", each.key)[1],
  )

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_apigatewayv2_stage" "live" {
  count = var.enabled ? 1 : 0

  api_id      = aws_apigatewayv2_api.operation_admission[0].id
  name        = var.api_stage_name
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_access[0].arn
    format = jsonencode({
      integrationLatencyMs = "$context.integrationLatency"
      integrationStatus    = "$context.integrationStatus"
      requestId            = "$context.requestId"
      responseLatencyMs    = "$context.responseLatency"
      responseLength       = "$context.responseLength"
      routeKey             = "$context.routeKey"
      status               = "$context.status"
    })
  }

  default_route_settings {
    detailed_metrics_enabled = true
    throttling_burst_limit   = var.api_throttling_burst_limit
    throttling_rate_limit    = var.api_throttling_rate_limit
  }

  dynamic "route_settings" {
    for_each = local.protected_route_keys

    content {
      route_key                = route_settings.value
      detailed_metrics_enabled = true
      throttling_burst_limit   = var.protected_route_throttling_burst_limit
      throttling_rate_limit    = var.protected_route_throttling_rate_limit
    }
  }

  depends_on = [
    aws_apigatewayv2_route.gateway,
    aws_apigatewayv2_route.protected,
  ]

  tags = merge(local.common_tags, {
    Name = "${local.resource_name}-${var.api_stage_name}"
  })
}

resource "aws_apigatewayv2_domain_name" "operation_admission" {
  count = var.enabled ? 1 : 0

  domain_name = lower(var.api_domain_name)

  domain_name_configuration {
    certificate_arn = var.api_certificate_arn
    endpoint_type   = "REGIONAL"
    security_policy = "TLS_1_2"
  }

  tags = merge(local.common_tags, {
    Name = lower(var.api_domain_name)
  })
}

resource "aws_apigatewayv2_api_mapping" "operation_admission" {
  count = var.enabled && var.traffic_enabled ? 1 : 0

  api_id      = aws_apigatewayv2_api.operation_admission[0].id
  domain_name = aws_apigatewayv2_domain_name.operation_admission[0].id
  stage       = aws_apigatewayv2_stage.live[0].id

  depends_on = [
    aws_lambda_permission.admission_from_api,
    aws_lambda_permission.gateway_from_api,
  ]

  lifecycle {
    precondition {
      condition     = can(regex("^[0-9a-f]{64}$", var.dark_proof_sha256))
      error_message = "traffic_enabled requires a retained provisioned-dark evidence-bundle digest."
    }
  }
}

resource "aws_route53_record" "operation_admission" {
  count = var.enabled && var.traffic_enabled && var.publish_dns ? 1 : 0

  zone_id = var.route53_zone_id
  name    = lower(var.api_domain_name)
  type    = "A"

  alias {
    evaluate_target_health = false
    name                   = aws_apigatewayv2_domain_name.operation_admission[0].domain_name_configuration[0].target_domain_name
    zone_id                = aws_apigatewayv2_domain_name.operation_admission[0].domain_name_configuration[0].hosted_zone_id
  }

  depends_on = [
    aws_apigatewayv2_api_mapping.operation_admission,
    aws_lambda_permission.admission_from_api,
    aws_lambda_permission.gateway_from_api,
  ]

  lifecycle {
    precondition {
      condition = (
        can(regex("^[0-9a-f]{64}$", var.dark_proof_sha256)) &&
        can(regex("^[0-9a-f]{64}$", var.mapped_proof_sha256))
      )
      error_message = "publish_dns requires retained provisioned-dark and mapped-no-DNS evidence-bundle digests."
    }
  }
}
