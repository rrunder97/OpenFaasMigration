terraform {
  required_version = ">= 1.5.0"

  # Remote state backend configuration is intentionally partial.
  # Provide concrete backend values via backend.hcl (see backend.hcl.example)
  # and run: terraform init -reconfigure -backend-config=backend.hcl
  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
