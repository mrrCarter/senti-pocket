locals {
  resource_name             = "${var.name_prefix}-${var.environment}-operation-admission"
  lambda_log_group_name     = "/aws/lambda/${local.resource_name}"
  api_access_log_group_name = "/aws/apigateway/${local.resource_name}"
  dns_suffix                = var.aws_partition == "aws-cn" ? "amazonaws.com.cn" : "amazonaws.com"

  lambda_log_group_arn     = "arn:${var.aws_partition}:logs:${var.aws_region}:${var.aws_account_id}:log-group:${local.lambda_log_group_name}"
  api_access_log_group_arn = "arn:${var.aws_partition}:logs:${var.aws_region}:${var.aws_account_id}:log-group:${local.api_access_log_group_name}"
  public_base_url          = "https://${lower(var.api_domain_name)}"

  gateway_version_arn                 = "arn:${var.aws_partition}:lambda:${var.aws_region}:${var.aws_account_id}:function:${var.gateway_lambda_function_name}:${var.gateway_lambda_version}"
  gateway_attestation_request_schema  = "senti.gateway.operation-admission-attestation.request.v1"
  gateway_attestation_response_schema = "senti.gateway.operation-admission-attestation.response.v1"
  gateway_admission_capability        = "registry-v2-operation-admission-capable"
  gateway_version_attestation         = var.enabled ? jsondecode(data.aws_lambda_invocation.gateway_version_attestation[0].result) : null
  gateway_version_invoke_arn          = var.enabled ? "arn:${var.aws_partition}:apigateway:${var.aws_region}:lambda:path/2015-03-31/functions/${local.gateway_version_attestation.invoked_function_arn}/invocations" : null
  gateway_release_manifest = var.enabled ? {
    schema                 = "senti.pocket.gateway-release-evidence.v1"
    artifact_sha256        = var.gateway_release_artifact_sha256
    attestation_sha256     = sha256(jsonencode(local.gateway_version_attestation))
    capability             = local.gateway_admission_capability
    function_version       = local.gateway_version_attestation.function_version
    hmac_secret_arn        = local.gateway_version_attestation.hmac_secret_arn
    hmac_secret_version_id = local.gateway_version_attestation.hmac_secret_version_id
  } : null

  # These body-aware writes have no direct gateway integration in this API. `enabled=true` may safely provision them
  # dark; traffic_enabled and publish_dns are the separately ordered mapping/publication cutover controls.
  protected_route_keys = toset([
    "POST /dial/register",
    "POST /dial/register/reconcile",
  ])

  # Direct non-protected traffic avoids the extra synchronous Lambda hop and remains numeric-version-pinned.
  gateway_route_keys = toset([
    "GET /health",
    "GET /sync",
    "GET /checkpoint",
    "POST /answer",
    "POST /brief",
    "POST /actions/execute",
    "POST /tts",
    "POST /deck",
    "POST /dial",
    "POST /dial/ring-owner",
    "GET /dial",
    "GET /dial/register/context",
    "DELETE /dial/register",
  ])

  enabled_protected_routes = var.enabled ? local.protected_route_keys : toset([])
  enabled_gateway_routes   = var.enabled ? local.gateway_route_keys : toset([])

  deployment_state = !var.enabled ? "disabled" : (
    var.publish_dns ? "public" : (
      var.traffic_enabled ? "mapped-no-dns" : "provisioned-dark"
    )
  )

  common_tags = {
    DataClassification = "confidential"
    DeploymentState    = local.deployment_state
  }

  production_admission_enabled = var.enabled && var.environment == "prod"
}
