mock_provider "aws" {
  mock_data "aws_lambda_invocation" {
    defaults = {
      result = <<-JSON
        {"schema":"senti.gateway.operation-admission-attestation.response.v1","capability":"registry-v2-operation-admission-capable","invoked_function_arn":"arn:aws:lambda:us-east-1:123456789012:function:senti-pocket-gateway:42","function_version":"42","registry_mode":"v2","v1_purged":"1","client_ready":"1","outcome_ready":"1","owner_ready":"1","hmac_secret_arn":"arn:aws:secretsmanager:us-east-1:123456789012:secret:senti-pocket-registry-hmac-AbCdEf","hmac_secret_version_id":"0123456789abcdef0123456789abcdef","assertion_schema":"senti-pocket-operation-admission-assertion-v1"}
      JSON
    }
  }

  mock_data "aws_signer_signing_profile" {
    defaults = {
      arn         = "arn:aws:signer:us-east-1:123456789012:/signing-profiles/senti_pocket_admission"
      platform_id = "AWSLambda-SHA384-ECDSA"
      status      = "Active"
      version     = "AbCdEf1234"
      version_arn = "arn:aws:signer:us-east-1:123456789012:/signing-profiles/senti_pocket_admission/AbCdEf1234"
    }
  }

  mock_resource "aws_lambda_function" {
    defaults = {
      arn                  = "arn:aws:lambda:us-east-1:123456789012:function:senti-pocket-test-operation-admission"
      code_sha256          = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
      function_name        = "senti-pocket-test-operation-admission"
      invoke_arn           = "arn:aws:apigateway:us-east-1:lambda:path/2015-03-31/functions/arn:aws:lambda:us-east-1:123456789012:function:senti-pocket-test-operation-admission/invocations"
      qualified_arn        = "arn:aws:lambda:us-east-1:123456789012:function:senti-pocket-test-operation-admission:1"
      qualified_invoke_arn = "arn:aws:apigateway:us-east-1:lambda:path/2015-03-31/functions/arn:aws:lambda:us-east-1:123456789012:function:senti-pocket-test-operation-admission:1/invocations"
      version              = "1"
    }
  }

  mock_resource "aws_lambda_code_signing_config" {
    defaults = {
      arn = "arn:aws:lambda:us-east-1:123456789012:code-signing-config:csc-0123456789abcdefg"
    }
  }

  mock_resource "aws_apigatewayv2_domain_name" {
    defaults = {
      id = "pocket-api.example.com"
      domain_name_configuration = {
        hosted_zone_id     = "Z2FDTNDATAQYW2"
        target_domain_name = "d-example.execute-api.us-east-1.amazonaws.com"
      }
    }
  }
}

variables {
  aws_account_id                          = "123456789012"
  aws_region                              = "us-east-1"
  environment                             = "test"
  api_domain_name                         = "pocket-api.example.com"
  api_certificate_arn                     = "arn:aws:acm:us-east-1:123456789012:certificate/11111111-2222-3333-4444-555555555555"
  route53_zone_id                         = "Z0123456789EXAMPLE"
  gateway_lambda_function_name            = "senti-pocket-gateway"
  gateway_lambda_version                  = "42"
  gateway_release_artifact_sha256         = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
  registry_hmac_secret_arn                = "arn:aws:secretsmanager:us-east-1:123456789012:secret:senti-pocket-registry-hmac-AbCdEf"
  gateway_registry_hmac_secret_arn        = "arn:aws:secretsmanager:us-east-1:123456789012:secret:senti-pocket-registry-hmac-AbCdEf"
  registry_hmac_kms_key_arn               = "arn:aws:kms:us-east-1:123456789012:key/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
  registry_hmac_secret_version_id         = "0123456789abcdef0123456789abcdef"
  gateway_registry_hmac_secret_version_id = "0123456789abcdef0123456789abcdef"
  senti_api_base_url                      = "https://api.example.com"
  admission_package_s3_bucket             = "senti-pocket-artifacts"
  admission_package_s3_key                = "operation-admission/0123456789abcdef.zip"
  admission_package_s3_object_version     = "immutable-object-version"
  admission_package_sha256                = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
  alarm_topic_arns                        = ["arn:aws:sns:us-east-1:123456789012:senti-pocket-alerts"]
}

run "dark_by_default" {
  command = plan

  assert {
    condition = alltrue([
      var.enabled == false,
      length(data.aws_lambda_invocation.gateway_version_attestation) == 0,
      length(data.aws_signer_signing_profile.admission) == 0,
      length(aws_lambda_code_signing_config.admission) == 0,
      length(aws_apigatewayv2_api.operation_admission) == 0,
      length(aws_apigatewayv2_route.protected) == 0,
      length(aws_apigatewayv2_route.gateway) == 0,
      length(aws_lambda_function.admission) == 0,
      length(aws_dynamodb_table.operation_admission) == 0,
      length(aws_kms_key.operation_admission) == 0,
    ])
    error_message = "Dark-by-default must plan no provider lookup or admission resource."
  }
}

run "provisioned_dark_is_explicit_and_numeric_version_pinned" {
  command = plan

  variables {
    enabled = true
  }

  assert {
    condition = toset(keys(aws_apigatewayv2_route.protected)) == toset([
      "POST /dial/register",
      "POST /dial/register/reconcile",
    ])
    error_message = "Exactly the two Registry V2 write routes must use operation admission."
  }

  assert {
    condition = toset(keys(aws_apigatewayv2_route.gateway)) == toset([
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
    error_message = "Every non-protected route must be explicit and use the attested numeric gateway version."
  }

  assert {
    condition = alltrue(concat(
      [for route in values(aws_apigatewayv2_route.protected) : route.route_key != "$default"],
      [for route in values(aws_apigatewayv2_route.gateway) : route.route_key != "$default"],
    ))
    error_message = "A $default route is prohibited."
  }

  assert {
    condition = alltrue([
      aws_apigatewayv2_api.operation_admission[0].disable_execute_api_endpoint,
      aws_apigatewayv2_integration.admission[0].integration_type == "AWS_PROXY",
      aws_apigatewayv2_integration.admission[0].payload_format_version == "2.0",
      aws_apigatewayv2_integration.admission[0].timeout_milliseconds == 29000,
      aws_apigatewayv2_integration.gateway[0].integration_type == "AWS_PROXY",
      aws_apigatewayv2_integration.gateway[0].payload_format_version == "2.0",
      aws_apigatewayv2_integration.gateway[0].timeout_milliseconds == 29000,
      length(aws_lambda_permission.admission_from_api) == 2,
      length(aws_lambda_permission.gateway_from_api) == 13,
    ])
    error_message = "Ingress must disable the provider endpoint and use bounded payload-v2 Lambda proxies."
  }

  assert {
    condition = alltrue([
      var.traffic_enabled == false,
      var.publish_dns == false,
      length(aws_apigatewayv2_api_mapping.operation_admission) == 0,
      length(aws_route53_record.operation_admission) == 0,
      output.public_base_url == null,
      output.cutover_contract.deployment_state == "provisioned-dark",
      output.cutover_contract.ingress_uses_mutable_lambda_aliases == false,
      output.cutover_contract.dark_proof_sha256 == null,
      output.cutover_contract.mapped_proof_sha256 == null,
    ])
    error_message = "Provisioning must remain dark until proof-gated mapping and DNS publication."
  }

  assert {
    condition = alltrue([
      data.aws_lambda_invocation.gateway_version_attestation[0].qualifier == "42",
      jsondecode(data.aws_lambda_invocation.gateway_version_attestation[0].input) == {
        schema = "senti.gateway.operation-admission-attestation.request.v1"
      },
      local.gateway_version_attestation.invoked_function_arn == local.gateway_version_arn,
      local.gateway_version_attestation.function_version == "42",
      aws_apigatewayv2_integration.gateway[0].integration_uri == local.gateway_version_invoke_arn,
      alltrue([for permission in values(aws_lambda_permission.gateway_from_api) : permission.qualifier == "42"]),
      output.gateway_release_manifest.schema == "senti.pocket.gateway-release-evidence.v1",
      output.gateway_release_manifest.artifact_sha256 == var.gateway_release_artifact_sha256,
      output.gateway_release_manifest.function_version == "42",
      can(regex("^[0-9a-f]{64}$", output.gateway_release_manifest.attestation_sha256)),
    ])
    error_message = "The exact numeric gateway version must satisfy attestation and remain immutable through ingress."
  }

  assert {
    condition = toset(keys(aws_lambda_function.admission[0].environment[0].variables)) == toset([
      "DEVICE_REGISTRY_HMAC_SECRET_ARN",
      "DEVICE_REGISTRY_HMAC_SECRET_VERSION_ID",
      "GATEWAY_LAMBDA_VERSION",
      "GATEWAY_LAMBDA_VERSION_ARN",
      "OPERATION_ADMISSION_DDB_TABLE",
      "REGISTRY_OPERATION_ADMISSION_AUTH_MODE",
      "SENTI_API_BASE_URL",
    ])
    error_message = "The admission environment must contain only non-secret references and no readiness assertion."
  }

  assert {
    condition = alltrue([
      aws_lambda_function.admission[0].environment[0].variables["GATEWAY_LAMBDA_VERSION"] == "42",
      aws_lambda_function.admission[0].environment[0].variables["GATEWAY_LAMBDA_VERSION_ARN"] == local.gateway_version_arn,
      aws_lambda_function.admission[0].source_code_hash == "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
      aws_lambda_function.admission[0].s3_object_version == "immutable-object-version",
      length(data.aws_signer_signing_profile.admission) == 0,
      length(aws_lambda_code_signing_config.admission) == 0,
      aws_lambda_function.admission[0].code_signing_config_arn == null,
    ])
    error_message = "Non-production dark provisioning must retain immutable artifacts without inventing a signing policy."
  }

}

run "production_dark_enforces_one_signer_profile" {
  command = plan

  variables {
    enabled                        = true
    environment                    = "prod"
    admission_signing_profile_name = "senti_pocket_admission"
  }

  assert {
    condition = alltrue([
      length(data.aws_signer_signing_profile.admission) == 1,
      data.aws_signer_signing_profile.admission[0].status == "Active",
      data.aws_signer_signing_profile.admission[0].platform_id == "AWSLambda-SHA384-ECDSA",
      length(aws_lambda_code_signing_config.admission) == 1,
      toset(aws_lambda_code_signing_config.admission[0].allowed_publishers[0].signing_profile_version_arns) == toset([
        data.aws_signer_signing_profile.admission[0].version_arn,
      ]),
      aws_lambda_code_signing_config.admission[0].policies[0].untrusted_artifact_on_deployment == "Enforce",
      output.cutover_contract.production_code_signing_enforced,
    ])
    error_message = "Every enabled production deployment, including dark, must structurally enforce one immutable Signer profile."
  }
}

run "reject_attestation_extra_key" {
  command = plan

  variables {
    enabled = true
  }

  override_data {
    target = data.aws_lambda_invocation.gateway_version_attestation[0]
    values = {
      result = <<-JSON
        {"schema":"senti.gateway.operation-admission-attestation.response.v1","capability":"registry-v2-operation-admission-capable","invoked_function_arn":"arn:aws:lambda:us-east-1:123456789012:function:senti-pocket-gateway:42","function_version":"42","registry_mode":"v2","v1_purged":"1","client_ready":"1","outcome_ready":"1","owner_ready":"1","hmac_secret_arn":"arn:aws:secretsmanager:us-east-1:123456789012:secret:senti-pocket-registry-hmac-AbCdEf","hmac_secret_version_id":"0123456789abcdef0123456789abcdef","assertion_schema":"senti-pocket-operation-admission-assertion-v1","unexpected":"must-fail"}
      JSON
    }
  }

  expect_failures = [data.aws_lambda_invocation.gateway_version_attestation[0]]
}

run "reject_attestation_version_arn_drift" {
  command = plan

  variables {
    enabled = true
  }

  override_data {
    target = data.aws_lambda_invocation.gateway_version_attestation[0]
    values = {
      result = <<-JSON
        {"schema":"senti.gateway.operation-admission-attestation.response.v1","capability":"registry-v2-operation-admission-capable","invoked_function_arn":"arn:aws:lambda:us-east-1:123456789012:function:senti-pocket-gateway:43","function_version":"43","registry_mode":"v2","v1_purged":"1","client_ready":"1","outcome_ready":"1","owner_ready":"1","hmac_secret_arn":"arn:aws:secretsmanager:us-east-1:123456789012:secret:senti-pocket-registry-hmac-AbCdEf","hmac_secret_version_id":"0123456789abcdef0123456789abcdef","assertion_schema":"senti-pocket-operation-admission-assertion-v1"}
      JSON
    }
  }

  expect_failures = [data.aws_lambda_invocation.gateway_version_attestation[0]]
}

run "reject_attestation_secret_drift" {
  command = plan

  variables {
    enabled = true
  }

  override_data {
    target = data.aws_lambda_invocation.gateway_version_attestation[0]
    values = {
      result = <<-JSON
        {"schema":"senti.gateway.operation-admission-attestation.response.v1","capability":"registry-v2-operation-admission-capable","invoked_function_arn":"arn:aws:lambda:us-east-1:123456789012:function:senti-pocket-gateway:42","function_version":"42","registry_mode":"v2","v1_purged":"1","client_ready":"1","outcome_ready":"1","owner_ready":"1","hmac_secret_arn":"arn:aws:secretsmanager:us-east-1:123456789012:secret:wrong-secret-AbCdEf","hmac_secret_version_id":"0123456789abcdef0123456789abcdef","assertion_schema":"senti-pocket-operation-admission-assertion-v1"}
      JSON
    }
  }

  expect_failures = [data.aws_lambda_invocation.gateway_version_attestation[0]]
}

run "reject_literal_null_s3_object_version" {
  command = plan

  variables {
    enabled                             = true
    admission_package_s3_object_version = "null"
  }

  expect_failures = [var.admission_package_s3_object_version]
}

run "reject_production_without_signing_profile" {
  command = plan

  variables {
    enabled                        = true
    environment                    = "prod"
    admission_signing_profile_name = ""
  }

  expect_failures = [var.admission_signing_profile_name]
}

run "reject_non_lambda_signing_profile" {
  command = plan

  variables {
    enabled                        = true
    environment                    = "prod"
    admission_signing_profile_name = "senti_pocket_admission"
  }

  override_data {
    target = data.aws_signer_signing_profile.admission[0]
    values = {
      arn         = "arn:aws:signer:us-east-1:123456789012:/signing-profiles/senti_pocket_admission"
      platform_id = "NotLambda"
      status      = "Active"
      version     = "AbCdEf1234"
      version_arn = "arn:aws:signer:us-east-1:123456789012:/signing-profiles/senti_pocket_admission/AbCdEf1234"
    }
  }

  expect_failures = [data.aws_signer_signing_profile.admission[0]]
}

run "reject_inactive_signing_profile" {
  command = plan

  variables {
    enabled                        = true
    environment                    = "prod"
    admission_signing_profile_name = "senti_pocket_admission"
  }

  override_data {
    target = data.aws_signer_signing_profile.admission[0]
    values = {
      arn         = "arn:aws:signer:us-east-1:123456789012:/signing-profiles/senti_pocket_admission"
      platform_id = "AWSLambda-SHA384-ECDSA"
      status      = "Revoked"
      version     = "AbCdEf1234"
      version_arn = "arn:aws:signer:us-east-1:123456789012:/signing-profiles/senti_pocket_admission/AbCdEf1234"
    }
  }

  expect_failures = [data.aws_signer_signing_profile.admission[0]]
}

run "reject_mapping_without_dark_proof" {
  command = plan

  variables {
    enabled           = true
    traffic_enabled   = true
    dark_proof_sha256 = ""
  }

  expect_failures = [aws_apigatewayv2_api_mapping.operation_admission[0]]
}

run "mapped_without_dns_is_explicit" {
  command = plan

  variables {
    enabled           = true
    traffic_enabled   = true
    publish_dns       = false
    dark_proof_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  }

  assert {
    condition = alltrue([
      length(aws_apigatewayv2_api_mapping.operation_admission) == 1,
      length(aws_route53_record.operation_admission) == 0,
      output.cutover_contract.deployment_state == "mapped-no-dns",
      output.cutover_contract.dark_proof_sha256 == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      output.cutover_contract.mapped_proof_sha256 == null,
    ])
    error_message = "Traffic mapping without DNS publication must be proof-gated and machine-readable."
  }
}

run "reject_dns_without_mapped_proof" {
  command = plan

  variables {
    enabled             = true
    traffic_enabled     = true
    publish_dns         = true
    dark_proof_sha256   = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    mapped_proof_sha256 = ""
  }

  expect_failures = [aws_route53_record.operation_admission[0]]
}

run "public_requires_both_proofs" {
  command = plan

  variables {
    enabled             = true
    traffic_enabled     = true
    publish_dns         = true
    dark_proof_sha256   = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    mapped_proof_sha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  }

  assert {
    condition = alltrue([
      length(aws_apigatewayv2_api_mapping.operation_admission) == 1,
      length(aws_route53_record.operation_admission) == 1,
      output.cutover_contract.deployment_state == "public",
      output.cutover_contract.dark_proof_sha256 == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      output.cutover_contract.mapped_proof_sha256 == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    ])
    error_message = "Public DNS requires both retained transition evidence digests."
  }
}

run "reject_wildcard_secret_arns" {
  command = plan

  variables {
    enabled                          = true
    registry_hmac_secret_arn         = "arn:aws:secretsmanager:us-east-1:123456789012:secret:senti-pocket-*"
    gateway_registry_hmac_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:senti-pocket-?"
  }

  expect_failures = [
    var.registry_hmac_secret_arn,
    var.gateway_registry_hmac_secret_arn,
  ]
}

run "reject_noncanonical_proof_digest" {
  command = plan

  variables {
    dark_proof_sha256 = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
  }

  expect_failures = [var.dark_proof_sha256]
}
