terraform {
  required_version = ">= 1.3"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }

  backend "s3" {
    bucket  = "oidcstate79874132464"
    key     = "terraform.tfstate"
    region  = "eu-north-1"
    encrypt = true
  }
}

provider "aws" {
  region = var.aws_region
}

provider "aws" {
  alias  = "main"
  region = var.main_aws_region

  # S3 HeadObject returns 301 if the client uses the global/legacy endpoint while the
  # bucket lives in this region (common when CI sets AWS_REGION to another region).
  endpoints {
    s3 = "https://s3.${var.main_aws_region}.amazonaws.com"
  }
}

provider "aws" {
  alias  = "us-east-1"
  region = "us-east-1"
}

provider "aws" {
  alias  = "secondary"
  region = var.dr_secondary_region
}