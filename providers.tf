terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.82.2"
    }
  }
}

provider "aws" {
  region                   = var.aws_region
  shared_credentials_files = var.shared_credentials_file
  profile                  = var.profile
}

