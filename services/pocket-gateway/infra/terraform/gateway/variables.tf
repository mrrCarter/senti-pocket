variable "enabled" {
  description = "Explicitly provision the private gateway compute and data plane. False creates no resources."
  type        = bool
  default     = false
}

variable "aws_partition" {
  description = "AWS partition used to construct and validate exact ARNs."
  type        = string
  default     = "aws"

  validation {
    condition     = contains(["aws", "aws-cn", "aws-us-gov"], var.aws_partition)
    error_message = "aws_partition must be aws, aws-cn, or aws-us-gov."
  }
}

variable "aws_region" {
  description = "AWS region for the gateway stack."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[1-9][0-9]*$", var.aws_region))
    error_message = "aws_region must be a canonical AWS region name."
  }
}

variable "aws_account_id" {
  description = "Twelve-digit AWS account allowed to own every enabled resource."
  type        = string
  default     = ""

  validation {
    condition     = !var.enabled || can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id must be twelve digits when enabled."
  }
}

variable "environment" {
  description = "Deployment environment label. Production additionally enforces signing, alarms, and deletion protection."
  type        = string
  default     = "test"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,15}$", var.environment))
    error_message = "environment must be a lowercase 1-16 character label."
  }
}

variable "name_prefix" {
  description = "Stable resource-name prefix."
  type        = string
  default     = "senti-pocket"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,31}$", var.name_prefix))
    error_message = "name_prefix must be a lowercase 2-32 character resource prefix."
  }
}

variable "tags" {
  description = "Additional resource tags."
  type        = map(string)
  default     = {}
}

variable "iam_permissions_boundary_arn" {
  description = "Optional IAM permissions boundary for the gateway execution role."
  type        = string
  default     = ""

  validation {
    condition = var.iam_permissions_boundary_arn == "" || can(regex(
      "^arn:(aws|aws-cn|aws-us-gov):iam::[0-9]{12}:policy/[A-Za-z0-9+=,.@_/-]{1,128}$",
      var.iam_permissions_boundary_arn,
    ))
    error_message = "iam_permissions_boundary_arn must be empty or a complete IAM policy ARN."
  }
}

variable "gateway_package_s3_bucket" {
  description = "Versioned S3 bucket containing the AWS-Signer-produced gateway ZIP."
  type        = string
  default     = ""

  validation {
    condition     = !var.enabled || can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.gateway_package_s3_bucket))
    error_message = "gateway_package_s3_bucket must be a valid bucket name when enabled."
  }
}

variable "gateway_package_s3_key" {
  description = "Exact S3 key of the signed gateway ZIP."
  type        = string
  default     = ""

  validation {
    condition = !var.enabled || (
      length(var.gateway_package_s3_key) >= 1 &&
      length(var.gateway_package_s3_key) <= 1024 &&
      can(regex("^[^\r\n]+$", var.gateway_package_s3_key))
    )
    error_message = "gateway_package_s3_key must be a non-empty bounded key when enabled."
  }
}

variable "gateway_package_s3_object_version" {
  description = "Immutable S3 VersionId of the signed gateway ZIP."
  type        = string
  default     = ""

  validation {
    condition = !var.enabled || (
      trimspace(var.gateway_package_s3_object_version) == var.gateway_package_s3_object_version &&
      lower(var.gateway_package_s3_object_version) != "null" &&
      length(var.gateway_package_s3_object_version) >= 1 &&
      length(var.gateway_package_s3_object_version) <= 1024 &&
      can(regex("^[^\r\n]+$", var.gateway_package_s3_object_version))
    )
    error_message = "gateway_package_s3_object_version must be a non-empty immutable version, never S3's null/unversioned marker or whitespace drift."
  }
}

variable "gateway_package_sha256" {
  description = "Canonical base64 SHA-256 of the signed gateway ZIP supplied to Lambda source_code_hash."
  type        = string
  default     = ""

  validation {
    condition     = !var.enabled || can(regex("^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$", var.gateway_package_sha256))
    error_message = "gateway_package_sha256 must be a canonical 44-character base64 SHA-256 when enabled."
  }
}

variable "gateway_handler" {
  description = "Gateway Lambda handler in module.export form."
  type        = string
  default     = "index.handler"

  validation {
    condition     = can(regex("^[A-Za-z0-9_./-]+\\.[A-Za-z0-9_$-]+$", var.gateway_handler))
    error_message = "gateway_handler must use the module.export form."
  }
}

variable "gateway_architecture" {
  description = "Gateway Lambda instruction-set architecture."
  type        = string
  default     = "arm64"

  validation {
    condition     = contains(["arm64", "x86_64"], var.gateway_architecture)
    error_message = "gateway_architecture must be arm64 or x86_64."
  }
}

variable "gateway_memory_mb" {
  description = "Gateway Lambda memory allocation."
  type        = number
  default     = 1024

  validation {
    condition     = floor(var.gateway_memory_mb) == var.gateway_memory_mb && var.gateway_memory_mb >= 128 && var.gateway_memory_mb <= 10240
    error_message = "gateway_memory_mb must be an integer from 128 through 10240."
  }
}

variable "gateway_timeout_seconds" {
  description = "Gateway timeout, bounded below the downstream HTTP API integration timeout."
  type        = number
  default     = 28

  validation {
    condition     = floor(var.gateway_timeout_seconds) == var.gateway_timeout_seconds && var.gateway_timeout_seconds >= 11 && var.gateway_timeout_seconds <= 28
    error_message = "gateway_timeout_seconds must be an integer from 11 through 28 so the ten-second APNs deadline can complete."
  }
}

variable "gateway_reserved_concurrency" {
  description = "Hard concurrency ceiling for gateway cold starts, upstream calls, and APNs sessions."
  type        = number
  default     = 20

  validation {
    condition     = floor(var.gateway_reserved_concurrency) == var.gateway_reserved_concurrency && var.gateway_reserved_concurrency >= 1 && var.gateway_reserved_concurrency <= 1000
    error_message = "gateway_reserved_concurrency must be an integer from 1 through 1000."
  }
}

variable "gateway_layers" {
  description = "Optional immutable Lambda layer-version ARNs."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for arn in var.gateway_layers : can(regex(
        "^arn:(aws|aws-cn|aws-us-gov):lambda:[a-z0-9-]+:[0-9]{12}:layer:[A-Za-z0-9_-]{1,140}:[1-9][0-9]*$",
        arn,
      ))
    ])
    error_message = "Every gateway layer must be an immutable numeric layer-version ARN."
  }
}

variable "gateway_signing_profile_name" {
  description = "Existing AWS Signer profile name trusted for production gateway artifacts."
  type        = string
  default     = ""

  validation {
    condition     = !var.enabled || var.environment != "prod" || can(regex("^[A-Za-z0-9_]{2,64}$", var.gateway_signing_profile_name))
    error_message = "gateway_signing_profile_name must identify a valid profile for enabled production."
  }
}

variable "gateway_public_url" {
  description = "Future canonical Pocket gateway HTTPS origin used for request binding; this module does not publish it."
  type        = string
  default     = ""

  validation {
    condition = !var.enabled || can(regex(
      "^https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?/?$",
      var.gateway_public_url,
    ))
    error_message = "gateway_public_url must be an HTTPS origin without credentials, query, fragment, or path when enabled."
  }
}

variable "senti_api_base_url" {
  description = "Canonical HTTPS Senti API origin for session validation, target membership, and governed writes."
  type        = string
  default     = ""

  validation {
    condition = !var.enabled || can(regex(
      "^https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?/?$",
      var.senti_api_base_url,
    ))
    error_message = "senti_api_base_url must be an HTTPS origin without credentials, query, fragment, or path when enabled."
  }
}

variable "signing_key_id" {
  description = "Stable public identifier bound into gateway receipts and bundles."
  type        = string
  default     = ""

  validation {
    condition     = !var.enabled || can(regex("^[A-Za-z0-9._:-]{1,128}$", var.signing_key_id))
    error_message = "signing_key_id must be a bounded stable identifier when enabled."
  }
}

variable "signing_key_secret_arn" {
  description = "Complete ARN of the existing Ed25519 PKCS#8 receipt-signing secret. No key material enters Terraform."
  type        = string
  default     = ""

  validation {
    condition     = !var.enabled || can(regex("^arn:(aws|aws-cn|aws-us-gov):secretsmanager:[a-z0-9-]{1,32}:[0-9]{12}:secret:[A-Za-z0-9/_+=.@-]{1,512}-[A-Za-z0-9]{6}$", var.signing_key_secret_arn))
    error_message = "signing_key_secret_arn must be a complete wildcard-free Secrets Manager ARN when enabled."
  }
}

variable "signing_key_secret_version_id" {
  description = "Immutable Secrets Manager VersionId of the receipt-signing key."
  type        = string
  default     = ""

  validation {
    condition = !var.enabled || (
      length(var.signing_key_secret_version_id) >= 32 &&
      length(var.signing_key_secret_version_id) <= 64 &&
      can(regex("^[A-Za-z0-9-]+$", var.signing_key_secret_version_id))
    )
    error_message = "signing_key_secret_version_id must be a 32-64 character version identifier when enabled."
  }
}

variable "signing_key_kms_key_arn" {
  description = "Customer-managed KMS key encrypting the receipt-signing secret."
  type        = string
  default     = ""

  validation {
    condition     = !var.enabled || can(regex("^arn:(aws|aws-cn|aws-us-gov):kms:[a-z0-9-]+:[0-9]{12}:key/[0-9A-Fa-f-]{36}$", var.signing_key_kms_key_arn))
    error_message = "signing_key_kms_key_arn must be a complete KMS key ARN when enabled."
  }
}

variable "device_registry_mode" {
  description = "Device registry protocol. V1 is the compatibility default; V2 requires every explicit readiness proof."
  type        = string
  default     = "v1"

  validation {
    condition     = contains(["v1", "v2"], var.device_registry_mode)
    error_message = "device_registry_mode must be v1 or v2."
  }
}

variable "registry_hmac_secret_arn" {
  description = "Complete ARN of the existing Registry V2 HMAC secret shared with operation admission."
  type        = string
  default     = ""

  validation {
    condition     = !var.enabled || var.device_registry_mode != "v2" || can(regex("^arn:(aws|aws-cn|aws-us-gov):secretsmanager:[a-z0-9-]{1,32}:[0-9]{12}:secret:[A-Za-z0-9/_+=.@-]{1,512}-[A-Za-z0-9]{6}$", var.registry_hmac_secret_arn))
    error_message = "registry_hmac_secret_arn must be a complete wildcard-free Secrets Manager ARN in Registry V2."
  }
}

variable "registry_hmac_secret_version_id" {
  description = "Immutable VersionId of the Registry V2 HMAC secret; rotation is a stop-the-world namespace migration."
  type        = string
  default     = ""

  validation {
    condition = !var.enabled || var.device_registry_mode != "v2" || (
      length(var.registry_hmac_secret_version_id) >= 32 &&
      length(var.registry_hmac_secret_version_id) <= 64 &&
      can(regex("^[A-Za-z0-9-]+$", var.registry_hmac_secret_version_id))
    )
    error_message = "registry_hmac_secret_version_id must be a 32-64 character version identifier in Registry V2."
  }
}

variable "registry_hmac_kms_key_arn" {
  description = "Customer-managed KMS key encrypting the Registry V2 HMAC secret."
  type        = string
  default     = ""

  validation {
    condition     = !var.enabled || var.device_registry_mode != "v2" || can(regex("^arn:(aws|aws-cn|aws-us-gov):kms:[a-z0-9-]+:[0-9]{12}:key/[0-9A-Fa-f-]{36}$", var.registry_hmac_kms_key_arn))
    error_message = "registry_hmac_kms_key_arn must be a complete KMS key ARN in Registry V2."
  }
}

variable "device_registry_v1_purged" {
  description = "Operator proof acknowledgement that all historical Registry V1 rows and workers are gone."
  type        = string
  default     = "0"

  validation {
    condition     = contains(["0", "1"], var.device_registry_v1_purged)
    error_message = "device_registry_v1_purged must be exactly 0 or 1."
  }
}

variable "device_registry_client_v2_ready" {
  description = "Operator proof acknowledgement that the intended iOS fleet speaks Registry V2."
  type        = string
  default     = "0"

  validation {
    condition     = contains(["0", "1"], var.device_registry_client_v2_ready)
    error_message = "device_registry_client_v2_ready must be exactly 0 or 1."
  }
}

variable "device_registry_outcome_protocol_ready" {
  description = "Operator proof acknowledgement for the homogeneous terminal-outcome protocol cutover."
  type        = string
  default     = "0"

  validation {
    condition     = contains(["0", "1"], var.device_registry_outcome_protocol_ready)
    error_message = "device_registry_outcome_protocol_ready must be exactly 0 or 1."
  }
}

variable "device_registry_owner_continuity_ready" {
  description = "Operator proof acknowledgement for stable owner continuity and ownerless-row purge."
  type        = string
  default     = "0"

  validation {
    condition     = contains(["0", "1"], var.device_registry_owner_continuity_ready)
    error_message = "device_registry_owner_continuity_ready must be exactly 0 or 1."
  }
}

variable "apns_voip_enabled" {
  description = "Explicit APNs VoIP transport enable. False reads no APNs secret and preserves honest 501 responses."
  type        = bool
  default     = false
}

variable "apns_team_id" {
  description = "Apple Developer Team ID used only when APNs VoIP is enabled."
  type        = string
  default     = ""

  validation {
    condition     = !var.enabled || !var.apns_voip_enabled || can(regex("^[A-Z0-9]{10}$", var.apns_team_id))
    error_message = "apns_team_id must be a ten-character uppercase Apple Team ID when APNs is enabled."
  }
}

variable "apns_key_id" {
  description = "Apple APNs provider-token Key ID used only when APNs VoIP is enabled."
  type        = string
  default     = ""

  validation {
    condition     = !var.enabled || !var.apns_voip_enabled || can(regex("^[A-Z0-9]{10}$", var.apns_key_id))
    error_message = "apns_key_id must be a ten-character uppercase Apple Key ID when APNs is enabled."
  }
}

variable "apns_bundle_id" {
  description = "Exact installed iOS application bundle id; the transport derives the .voip topic."
  type        = string
  default     = ""

  validation {
    condition = !var.enabled || !var.apns_voip_enabled || (
      length(var.apns_bundle_id) >= 3 &&
      length(var.apns_bundle_id) <= 255 &&
      can(regex("^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+$", var.apns_bundle_id))
    )
    error_message = "apns_bundle_id must be a bounded reverse-DNS bundle id when APNs is enabled."
  }
}

variable "apns_voip_environment" {
  description = "APNs push environment. Device tokens are environment-specific."
  type        = string
  default     = "development"

  validation {
    condition     = contains(["development", "production"], var.apns_voip_environment)
    error_message = "apns_voip_environment must be development or production."
  }
}

variable "apns_private_key_secret_arn" {
  description = "Complete ARN of the existing APNs P-256 .p8 secret. No private key enters Terraform."
  type        = string
  default     = ""

  validation {
    condition     = !var.enabled || !var.apns_voip_enabled || can(regex("^arn:(aws|aws-cn|aws-us-gov):secretsmanager:[a-z0-9-]{1,32}:[0-9]{12}:secret:[A-Za-z0-9/_+=.@-]{1,512}-[A-Za-z0-9]{6}$", var.apns_private_key_secret_arn))
    error_message = "apns_private_key_secret_arn must be a complete wildcard-free Secrets Manager ARN when APNs is enabled."
  }
}

variable "apns_private_key_secret_version_id" {
  description = "Immutable VersionId of the APNs .p8 secret."
  type        = string
  default     = ""

  validation {
    condition = !var.enabled || !var.apns_voip_enabled || (
      length(var.apns_private_key_secret_version_id) >= 32 &&
      length(var.apns_private_key_secret_version_id) <= 64 &&
      can(regex("^[A-Za-z0-9-]+$", var.apns_private_key_secret_version_id))
    )
    error_message = "apns_private_key_secret_version_id must be a 32-64 character version identifier when APNs is enabled."
  }
}

variable "apns_private_key_kms_key_arn" {
  description = "Customer-managed KMS key encrypting the APNs .p8 secret."
  type        = string
  default     = ""

  validation {
    condition     = !var.enabled || !var.apns_voip_enabled || can(regex("^arn:(aws|aws-cn|aws-us-gov):kms:[a-z0-9-]+:[0-9]{12}:key/[0-9A-Fa-f-]{36}$", var.apns_private_key_kms_key_arn))
    error_message = "apns_private_key_kms_key_arn must be a complete KMS key ARN when APNs is enabled."
  }
}

variable "table_deletion_protection_enabled" {
  description = "Deletion protection for the durable gateway table. Production requires true."
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days."
  type        = number
  default     = 30

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be a CloudWatch-supported retention value."
  }
}

variable "alarm_topic_arns" {
  description = "SNS topics receiving gateway, APNs, and data-plane alarms. Production requires at least one."
  type        = set(string)
  default     = []

  validation {
    condition = alltrue([
      for arn in var.alarm_topic_arns : can(regex(
        "^arn:(aws|aws-cn|aws-us-gov):sns:[a-z0-9-]+:[0-9]{12}:[A-Za-z0-9_-]{1,256}$",
        arn,
      ))
    ])
    error_message = "Every alarm topic must be a complete SNS topic ARN."
  }
}
