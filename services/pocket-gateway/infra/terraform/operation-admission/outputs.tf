output "deployment_enabled" {
  description = "Whether this stack was explicitly provisioned. False is the safe default."
  value       = var.enabled
}

output "traffic_enabled" {
  description = "Whether the custom domain is mapped to the provisioned stage. False is the safe default and rollback posture."
  value       = var.traffic_enabled
}

output "dns_published" {
  description = "Whether this module publishes the Route 53 alias. False is the safe default."
  value       = var.publish_dns
}

output "public_base_url" {
  description = "Canonical mapped custom-domain origin. Null while the stack remains dark."
  value       = var.enabled && var.traffic_enabled ? local.public_base_url : null
}

output "api_id" {
  description = "HTTP API id when the stack is enabled."
  value       = try(aws_apigatewayv2_api.operation_admission[0].id, null)
}

output "admission_lambda_version_arn" {
  description = "Immutable published admission version invoked by protected routes."
  value       = try(aws_lambda_function.admission[0].qualified_arn, null)
}

output "gateway_version_arn" {
  description = "Attested immutable numeric gateway version invoked privately by operation admission."
  value       = var.enabled ? local.gateway_version_attestation.invoked_function_arn : null
}

output "gateway_release_manifest" {
  description = "Machine-readable independent artifact evidence plus a digest of the validated runtime attestation."
  value       = local.gateway_release_manifest
}

output "admission_table_name" {
  description = "Separate bounded operation-ledger DynamoDB table name."
  value       = try(aws_dynamodb_table.operation_admission[0].name, null)
}

output "admission_kms_key_arn" {
  description = "Dedicated KMS key protecting the admission table, Lambda environment, and logs."
  value       = try(aws_kms_key.operation_admission[0].arn, null)
}

output "protected_route_keys" {
  description = "Frozen routes that can reach the gateway only through operation admission."
  value       = sort(tolist(local.protected_route_keys))
}

output "gateway_route_keys" {
  description = "Explicit routes integrated directly with the attested numeric gateway version."
  value       = sort(tolist(local.gateway_route_keys))
}

output "cutover_contract" {
  description = "Machine-readable immutable-version, signing, proof-digest, and dark-stage cutover facts."
  value = {
    resources_created                      = var.enabled
    traffic_mapping_enabled                = var.traffic_enabled
    dns_published                          = var.publish_dns
    deployment_state                       = local.deployment_state
    public_execute_api_endpoint_disabled   = true
    protected_routes_use_admission_version = sort(tolist(local.protected_route_keys))
    remaining_routes_use_gateway_version   = sort(tolist(local.gateway_route_keys))
    admission_auth_mode                    = "senti_session_reusable_v1"
    gateway_function_name                  = var.enabled ? var.gateway_lambda_function_name : null
    gateway_published_version              = var.enabled ? var.gateway_lambda_version : null
    gateway_release_artifact_sha256        = var.enabled ? var.gateway_release_artifact_sha256 : null
    admission_package_sha256               = var.enabled ? var.admission_package_sha256 : null
    ingress_uses_mutable_lambda_aliases    = false
    admission_invokes_numeric_version      = true
    registry_hmac_secret_version_id        = var.enabled ? var.registry_hmac_secret_version_id : null
    registry_hmac_secret_arn               = var.enabled ? var.registry_hmac_secret_arn : null
    gateway_hmac_version_match_required    = true
    dark_proof_sha256                      = var.dark_proof_sha256 == "" ? null : var.dark_proof_sha256
    mapped_proof_sha256                    = var.mapped_proof_sha256 == "" ? null : var.mapped_proof_sha256
    production_code_signing_enforced       = local.production_admission_enabled
    admission_signing_profile_version_arn  = try(data.aws_signer_signing_profile.admission[0].version_arn, null)
    admission_code_signing_config_arn      = try(aws_lambda_code_signing_config.admission[0].arn, null)
  }
}
