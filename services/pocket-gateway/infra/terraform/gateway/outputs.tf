output "deployment_enabled" {
  description = "Whether the private gateway data/compute plane was explicitly provisioned."
  value       = var.enabled
}

output "deployment_state" {
  description = "Disabled or provisioned-dark. This module cannot create public ingress."
  value       = local.deployment_state
}

output "gateway_table_name" {
  description = "Durable gateway state and device-registry table name."
  value       = try(aws_dynamodb_table.gateway[0].name, null)
}

output "gateway_table_arn" {
  description = "Durable gateway state and device-registry table ARN."
  value       = try(aws_dynamodb_table.gateway[0].arn, null)
}

output "gateway_kms_key_arn" {
  description = "Dedicated KMS key protecting the table, Lambda environment, and logs."
  value       = try(aws_kms_key.gateway[0].arn, null)
}

output "gateway_lambda_function_name" {
  description = "Unqualified private gateway Lambda function name."
  value       = try(aws_lambda_function.gateway[0].function_name, null)
}

output "gateway_lambda_version" {
  description = "Immutable numeric gateway version published by this release."
  value       = try(aws_lambda_function.gateway[0].version, null)
}

output "gateway_lambda_version_arn" {
  description = "Immutable qualified gateway version ARN for later operation-admission attestation and exact invocation grants."
  value       = try(aws_lambda_function.gateway[0].qualified_arn, null)
}

output "gateway_release_manifest" {
  description = "Non-secret machine-readable evidence for the exact dark gateway release."
  value = var.enabled ? {
    schema                          = "senti.pocket.gateway-dark-release.v1"
    deployment_state                = local.deployment_state
    artifact_sha256                 = var.gateway_package_sha256
    function_name                   = aws_lambda_function.gateway[0].function_name
    function_version                = aws_lambda_function.gateway[0].version
    function_version_arn            = aws_lambda_function.gateway[0].qualified_arn
    registry_mode                   = var.device_registry_mode
    signing_secret_arn              = var.signing_key_secret_arn
    signing_secret_version_id       = var.signing_key_secret_version_id
    registry_hmac_secret_arn        = local.registry_v2_enabled ? var.registry_hmac_secret_arn : null
    registry_hmac_secret_version_id = local.registry_v2_enabled ? var.registry_hmac_secret_version_id : null
    apns_enabled                    = local.apns_enabled
    apns_environment                = local.apns_enabled ? var.apns_voip_environment : null
    apns_topic                      = local.apns_enabled ? "${var.apns_bundle_id}.voip" : null
    apns_secret_arn                 = local.apns_enabled ? var.apns_private_key_secret_arn : null
    apns_secret_version_id          = local.apns_enabled ? var.apns_private_key_secret_version_id : null
    signer_profile_version_arn      = try(data.aws_signer_signing_profile.gateway[0].version_arn, null)
    code_signing_config_arn         = try(aws_lambda_code_signing_config.gateway[0].arn, null)
  } : null
}

output "cutover_contract" {
  description = "Machine-readable proof that this stack is private, alias-free, version-pinned, and APNs opt-in."
  value = {
    resources_created                = var.enabled
    deployment_state                 = local.deployment_state
    public_api_created               = false
    lambda_function_url_created      = false
    lambda_invoke_permission_created = false
    mutable_lambda_alias_created     = false
    numeric_version_published        = var.enabled
    apns_enabled                     = local.apns_enabled
    apns_secret_value_in_terraform   = false
    registry_hmac_value_in_terraform = false
    signing_key_value_in_terraform   = false
    target_membership_release_proven = false
    production_code_signing_enforced = local.production_gateway_enabled
  }
}
