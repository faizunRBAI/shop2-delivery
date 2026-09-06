terraform {
  required_version = ">= 1.9.0"

  # Backend is intentionally EMPTY: bucket/key/region arrive via -backend-config
  # flags from the pipeline (platform terraform state contract).
  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "udap"
      Stack     = "gitops-delivery-platform"
    }
  }
}
