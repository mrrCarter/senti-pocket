data "aws_lambda_invocation" "gateway_version_attestation" {
  count = var.enabled ? 1 : 0

  function_name = var.gateway_lambda_function_name
  qualifier     = var.gateway_lambda_version
  input = jsonencode({
    schema = local.gateway_attestation_request_schema
  })

  # Invoke the exact numeric version through the pinned AWS provider. The gateway handles this exact, non-mutating
  # control event before HTTP normalization, auth, assertion replay storage, or gateway work and returns only the
  # non-secret allowlist below. This avoids both a host-command provider and copying the Lambda Environment map to state.
  lifecycle {
    postcondition {
      condition = try(toset(keys(jsondecode(self.result))) == toset([
        "schema",
        "capability",
        "invoked_function_arn",
        "function_version",
        "registry_mode",
        "v1_purged",
        "client_ready",
        "outcome_ready",
        "owner_ready",
        "hmac_secret_arn",
        "hmac_secret_version_id",
        "assertion_schema",
      ]), false)
      error_message = "The gateway operation-admission attestation must contain only the exact non-secret allowlist."
    }

    postcondition {
      condition = alltrue([
        try(jsondecode(self.result).schema, "") == local.gateway_attestation_response_schema,
        try(jsondecode(self.result).capability, "") == local.gateway_admission_capability,
        try(jsondecode(self.result).assertion_schema, "") == "senti-pocket-operation-admission-assertion-v1",
      ])
      error_message = "The gateway does not advertise the required operation-admission capability and assertion schema."
    }

    postcondition {
      condition = alltrue([
        try(jsondecode(self.result).invoked_function_arn, "") == local.gateway_version_arn,
        try(jsondecode(self.result).function_version, "") == var.gateway_lambda_version,
      ])
      error_message = "The invoked gateway must be the configured immutable numeric Lambda version."
    }

    postcondition {
      condition = alltrue([
        try(jsondecode(self.result).registry_mode, "") == "v2",
        try(jsondecode(self.result).v1_purged, "") == "1",
        try(jsondecode(self.result).client_ready, "") == "1",
        try(jsondecode(self.result).outcome_ready, "") == "1",
        try(jsondecode(self.result).owner_ready, "") == "1",
      ])
      error_message = "The invoked gateway is not an exact Registry V2 operation-admission-capable deployment."
    }

    postcondition {
      condition = alltrue([
        try(jsondecode(self.result).hmac_secret_arn, "") == var.gateway_registry_hmac_secret_arn,
        try(jsondecode(self.result).hmac_secret_version_id, "") == var.gateway_registry_hmac_secret_version_id,
      ])
      error_message = "The invoked gateway does not pin the attested Registry HMAC secret ARN and VersionId."
    }
  }
}
