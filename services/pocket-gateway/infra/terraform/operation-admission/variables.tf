variable "enabled" {
  description = "Explicit provisioning switch. False creates no resources; true creates the dark-capable admission stack without publishing traffic by itself."
  type        = bool
  default     = false
}

variable "traffic_enabled" {
  description = "Explicit custom-domain mapping switch. It may be true only after the stack is provisioned and dark proofs pass; false preserves resources during rollback."
  type        = bool
  default     = false

  validation {
    condition     = !var.traffic_enabled || var.enabled
    error_message = "traffic_enabled requires enabled=true."
  }
}

variable "publish_dns" {
  description = "Explicit Route 53 publication switch. It may be true only after the custom-domain mapping is enabled and live proof is retained."
  type        = bool
  default     = false

  validation {
    condition     = !var.publish_dns || (var.enabled && var.traffic_enabled)
    error_message = "publish_dns requires enabled=true and traffic_enabled=true."
  }
}

variable "dark_proof_sha256" {
  description = "Canonical lowercase hexadecimal SHA-256 of the retained provisioned-dark evidence bundle. Required before traffic mapping."
  type        = string
  default     = ""

  validation {
    condition     = var.dark_proof_sha256 == "" || can(regex("^[0-9a-f]{64}$", var.dark_proof_sha256))
    error_message = "dark_proof_sha256 must be empty or a canonical lowercase 64-character hexadecimal SHA-256."
  }
}

variable "mapped_proof_sha256" {
  description = "Canonical lowercase hexadecimal SHA-256 of the retained mapped-no-DNS evidence bundle. Required before DNS publication."
  type        = string
  default     = ""

  validation {
    condition     = var.mapped_proof_sha256 == "" || can(regex("^[0-9a-f]{64}$", var.mapped_proof_sha256))
    error_message = "mapped_proof_sha256 must be empty or a canonical lowercase 64-character hexadecimal SHA-256."
  }
}

variable "aws_partition" {
  description = "AWS partition containing every resource in this stack."
  type        = string
  default     = "aws"

  validation {
    condition     = contains(["aws", "aws-cn", "aws-us-gov"], var.aws_partition)
    error_message = "aws_partition must be aws, aws-cn, or aws-us-gov."
  }
}

variable "aws_region" {
  description = "AWS region for the API, Lambdas, table, key, and certificate."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]{2}(?:-gov)?-[a-z]+-[0-9]+$", var.aws_region))
    error_message = "aws_region must be a valid AWS region identifier."
  }
}

variable "aws_account_id" {
  description = "Twelve-digit AWS account id. Required only when enabled."
  type        = string
  default     = ""

  validation {
    condition     = !var.enabled || can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id must contain twelve digits when enabled."
  }
}

variable "name_prefix" {
  description = "Lowercase prefix used for named resources."
  type        = string
  default     = "senti-pocket"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,23}$", var.name_prefix))
    error_message = "name_prefix must be 2-24 lowercase letters, digits, or hyphens and start alphanumeric."
  }
}

variable "environment" {
  description = "Lowercase deployment environment name."
  type        = string
  default     = "prod"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,15}$", var.environment))
    error_message = "environment must be 1-16 lowercase letters, digits, or hyphens and start alphanumeric."
  }
}

variable "api_domain_name" {
  description = "Dedicated public hostname for the HTTP API. Required only when enabled."
  type        = string
  default     = ""

  validation {
    condition     = !var.enabled || can(regex("^[A-Za-z0-9](?:[A-Za-z0-9.-]{1,251}[A-Za-z0-9])?$", var.api_domain_name))
    error_message = "api_domain_name must be a DNS hostname when enabled."
  }
}

variable "api_certificate_arn" {
  description = "Regional ACM certificate ARN for api_domain_name. Required only when enabled."
  type        = string
  default     = ""

  validation {
    condition     = !var.enabled || can(regex("^arn:(aws|aws-cn|aws-us-gov):acm:[a-z0-9-]+:[0-9]{12}:certificate/[0-9a-f-]+$", var.api_certificate_arn))
    error_message = "api_certificate_arn must be an ACM certificate ARN when enabled."
  }
}

variable "route53_zone_id" {
  description = "Route 53 public hosted-zone id for api_domain_name. Required only when publish_dns is true."
  type        = string
  default     = ""

  validation {
    condition     = !var.publish_dns || can(regex("^Z[A-Z0-9]+$", var.route53_zone_id))
    error_message = "route53_zone_id must be a Route 53 hosted-zone id when publish_dns is true."
  }
}

variable "api_stage_name" {
  description = "Named API stage. The $default stage is deliberately prohibited."
  type        = string
  default     = "live"

  validation {
    condition     = var.api_stage_name != "$default" && can(regex("^[A-Za-z0-9_-]{1,64}$", var.api_stage_name))
    error_message = "api_stage_name must be a named 1-64 character stage and cannot be $default."
  }
}

variable "gateway_lambda_function_name" {
  description = "Existing gateway Lambda function name containing the attested published version."
  type        = string
  default     = ""

  validation {
    condition     = !var.enabled || can(regex("^[A-Za-z0-9_-]{1,64}$", var.gateway_lambda_function_name))
    error_message = "gateway_lambda_function_name must be a valid Lambda function name when enabled."
  }
}

variable "gateway_lambda_version" {
  description = "Exact existing published numeric gateway version. $LATEST and aliases are prohibited."
  type        = string
  default     = ""

  validation {
    condition     = !var.enabled || can(regex("^[1-9][0-9]*$", var.gateway_lambda_version))
    error_message = "gateway_lambda_version must be a positive published numeric Lambda version when enabled."
  }
}

variable "gateway_release_artifact_sha256" {
  description = "Canonical base64 SHA-256 from independently verified release evidence for the exact published gateway artifact. Runtime attestation does not self-claim control-plane provenance."
  type        = string
  default     = ""

  validation {
    condition     = !var.enabled || can(regex("^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$", var.gateway_release_artifact_sha256))
    error_message = "gateway_release_artifact_sha256 must be a canonical 44-character base64 SHA-256 when enabled."
  }
}

variable "registry_hmac_secret_arn" {
  description = "ARN of the existing immutable Registry V2 HMAC secret shared with the gateway. No secret value enters Terraform."
  type        = string
  default     = ""

  validation {
    condition     = !var.enabled || can(regex("^arn:(aws|aws-cn|aws-us-gov):secretsmanager:[a-z0-9-]{1,32}:[0-9]{12}:secret:[A-Za-z0-9/_+=.@-]{1,512}-[A-Za-z0-9]{6}$", var.registry_hmac_secret_arn))
    error_message = "registry_hmac_secret_arn must be a complete wildcard-free Secrets Manager secret ARN when enabled."
  }
}

variable "registry_hmac_kms_key_arn" {
  description = "ARN of the KMS key encrypting the Registry V2 HMAC secret."
  type        = string
  default     = ""

  validation {
    condition     = !var.enabled || can(regex("^arn:(aws|aws-cn|aws-us-gov):kms:[a-z0-9-]+:[0-9]{12}:key/[0-9a-f-]+$", var.registry_hmac_kms_key_arn))
    error_message = "registry_hmac_kms_key_arn must be a KMS key ARN when enabled."
  }
}

variable "registry_hmac_secret_version_id" {
  description = "Immutable Secrets Manager version id read by admission. Changing it is a stop-the-world namespace migration, never a rolling deploy."
  type        = string
  default     = ""

  validation {
    condition = !var.enabled || (
      length(var.registry_hmac_secret_version_id) >= 32 &&
      length(var.registry_hmac_secret_version_id) <= 64 &&
      can(regex("^[A-Za-z0-9-]+$", var.registry_hmac_secret_version_id))
    )
    error_message = "registry_hmac_secret_version_id must be a 32-64 character Secrets Manager version id when enabled."
  }
}

variable "gateway_registry_hmac_secret_version_id" {
  description = "Pinned HMAC version id exported by the qualified gateway deployment. It must equal the admission pin at cutover."
  type        = string
  default     = ""

  validation {
    condition = !var.enabled || (
      length(var.gateway_registry_hmac_secret_version_id) >= 32 &&
      length(var.gateway_registry_hmac_secret_version_id) <= 64 &&
      can(regex("^[A-Za-z0-9-]+$", var.gateway_registry_hmac_secret_version_id))
    )
    error_message = "gateway_registry_hmac_secret_version_id must be the gateway deployment's 32-64 character pin when enabled."
  }
}

variable "gateway_registry_hmac_secret_arn" {
  description = "Exact Registry HMAC secret ARN attested by the qualified gateway deployment. It must equal the admission secret ARN at cutover."
  type        = string
  default     = ""

  validation {
    condition     = !var.enabled || can(regex("^arn:(aws|aws-cn|aws-us-gov):secretsmanager:[a-z0-9-]{1,32}:[0-9]{12}:secret:[A-Za-z0-9/_+=.@-]{1,512}-[A-Za-z0-9]{6}$", var.gateway_registry_hmac_secret_arn))
    error_message = "gateway_registry_hmac_secret_arn must be the gateway deployment's complete wildcard-free Secrets Manager secret ARN when enabled."
  }
}

variable "senti_api_base_url" {
  description = "HTTPS Senti API origin used to resolve verifier-owned principal and human identity."
  type        = string
  default     = ""

  validation {
    condition = !var.enabled || can(regex(
      "^https://[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?(?::[0-9]{1,5})?/?$",
      var.senti_api_base_url,
    ))
    error_message = "senti_api_base_url must be an HTTPS origin without credentials, query, fragment, or path when enabled."
  }
}

variable "admission_package_s3_bucket" {
  description = "S3 bucket holding the admission Lambda artifact. Required only when enabled."
  type        = string
  default     = ""

  validation {
    condition     = !var.enabled || length(trimspace(var.admission_package_s3_bucket)) > 0
    error_message = "admission_package_s3_bucket is required when enabled."
  }
}

variable "admission_package_s3_key" {
  description = "S3 key holding the admission Lambda artifact. Required only when enabled."
  type        = string
  default     = ""

  validation {
    condition     = !var.enabled || length(trimspace(var.admission_package_s3_key)) > 0
    error_message = "admission_package_s3_key is required when enabled."
  }
}

variable "admission_package_s3_object_version" {
  description = "Immutable S3 object version for the admission artifact. Required only when enabled."
  type        = string
  default     = ""

  validation {
    condition = !var.enabled || (
      length(var.admission_package_s3_object_version) > 0 &&
      length(var.admission_package_s3_object_version) <= 1024 &&
      trimspace(var.admission_package_s3_object_version) == var.admission_package_s3_object_version &&
      lower(var.admission_package_s3_object_version) != "null"
    )
    error_message = "admission_package_s3_object_version must be a non-null, bounded immutable S3 VersionId when enabled."
  }
}

variable "admission_package_sha256" {
  description = "Expected canonical base64 SHA-256 of the exact admission deployment ZIP."
  type        = string
  default     = ""

  validation {
    condition     = !var.enabled || can(regex("^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$", var.admission_package_sha256))
    error_message = "admission_package_sha256 must be a canonical 44-character base64 SHA-256 when enabled."
  }
}

variable "admission_handler" {
  description = "Exported admission Lambda handler."
  type        = string
  default     = "index.handler"

  validation {
    condition     = can(regex("^[A-Za-z0-9_./-]+\\.[A-Za-z0-9_$-]+$", var.admission_handler))
    error_message = "admission_handler must use the module.export form."
  }
}

variable "admission_architecture" {
  description = "Lambda instruction-set architecture."
  type        = string
  default     = "arm64"

  validation {
    condition     = contains(["arm64", "x86_64"], var.admission_architecture)
    error_message = "admission_architecture must be arm64 or x86_64."
  }
}

variable "admission_memory_mb" {
  description = "Admission Lambda memory allocation."
  type        = number
  default     = 512

  validation {
    condition     = floor(var.admission_memory_mb) == var.admission_memory_mb && var.admission_memory_mb >= 128 && var.admission_memory_mb <= 10240
    error_message = "admission_memory_mb must be an integer from 128 through 10240."
  }
}

variable "admission_timeout_seconds" {
  description = "Admission Lambda timeout, bounded below the HTTP API integration timeout."
  type        = number
  default     = 28

  validation {
    condition     = floor(var.admission_timeout_seconds) == var.admission_timeout_seconds && var.admission_timeout_seconds >= 1 && var.admission_timeout_seconds <= 28
    error_message = "admission_timeout_seconds must be an integer from 1 through 28."
  }
}

variable "admission_reserved_concurrency" {
  description = "Hard concurrency ceiling for the admission Lambda."
  type        = number
  default     = 20

  validation {
    condition     = floor(var.admission_reserved_concurrency) == var.admission_reserved_concurrency && var.admission_reserved_concurrency >= 1 && var.admission_reserved_concurrency <= 1000
    error_message = "admission_reserved_concurrency must be an integer from 1 through 1000."
  }
}

variable "admission_layers" {
  description = "Optional immutable Lambda layer-version ARNs."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for arn in var.admission_layers : can(regex("^arn:(aws|aws-cn|aws-us-gov):lambda:[a-z0-9-]+:[0-9]{12}:layer:[A-Za-z0-9_-]+:[1-9][0-9]*$", arn))
    ])
    error_message = "Every admission_layers entry must be a qualified Lambda layer-version ARN."
  }
}

variable "admission_signing_profile_name" {
  description = "Existing active AWS Signer profile trusted as the sole publisher for enabled production admission artifacts."
  type        = string
  default     = ""

  validation {
    condition = (
      var.admission_signing_profile_name == "" && !(var.enabled && var.environment == "prod")
    ) || can(regex("^[A-Za-z0-9_]{2,64}$", var.admission_signing_profile_name))
    error_message = "admission_signing_profile_name must be a 2-64 character AWS Signer profile name and is required for enabled production."
  }
}

variable "iam_permissions_boundary_arn" {
  description = "Optional IAM permissions-boundary policy ARN for the admission execution role."
  type        = string
  default     = ""

  validation {
    condition     = var.iam_permissions_boundary_arn == "" || can(regex("^arn:(aws|aws-cn|aws-us-gov):iam::[0-9]{12}:policy/.+$", var.iam_permissions_boundary_arn))
    error_message = "iam_permissions_boundary_arn must be empty or an IAM policy ARN."
  }
}

variable "api_throttling_rate_limit" {
  description = "Aggregate API-stage steady-state request rate backstop. Per-principal admission remains authoritative."
  type        = number
  default     = 50

  validation {
    condition     = var.api_throttling_rate_limit > 0
    error_message = "api_throttling_rate_limit must be positive."
  }
}

variable "api_throttling_burst_limit" {
  description = "Aggregate API-stage burst backstop."
  type        = number
  default     = 100

  validation {
    condition     = floor(var.api_throttling_burst_limit) == var.api_throttling_burst_limit && var.api_throttling_burst_limit > 0
    error_message = "api_throttling_burst_limit must be a positive integer."
  }
}

variable "protected_route_throttling_rate_limit" {
  description = "Steady-state requests per second allowed independently on each protected registration route."
  type        = number
  default     = 10

  validation {
    condition     = var.protected_route_throttling_rate_limit > 0
    error_message = "protected_route_throttling_rate_limit must be positive."
  }
}

variable "protected_route_throttling_burst_limit" {
  description = "Bounded burst allowed independently on each protected registration route."
  type        = number
  default     = 20

  validation {
    condition     = floor(var.protected_route_throttling_burst_limit) == var.protected_route_throttling_burst_limit && var.protected_route_throttling_burst_limit > 0
    error_message = "protected_route_throttling_burst_limit must be a positive integer."
  }
}

variable "log_retention_days" {
  description = "Retention period for encrypted API access and Lambda logs."
  type        = number
  default     = 365

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be a CloudWatch Logs supported retention period."
  }
}

variable "table_deletion_protection_enabled" {
  description = "Enable DynamoDB deletion protection. Keep true in production."
  type        = bool
  default     = true
}

variable "alarm_topic_arns" {
  description = "Existing SNS topic ARNs receiving alarm and recovery notifications."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for arn in var.alarm_topic_arns : can(regex("^arn:(aws|aws-cn|aws-us-gov):sns:[a-z0-9-]+:[0-9]{12}:[A-Za-z0-9_-]+$", arn))
    ])
    error_message = "Every alarm_topic_arns entry must be an SNS topic ARN."
  }
}

variable "tags" {
  description = "Additional tags applied through provider default tags."
  type        = map(string)
  default     = {}
}
