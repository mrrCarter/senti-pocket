data "aws_signer_signing_profile" "admission" {
  count = local.production_admission_enabled ? 1 : 0

  name = var.admission_signing_profile_name

  lifecycle {
    postcondition {
      condition     = self.platform_id == "AWSLambda-SHA384-ECDSA"
      error_message = "The production admission signing profile must use AWSLambda-SHA384-ECDSA."
    }

    postcondition {
      condition     = self.status == "Active"
      error_message = "The production admission signing profile must be Active."
    }

    postcondition {
      condition = self.arn == join("", [
        "arn:", var.aws_partition, ":signer:", var.aws_region, ":",
        var.aws_account_id, ":/signing-profiles/",
        var.admission_signing_profile_name,
      ])
      error_message = "The signing profile must belong to the configured partition, region, account, and profile name."
    }

    postcondition {
      condition = (
        can(regex("^[A-Za-z0-9]{10}$", self.version)) &&
        self.version_arn == "${self.arn}/${self.version}"
      )
      error_message = "The signing profile must expose its exact immutable ten-character profile version ARN."
    }
  }
}

resource "aws_lambda_code_signing_config" "admission" {
  count = local.production_admission_enabled ? 1 : 0

  description = "Senti Pocket production operation-admission trust policy"

  allowed_publishers {
    signing_profile_version_arns = [
      data.aws_signer_signing_profile.admission[0].version_arn,
    ]
  }

  policies {
    untrusted_artifact_on_deployment = "Enforce"
  }

  lifecycle {
    postcondition {
      condition = (
        length(self.allowed_publishers) == 1 &&
        toset(self.allowed_publishers[0].signing_profile_version_arns) ==
        toset([data.aws_signer_signing_profile.admission[0].version_arn])
      )
      error_message = "The code-signing configuration must trust exactly one immutable profile version."
    }

    postcondition {
      condition = (
        length(self.policies) == 1 &&
        self.policies[0].untrusted_artifact_on_deployment == "Enforce"
      )
      error_message = "Untrusted Lambda artifacts must be rejected."
    }
  }

  tags = merge(local.common_tags, {
    Name = "${local.resource_name}-code-signing"
  })
}
