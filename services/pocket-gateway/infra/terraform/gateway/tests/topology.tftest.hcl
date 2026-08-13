mock_provider "aws" {
  mock_data "aws_signer_signing_profile" {
    defaults = {
      arn         = "arn:aws:signer:us-east-1:123456789012:/signing-profiles/senti_pocket_gateway"
      platform_id = "AWSLambda-SHA384-ECDSA"
      status      = "Active"
      version     = "AbCdEf1234"
      version_arn = "arn:aws:signer:us-east-1:123456789012:/signing-profiles/senti_pocket_gateway/AbCdEf1234"
    }
  }

  mock_resource "aws_lambda_function" {
    defaults = {
      arn           = "arn:aws:lambda:us-east-1:123456789012:function:senti-pocket-test-gateway"
      code_sha256   = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
      function_name = "senti-pocket-test-gateway"
      qualified_arn = "arn:aws:lambda:us-east-1:123456789012:function:senti-pocket-test-gateway:42"
      version       = "42"
    }
  }

  mock_resource "aws_lambda_code_signing_config" {
    defaults = {
      arn = "arn:aws:lambda:us-east-1:123456789012:code-signing-config:csc-0123456789abcdefg"
    }
  }

  mock_resource "aws_dynamodb_table" {
    defaults = {
      arn  = "arn:aws:dynamodb:us-east-1:123456789012:table/senti-pocket-test-gateway"
      name = "senti-pocket-test-gateway"
    }
  }

  mock_resource "aws_kms_key" {
    defaults = {
      arn    = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
      key_id = "11111111-2222-3333-4444-555555555555"
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/senti-pocket/senti-pocket-test-gateway"
      id  = "senti-pocket-test-gateway"
    }
  }
}

variables {
  aws_account_id                     = "123456789012"
  aws_region                         = "us-east-1"
  environment                        = "test"
  gateway_package_s3_bucket          = "senti-pocket-artifacts"
  gateway_package_s3_key             = "gateway/0123456789abcdef.zip"
  gateway_package_s3_object_version  = "immutable-object-version"
  gateway_package_sha256             = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
  gateway_public_url                 = "https://pocket-api.example.com"
  senti_api_base_url                 = "https://api.example.com"
  signing_key_id                     = "gateway-signing-v1"
  signing_key_secret_arn             = "arn:aws:secretsmanager:us-east-1:123456789012:secret:gateway-signing-AbCdEf"
  signing_key_secret_version_id      = "0123456789abcdef0123456789abcdef"
  signing_key_kms_key_arn            = "arn:aws:kms:us-east-1:123456789012:key/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
  registry_hmac_secret_arn           = "arn:aws:secretsmanager:us-east-1:123456789012:secret:registry-hmac-GhIjKl"
  registry_hmac_secret_version_id    = "abcdef0123456789abcdef0123456789"
  registry_hmac_kms_key_arn          = "arn:aws:kms:us-east-1:123456789012:key/bbbbbbbb-cccc-dddd-eeee-ffffffffffff"
  apns_team_id                       = "ABCDE12345"
  apns_key_id                        = "FGHIJ67890"
  apns_bundle_id                     = "com.plexaura.sentipocket.app"
  apns_voip_environment              = "development"
  apns_private_key_secret_arn        = "arn:aws:secretsmanager:us-east-1:123456789012:secret:apns-development-MnOpQr"
  apns_private_key_secret_version_id = "fedcba9876543210fedcba9876543210"
  apns_private_key_kms_key_arn       = "arn:aws:kms:us-east-1:123456789012:key/cccccccc-dddd-eeee-ffff-000000000000"
  gateway_signing_profile_name       = "senti_pocket_gateway"
  alarm_topic_arns                   = ["arn:aws:sns:us-east-1:123456789012:senti-pocket-alerts"]
}

run "disabled_by_default" {
  command = plan

  assert {
    condition = alltrue([
      var.enabled == false,
      length(data.aws_signer_signing_profile.gateway) == 0,
      length(aws_lambda_code_signing_config.gateway) == 0,
      length(aws_lambda_function.gateway) == 0,
      length(aws_dynamodb_table.gateway) == 0,
      length(aws_kms_key.gateway) == 0,
      length(aws_iam_role.gateway) == 0,
      length(aws_cloudwatch_log_group.gateway_lambda) == 0,
      length(aws_cloudwatch_log_metric_filter.gateway_events) == 0,
      length(aws_cloudwatch_metric_alarm.lambda) == 0,
      length(aws_cloudwatch_metric_alarm.table) == 0,
      length(aws_cloudwatch_metric_alarm.gateway_events) == 0,
    ])
    error_message = "The gateway stack must perform no provider lookup and create no resource until explicitly enabled."
  }

  assert {
    condition = alltrue([
      output.deployment_state == "disabled",
      output.cutover_contract.public_api_created == false,
      output.cutover_contract.lambda_function_url_created == false,
      output.cutover_contract.lambda_invoke_permission_created == false,
      output.cutover_contract.mutable_lambda_alias_created == false,
    ])
    error_message = "The disabled cutover contract must remain private and alias-free."
  }
}

run "registry_v1_apns_off_is_private_and_minimal" {
  command = plan

  variables {
    enabled = true
  }

  assert {
    condition = alltrue([
      length(aws_lambda_function.gateway) == 1,
      length(aws_dynamodb_table.gateway) == 1,
      length(aws_kms_key.gateway) == 1,
      length(aws_iam_role.gateway) == 1,
      aws_lambda_function.gateway[0].runtime == "nodejs22.x",
      aws_lambda_function.gateway[0].publish == true,
      aws_lambda_function.gateway[0].s3_object_version == var.gateway_package_s3_object_version,
      aws_lambda_function.gateway[0].source_code_hash == var.gateway_package_sha256,
      aws_lambda_function.gateway[0].code_signing_config_arn == null,
    ])
    error_message = "The enabled test stack must create one exact-version dark gateway release."
  }

  assert {
    condition = alltrue([
      toset(keys(aws_lambda_function.gateway[0].environment[0].variables)) == toset([
        "APNS_VOIP_ENABLED",
        "DDB_TABLE",
        "DEVICE_REGISTRY_MODE",
        "GATEWAY_PUBLIC_URL",
        "SENTI_API_BASE_URL",
        "SIGNING_KEY_ID",
        "SIGNING_KEY_SECRET_ARN",
        "SIGNING_KEY_SECRET_VERSION_ID",
      ]),
      aws_lambda_function.gateway[0].environment[0].variables.APNS_VOIP_ENABLED == "0",
      aws_lambda_function.gateway[0].environment[0].variables.DDB_TABLE == aws_dynamodb_table.gateway[0].name,
      aws_lambda_function.gateway[0].environment[0].variables.DEVICE_REGISTRY_MODE == "v1",
      aws_lambda_function.gateway[0].environment[0].variables.GATEWAY_PUBLIC_URL == "https://pocket-api.example.com",
      aws_lambda_function.gateway[0].environment[0].variables.SENTI_API_BASE_URL == "https://api.example.com",
      aws_lambda_function.gateway[0].environment[0].variables.SIGNING_KEY_ID == var.signing_key_id,
      aws_lambda_function.gateway[0].environment[0].variables.SIGNING_KEY_SECRET_ARN == var.signing_key_secret_arn,
      aws_lambda_function.gateway[0].environment[0].variables.SIGNING_KEY_SECRET_VERSION_ID == var.signing_key_secret_version_id,
    ])
    error_message = "Registry V1 with APNs off must omit every APNs and Registry V2 secret/config field."
  }

  assert {
    condition = toset([
      for statement in local.runtime_policy_statements : statement.Sid
      ]) == toset([
      "GatewayTableExactActions",
      "DecryptGatewayEnvironment",
      "WritePrecreatedLambdaLogGroup",
      "WriteXRaySegments",
      "ReadPinnedSigningKeyVersion",
      "DecryptSigningKeyThroughSecretsManager",
    ])
    error_message = "APNs-off Registry V1 IAM must include no APNs or Registry HMAC authority."
  }

  assert {
    condition = alltrue([
      aws_dynamodb_table.gateway[0].billing_mode == "PAY_PER_REQUEST",
      aws_dynamodb_table.gateway[0].ttl[0].enabled,
      aws_dynamodb_table.gateway[0].ttl[0].attribute_name == "ttl",
      aws_dynamodb_table.gateway[0].point_in_time_recovery[0].enabled,
      aws_dynamodb_table.gateway[0].server_side_encryption[0].enabled,
      output.deployment_state == "provisioned-dark",
      output.cutover_contract.numeric_version_published,
      !output.cutover_contract.public_api_created,
      !output.cutover_contract.mutable_lambda_alias_created,
      !output.cutover_contract.target_membership_release_proven,
    ])
    error_message = "The state plane must be encrypted/durable and the release must remain explicitly dark."
  }
}

run "registry_v2_apns_on_adds_only_exact_pinned_authority" {
  command = plan

  variables {
    enabled                                = true
    device_registry_mode                   = "v2"
    device_registry_v1_purged              = "1"
    device_registry_client_v2_ready        = "1"
    device_registry_outcome_protocol_ready = "1"
    device_registry_owner_continuity_ready = "1"
    apns_voip_enabled                      = true
  }

  assert {
    condition = alltrue([
      aws_lambda_function.gateway[0].environment[0].variables.APNS_VOIP_ENABLED == "1",
      aws_lambda_function.gateway[0].environment[0].variables.APNS_PRIVATE_KEY_SECRET_ARN == var.apns_private_key_secret_arn,
      aws_lambda_function.gateway[0].environment[0].variables.APNS_PRIVATE_KEY_SECRET_VERSION_ID == var.apns_private_key_secret_version_id,
      aws_lambda_function.gateway[0].environment[0].variables.DEVICE_REGISTRY_HMAC_SECRET_ARN == var.registry_hmac_secret_arn,
      aws_lambda_function.gateway[0].environment[0].variables.DEVICE_REGISTRY_HMAC_SECRET_VERSION_ID == var.registry_hmac_secret_version_id,
      !contains(keys(aws_lambda_function.gateway[0].environment[0].variables), "APNS_PRIVATE_KEY"),
      !contains(keys(aws_lambda_function.gateway[0].environment[0].variables), "DEVICE_REGISTRY_HMAC_KEY_B64"),
    ])
    error_message = "APNs/V2 environment may contain only immutable pins and public metadata, never key material."
  }

  assert {
    condition = toset([
      for statement in local.runtime_policy_statements : statement.Sid
      ]) == toset([
      "GatewayTableExactActions",
      "DecryptGatewayEnvironment",
      "WritePrecreatedLambdaLogGroup",
      "WriteXRaySegments",
      "ReadPinnedSigningKeyVersion",
      "ReadPinnedRegistryHmacVersion",
      "ReadPinnedApnsPrivateKeyVersion",
      "DecryptSigningKeyThroughSecretsManager",
      "DecryptRegistryHmacThroughSecretsManager",
      "DecryptApnsPrivateKeyThroughSecretsManager",
    ])
    error_message = "APNs/V2 IAM must add exactly the two separately pinned secret/decrypt pairs."
  }

  assert {
    condition = alltrue([
      for statement in [
        for item in local.secret_read_statements : item
        if startswith(item.Sid, "ReadPinned")
        ] : (
        statement.Action == ["secretsmanager:GetSecretValue"] &&
        length(statement.Resource) > 20 &&
        statement.Condition.StringEquals["secretsmanager:VersionId"] != ""
      )
    ])
    error_message = "Every secret read must target one ARN and require one immutable VersionId."
  }

  assert {
    condition = alltrue([
      output.gateway_release_manifest.apns_enabled,
      output.gateway_release_manifest.apns_topic == "com.plexaura.sentipocket.app.voip",
      output.gateway_release_manifest.registry_mode == "v2",
      !output.cutover_contract.apns_secret_value_in_terraform,
      !output.cutover_contract.registry_hmac_value_in_terraform,
    ])
    error_message = "Release evidence must record APNs routing metadata and explicitly exclude secret values."
  }
}

run "production_enforces_one_signer" {
  command = plan

  variables {
    enabled     = true
    environment = "prod"
  }

  assert {
    condition = alltrue([
      length(data.aws_signer_signing_profile.gateway) == 1,
      length(aws_lambda_code_signing_config.gateway) == 1,
      aws_lambda_code_signing_config.gateway[0].policies[0].untrusted_artifact_on_deployment == "Enforce",
      toset(aws_lambda_code_signing_config.gateway[0].allowed_publishers[0].signing_profile_version_arns) == toset([
        data.aws_signer_signing_profile.gateway[0].version_arn,
      ]),
      output.cutover_contract.production_code_signing_enforced,
    ])
    error_message = "Production must enforce exactly one immutable AWS Signer publisher."
  }
}

run "registry_v2_refuses_unproven_cutover" {
  command = plan

  variables {
    enabled              = true
    device_registry_mode = "v2"
  }

  expect_failures = [aws_lambda_function.gateway]
}

run "apns_refuses_missing_team_id" {
  command = plan

  variables {
    enabled           = true
    apns_voip_enabled = true
    apns_team_id      = ""
  }

  expect_failures = [var.apns_team_id]
}

run "artifact_refuses_unversioned_s3_marker" {
  command = plan

  variables {
    enabled                           = true
    gateway_package_s3_object_version = "null"
  }

  expect_failures = [var.gateway_package_s3_object_version]
}

run "artifact_refuses_whitespace_object_version" {
  command = plan

  variables {
    enabled                           = true
    gateway_package_s3_object_version = "   "
  }

  expect_failures = [var.gateway_package_s3_object_version]
}

run "gateway_refuses_non_origin_public_url" {
  command = plan

  variables {
    enabled            = true
    gateway_public_url = "https://pocket-api.example.com/private/path"
  }

  expect_failures = [var.gateway_public_url]
}

run "apns_refuses_missing_secret_version_pin" {
  command = plan

  variables {
    enabled                            = true
    apns_voip_enabled                  = true
    apns_private_key_secret_version_id = ""
  }

  expect_failures = [var.apns_private_key_secret_version_id]
}

run "production_refuses_missing_alarm_destination" {
  command = plan

  variables {
    enabled          = true
    environment      = "prod"
    alarm_topic_arns = []
  }

  expect_failures = [aws_lambda_function.gateway]
}

run "production_refuses_unprotected_table" {
  command = plan

  variables {
    enabled                           = true
    environment                       = "prod"
    table_deletion_protection_enabled = false
  }

  expect_failures = [aws_dynamodb_table.gateway]
}
