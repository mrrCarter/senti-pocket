terraform {
  required_version = ">= 1.9.8, < 2.0.0"

  # Production initialization supplies bucket, key, region, kms_key_id, and dynamodb_table. Tests use `init -backend=false`.
  backend "s3" {
    encrypt = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 5.80.0"
    }
  }
}

provider "aws" {
  region              = var.aws_region
  allowed_account_ids = var.enabled ? [var.aws_account_id] : null

  default_tags {
    tags = merge(var.tags, {
      Application = "senti-pocket"
      Component   = "operation-admission"
      Environment = var.environment
      ManagedBy   = "terraform"
    })
  }
}
