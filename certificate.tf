# ============================================================
# CloudPulse Infrastructure — ACM Certificates
# ============================================================
# This file contains ACM certificates for all versions.
# Deploy this first to issue certificates before CloudFront distributions.
# ============================================================

# Provider for us-east-1 (required for CloudFront certificates)
provider "aws" {
  alias  = "us-east-1"
  region = "us-east-1"
}

# ============================================================
# ACM Certificates
# ============================================================

resource "aws_acm_certificate" "transit" {
  provider = aws.us-east-1

  domain_name       = "transit.derherzen.com"
  validation_method = "DNS"
  tags              = { Name = "cloudpulse-transit-cert" }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_acm_certificate" "high" {
  provider = aws.us-east-1

  domain_name       = "high.derherzen.com"
  validation_method = "DNS"
  tags              = { Name = "cloudpulse-high-cert" }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_acm_certificate" "disaster" {
  provider = aws.us-east-1

  domain_name       = "disaster.derherzen.com"
  validation_method = "DNS"
  tags              = { Name = "cloudpulse-disaster-cert" }

  lifecycle {
    prevent_destroy = true
  }
}


# ============================================================
# Outputs
# ============================================================

output "transit_validation_records" {
  description = "DNS validation records for transit.derherzen.com"
  value       = aws_acm_certificate.transit.domain_validation_options
}

output "high_validation_records" {
  description = "DNS validation records for high.derherzen.com"
  value       = aws_acm_certificate.high.domain_validation_options
}

output "disaster_validation_records" {
  description = "DNS validation records for disaster.derherzen.com"
  value       = aws_acm_certificate.disaster.domain_validation_options
}

