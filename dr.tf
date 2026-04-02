# # ============================================================
# # CloudPulse — single consolidated stack (instructor / custom domain)
# #
# # For labs without ACM or custom DNS, use dr_no_certs.tf instead — not both.
# #
# # This file replaces the old split scenarios (data_encryption.tf,
# # high_availability.tf). It is active together with main.tf: DR primary uses
# # var.aws_region (default eu-west-2); secondary uses aws.secondary (var.dr_secondary_region).
# #
# # Included in one place:
# #   • Primary VPC (2 public / 2 private AZs), NAT, internal ALB
# #   • Data at rest: SSE-KMS (S3, DynamoDB, EBS), bucket deny unencrypted PUT, MRK + replica key in DR region
# #   • HA-style edge: ASG min 2 in primary, CloudFront VPC origins, WAF, verify header on ALB listener
# #   • Multi-region data: S3 CRR + DynamoDB global replica (same table name in both regions; IAM allows both ARNs)
# #   • DR: full second VPC in aws.secondary (see provider.tf; var.dr_secondary_region),
# #     cold/warm DR ASG, CloudFront origin group failover, SNS + Lambda (same region as SNS) scale-out when primary ASG GroupInServiceInstances = 0; Lambda calls Auto Scaling in aws.secondary
# #
# # Requires: issued ACM cert in us-east-1 for the hostname in data.aws_acm_certificate.disaster (default disaster.derherzen.com).
# # Optional: uncomment certificate.tf to manage that cert via Terraform instead of a data source.
# #
# # Resource names use var.dr_stack_name; Session 3 uses var.main_stack_name (see main.tf).
# # ============================================================

# data "aws_region" "dr_primary" {}

# data "aws_region" "secondary" {
#   provider = aws.secondary
# }

# data "aws_availability_zones" "dr_primary" {
#   state = "available"
# }

# data "aws_availability_zones" "secondary" {
#   provider = aws.secondary
#   state    = "available"
# }

# data "aws_ami" "dr_amazon_linux" {
#   most_recent = true
#   owners      = ["amazon"]
#   filter {
#     name   = "name"
#     values = ["al2023-ami-20*-kernel-*-x86_64"]
#   }
#   filter {
#     name   = "virtualization-type"
#     values = ["hvm"]
#   }
# }

# data "aws_ami" "dr_amazon_linux_secondary" {
#   provider    = aws.secondary
#   most_recent = true
#   owners      = ["amazon"]
#   filter {
#     name   = "name"
#     values = ["al2023-ami-20*-kernel-*-x86_64"]
#   }
#   filter {
#     name   = "virtualization-type"
#     values = ["hvm"]
#   }
# }

# data "aws_acm_certificate" "disaster" {
#   provider = aws.us-east-1
#   domain   = "disaster.derherzen.com"
#   statuses = ["ISSUED"]
# }

# data "aws_ec2_managed_prefix_list" "cloudfront_origin" {
#   name = "com.amazonaws.global.cloudfront.origin-facing"
# }

# # Prefix list IDs are per-region; DR ALB SG must use the list ID from aws.secondary.
# data "aws_ec2_managed_prefix_list" "cloudfront_origin_secondary" {
#   provider = aws.secondary
#   name     = "com.amazonaws.global.cloudfront.origin-facing"
# }

# resource "random_password" "cloudfront_origin_secret" {
#   length  = 48
#   special = false
# }


# locals {
#   dr_kms_policy = jsonencode({
#     Version = "2012-10-17"
#     Statement = [
#       {
#         Sid       = "Enable IAM User Permissions"
#         Effect    = "Allow"
#         Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
#         Action    = "kms:*"
#         Resource  = "*"
#       },
#       {
#         Sid       = "Allow EC2 and Auto Scaling use of the key"
#         Effect    = "Allow"
#         Principal = { Service = ["ec2.amazonaws.com", "autoscaling.amazonaws.com"] }
#         Action = [
#           "kms:Encrypt",
#           "kms:Decrypt",
#           "kms:ReEncrypt*",
#           "kms:GenerateDataKey",
#           "kms:GenerateDataKeyWithoutPlaintext",
#           "kms:DescribeKey",
#           "kms:CreateGrant"
#         ]
#         Resource = "*"
#       },
#       {
#         Sid       = "Allow AWS Auto Scaling service-linked role use of the key"
#         Effect    = "Allow"
#         Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling" }
#         Action = [
#           "kms:Encrypt",
#           "kms:Decrypt",
#           "kms:ReEncrypt*",
#           "kms:GenerateDataKey",
#           "kms:GenerateDataKeyWithoutPlaintext",
#           "kms:DescribeKey"
#         ]
#         Resource = "*"
#       },
#       {
#         Sid       = "Allow attachment of persistent resources"
#         Effect    = "Allow"
#         Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling" }
#         Action    = "kms:CreateGrant"
#         Resource  = "*"
#         Condition = { Bool = { "kms:GrantIsForAWSResource" = true } }
#       },
#       {
#         Sid       = "Allow S3"
#         Effect    = "Allow"
#         Principal = { Service = "s3.amazonaws.com" }
#         Action = [
#           "kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey", "kms:GenerateDataKeyWithoutPlaintext",
#           "kms:DescribeKey", "kms:ReEncrypt*", "kms:CreateGrant"
#         ]
#         Resource  = "*"
#         Condition = { StringEquals = { "kms:CallerAccount" = data.aws_caller_identity.current.account_id } }
#       },
#       {
#         Sid       = "Allow DynamoDB"
#         Effect    = "Allow"
#         Principal = { Service = "dynamodb.amazonaws.com" }
#         Action = [
#           "kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey", "kms:GenerateDataKeyWithoutPlaintext",
#           "kms:DescribeKey", "kms:ReEncrypt*", "kms:CreateGrant"
#         ]
#         Resource  = "*"
#         Condition = { StringEquals = { "kms:CallerAccount" = data.aws_caller_identity.current.account_id } }
#       },
#       {
#         Sid       = "Allow SNS"
#         Effect    = "Allow"
#         Principal = { Service = "sns.amazonaws.com" }
#         Action    = ["kms:GenerateDataKey", "kms:Decrypt"]
#         Resource  = "*"
#         Condition = { StringEquals = { "kms:ViaService" = "sns.${data.aws_region.dr_primary.name}.amazonaws.com" } }
#       },
#       {
#         Sid       = "Allow CloudWatch alarm actions to encrypted SNS"
#         Effect    = "Allow"
#         Principal = { Service = "cloudwatch.amazonaws.com" }
#         # Omit kms:CallerAccount — CloudWatch alarm→encrypted SNS often fails evaluation with that condition.
#         Action   = ["kms:Decrypt", "kms:GenerateDataKey*", "kms:DescribeKey"]
#         Resource = "*"
#       },
#       {
#         Sid       = "Allow Lambda environment encryption"
#         Effect    = "Allow"
#         Principal = { Service = "lambda.amazonaws.com" }
#         Action = [
#           "kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey", "kms:GenerateDataKeyWithoutPlaintext",
#           "kms:DescribeKey", "kms:CreateGrant", "kms:ReEncrypt*"
#         ]
#         Resource  = "*"
#         Condition = { StringEquals = { "kms:ViaService" = "lambda.${data.aws_region.dr_primary.name}.amazonaws.com" } }
#       }
#     ]
#   })
# }

# resource "aws_kms_key" "dr_kms_mrk" {
#   description             = "CloudPulse MRK primary (shared DR data plane; do not destroy casually)"
#   multi_region            = true
#   policy                  = local.dr_kms_policy
#   deletion_window_in_days = 30
#   tags                    = { Name = "${var.dr_stack_name}-kms" }

#   lifecycle {
#     prevent_destroy = true
#   }
# }

# resource "aws_kms_replica_key" "dr_kms_replica" {
#   provider                = aws.secondary
#   primary_key_arn         = aws_kms_key.dr_kms_mrk.arn
#   description             = "CloudPulse MRK replica for ${data.aws_region.secondary.name}"
#   policy                  = local.dr_kms_policy
#   deletion_window_in_days = 30
#   tags                    = { Name = "${var.dr_stack_name}-kms-secondary" }

#   lifecycle {
#     prevent_destroy = true
#   }
# }


# resource "aws_vpc" "dr_vpc_primary" {
#   cidr_block           = var.vpc_cidr
#   enable_dns_support   = true
#   enable_dns_hostnames = true
#   tags                 = { Name = "${var.dr_stack_name}-vpc" }
# }

# resource "aws_internet_gateway" "dr_primary_igw" {
#   vpc_id = aws_vpc.dr_vpc_primary.id
#   tags   = { Name = "${var.dr_stack_name}-igw" }
# }

# resource "aws_subnet" "dr_primary_public" {
#   vpc_id                  = aws_vpc.dr_vpc_primary.id
#   cidr_block              = cidrsubnet(var.vpc_cidr, 2, 0)
#   availability_zone       = data.aws_availability_zones.dr_primary.names[0]
#   map_public_ip_on_launch = true
#   tags                    = { Name = "${var.dr_stack_name}-public-subnet" }
# }

# resource "aws_subnet" "dr_primary_public2" {
#   vpc_id                  = aws_vpc.dr_vpc_primary.id
#   cidr_block              = cidrsubnet(var.vpc_cidr, 2, 1)
#   availability_zone       = data.aws_availability_zones.dr_primary.names[1]
#   map_public_ip_on_launch = true
#   tags                    = { Name = "${var.dr_stack_name}-public-subnet2" }
# }

# resource "aws_eip" "dr_primary_nat_eip" {
#   domain = "vpc"
#   tags   = { Name = "${var.dr_stack_name}-nat-eip" }
# }

# resource "aws_nat_gateway" "dr_primary_nat_gw" {
#   allocation_id = aws_eip.dr_primary_nat_eip.id
#   subnet_id     = aws_subnet.dr_primary_public.id
#   tags          = { Name = "${var.dr_stack_name}-nat" }
# }

# resource "aws_subnet" "dr_primary_private" {
#   vpc_id            = aws_vpc.dr_vpc_primary.id
#   cidr_block        = cidrsubnet(var.vpc_cidr, 2, 2)
#   availability_zone = data.aws_availability_zones.dr_primary.names[0]
#   tags              = { Name = "${var.dr_stack_name}-private-subnet" }
# }

# resource "aws_subnet" "dr_primary_private2" {
#   vpc_id            = aws_vpc.dr_vpc_primary.id
#   cidr_block        = cidrsubnet(var.vpc_cidr, 2, 3)
#   availability_zone = data.aws_availability_zones.dr_primary.names[1]
#   tags              = { Name = "${var.dr_stack_name}-private-subnet2" }
# }

# resource "aws_route_table" "dr_primary_private_rt" {
#   vpc_id = aws_vpc.dr_vpc_primary.id
#   route {
#     cidr_block     = "0.0.0.0/0"
#     nat_gateway_id = aws_nat_gateway.dr_primary_nat_gw.id
#   }
#   tags = { Name = "${var.dr_stack_name}-private-rt" }
# }

# resource "aws_route_table_association" "dr_primary_rta_priv1" {
#   subnet_id      = aws_subnet.dr_primary_private.id
#   route_table_id = aws_route_table.dr_primary_private_rt.id
# }

# resource "aws_route_table_association" "dr_primary_rta_priv2" {
#   subnet_id      = aws_subnet.dr_primary_private2.id
#   route_table_id = aws_route_table.dr_primary_private_rt.id
# }

# resource "aws_route_table" "dr_primary_public_rt" {
#   vpc_id = aws_vpc.dr_vpc_primary.id
#   route {
#     cidr_block = "0.0.0.0/0"
#     gateway_id = aws_internet_gateway.dr_primary_igw.id
#   }
#   tags = { Name = "${var.dr_stack_name}-public-rt" }
# }

# resource "aws_route_table_association" "dr_primary_rta_pub1" {
#   subnet_id      = aws_subnet.dr_primary_public.id
#   route_table_id = aws_route_table.dr_primary_public_rt.id
# }

# resource "aws_route_table_association" "dr_primary_rta_pub2" {
#   subnet_id      = aws_subnet.dr_primary_public2.id
#   route_table_id = aws_route_table.dr_primary_public_rt.id
# }


# resource "aws_vpc" "dr_vpc_secondary" {
#   provider             = aws.secondary
#   cidr_block           = var.dr_vpc_cidr
#   enable_dns_support   = true
#   enable_dns_hostnames = true
#   tags                 = { Name = "${var.dr_stack_name}-vpc-dr" }
# }

# resource "aws_internet_gateway" "dr_igw_secondary" {
#   provider = aws.secondary
#   vpc_id   = aws_vpc.dr_vpc_secondary.id
#   tags     = { Name = "${var.dr_stack_name}-igw-dr" }
# }

# resource "aws_subnet" "dr_public" {
#   provider                = aws.secondary
#   vpc_id                  = aws_vpc.dr_vpc_secondary.id
#   cidr_block              = cidrsubnet(var.dr_vpc_cidr, 2, 0)
#   availability_zone       = data.aws_availability_zones.secondary.names[0]
#   map_public_ip_on_launch = true
#   tags                    = { Name = "${var.dr_stack_name}-public-dr-a" }
# }

# resource "aws_subnet" "dr_public2" {
#   provider                = aws.secondary
#   vpc_id                  = aws_vpc.dr_vpc_secondary.id
#   cidr_block              = cidrsubnet(var.dr_vpc_cidr, 2, 1)
#   availability_zone       = data.aws_availability_zones.secondary.names[1]
#   map_public_ip_on_launch = true
#   tags                    = { Name = "${var.dr_stack_name}-public-dr-b" }
# }

# resource "aws_eip" "dr_secondary_nat_eip" {
#   provider = aws.secondary
#   domain   = "vpc"
#   tags     = { Name = "${var.dr_stack_name}-nat-eip-dr" }
# }

# resource "aws_nat_gateway" "dr_nat_secondary" {
#   provider      = aws.secondary
#   allocation_id = aws_eip.dr_secondary_nat_eip.id
#   subnet_id     = aws_subnet.dr_public.id
#   tags          = { Name = "${var.dr_stack_name}-nat-dr" }
# }

# resource "aws_subnet" "dr_private" {
#   provider          = aws.secondary
#   vpc_id            = aws_vpc.dr_vpc_secondary.id
#   cidr_block        = cidrsubnet(var.dr_vpc_cidr, 2, 2)
#   availability_zone = data.aws_availability_zones.secondary.names[0]
#   tags              = { Name = "${var.dr_stack_name}-private-dr-a" }
# }

# resource "aws_subnet" "dr_private2" {
#   provider          = aws.secondary
#   vpc_id            = aws_vpc.dr_vpc_secondary.id
#   cidr_block        = cidrsubnet(var.dr_vpc_cidr, 2, 3)
#   availability_zone = data.aws_availability_zones.secondary.names[1]
#   tags              = { Name = "${var.dr_stack_name}-private-dr-b" }
# }

# resource "aws_route_table" "dr_private" {
#   provider = aws.secondary
#   vpc_id   = aws_vpc.dr_vpc_secondary.id
#   route {
#     cidr_block     = "0.0.0.0/0"
#     nat_gateway_id = aws_nat_gateway.dr_nat_secondary.id
#   }
#   tags = { Name = "${var.dr_stack_name}-private-rt-dr" }
# }

# resource "aws_route_table_association" "dr_private" {
#   provider       = aws.secondary
#   subnet_id      = aws_subnet.dr_private.id
#   route_table_id = aws_route_table.dr_private.id
# }

# resource "aws_route_table_association" "dr_private2" {
#   provider       = aws.secondary
#   subnet_id      = aws_subnet.dr_private2.id
#   route_table_id = aws_route_table.dr_private.id
# }

# resource "aws_route_table" "dr_public" {
#   provider = aws.secondary
#   vpc_id   = aws_vpc.dr_vpc_secondary.id
#   route {
#     cidr_block = "0.0.0.0/0"
#     gateway_id = aws_internet_gateway.dr_igw_secondary.id
#   }
#   tags = { Name = "${var.dr_stack_name}-public-rt-dr" }
# }

# resource "aws_route_table_association" "dr_public" {
#   provider       = aws.secondary
#   subnet_id      = aws_subnet.dr_public.id
#   route_table_id = aws_route_table.dr_public.id
# }

# resource "aws_route_table_association" "dr_public2" {
#   provider       = aws.secondary
#   subnet_id      = aws_subnet.dr_public2.id
#   route_table_id = aws_route_table.dr_public.id
# }


# resource "aws_security_group" "alb_sg" {
#   name        = "${var.dr_stack_name}-alb-sg"
#   description = "Internal ALB - HTTP from CloudFront (prefix list, VPC Origin)"
#   vpc_id      = aws_vpc.dr_vpc_primary.id

#   ingress {
#     description     = "HTTP from CloudFront"
#     from_port       = 80
#     to_port         = 80
#     protocol        = "tcp"
#     prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront_origin.id]
#   }
#   egress {
#     from_port   = 0
#     to_port     = 0
#     protocol    = "-1"
#     cidr_blocks = ["0.0.0.0/0"]
#   }
#   tags = { Name = "${var.dr_stack_name}-alb-sg" }
# }

# resource "aws_security_group" "dr_primary_app_sg" {
#   name        = "${var.dr_stack_name}-sg"
#   description = "Primary app - from ALB, SSH"
#   vpc_id      = aws_vpc.dr_vpc_primary.id

#   ingress {
#     description = "SSH"
#     from_port   = 22
#     to_port     = 22
#     protocol    = "tcp"
#     cidr_blocks = var.allowed_ssh_cidrs
#   }
#   ingress {
#     description     = "App from ALB"
#     from_port       = 80
#     to_port         = 80
#     protocol        = "tcp"
#     security_groups = [aws_security_group.alb_sg.id]
#   }
#   ingress {
#     description = "Grafana / Apps (lab)"
#     from_port   = 3000
#     to_port     = 3000
#     protocol    = "tcp"
#     cidr_blocks = ["0.0.0.0/0"]
#   }
#   ingress {
#     description = "Internal cluster ports"
#     from_port   = 3000
#     to_port     = 9999
#     protocol    = "tcp"
#     self        = true
#   }
#   egress {
#     from_port   = 0
#     to_port     = 0
#     protocol    = "-1"
#     cidr_blocks = ["0.0.0.0/0"]
#   }
#   tags = { Name = "${var.dr_stack_name}-sg" }
# }

# resource "aws_security_group" "alb_sg_dr" {
#   provider    = aws.secondary
#   name        = "${var.dr_stack_name}-alb-sg-dr"
#   description = "Internal DR ALB - HTTP from CloudFront (prefix list, VPC Origin)"
#   vpc_id      = aws_vpc.dr_vpc_secondary.id

#   ingress {
#     description     = "HTTP from CloudFront"
#     from_port       = 80
#     to_port         = 80
#     protocol        = "tcp"
#     prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront_origin_secondary.id]
#   }
#   egress {
#     from_port   = 0
#     to_port     = 0
#     protocol    = "-1"
#     cidr_blocks = ["0.0.0.0/0"]
#   }
#   tags = { Name = "${var.dr_stack_name}-alb-sg-dr" }
# }

# resource "aws_security_group" "dr_app_sg_secondary" {
#   provider    = aws.secondary
#   name        = "${var.dr_stack_name}-sg-dr"
#   description = "DR app - from ALB, SSH"
#   vpc_id      = aws_vpc.dr_vpc_secondary.id

#   ingress {
#     description = "SSH"
#     from_port   = 22
#     to_port     = 22
#     protocol    = "tcp"
#     cidr_blocks = var.allowed_ssh_cidrs
#   }
#   ingress {
#     description     = "App from ALB"
#     from_port       = 80
#     to_port         = 80
#     protocol        = "tcp"
#     security_groups = [aws_security_group.alb_sg_dr.id]
#   }
#   ingress {
#     description = "Internal cluster ports"
#     from_port   = 3000
#     to_port     = 9999
#     protocol    = "tcp"
#     self        = true
#   }
#   egress {
#     from_port   = 0
#     to_port     = 0
#     protocol    = "-1"
#     cidr_blocks = ["0.0.0.0/0"]
#   }
#   tags = { Name = "${var.dr_stack_name}-sg-dr" }
# }

# resource "aws_iam_role" "s3_replication" {
#   name = "${var.dr_stack_name}-s3-replication-role"
#   assume_role_policy = jsonencode({
#     Version = "2012-10-17"
#     Statement = [{
#       Action    = "sts:AssumeRole"
#       Principal = { Service = "s3.amazonaws.com" }
#       Effect    = "Allow"
#     }]
#   })
# }

# resource "aws_iam_role_policy" "s3_replication" {
#   name = "${var.dr_stack_name}-s3-replication-policy"
#   role = aws_iam_role.s3_replication.id
#   policy = jsonencode({
#     Version = "2012-10-17"
#     Statement = [
#       {
#         Action   = ["s3:GetReplicationConfiguration", "s3:ListBucket"]
#         Effect   = "Allow"
#         Resource = aws_s3_bucket.dr_s3_primary.arn
#       },
#       {
#         Action = [
#           "s3:GetObjectVersion",
#           "s3:GetObjectVersionAcl",
#           "s3:GetObjectVersionTagging"
#         ]
#         Effect   = "Allow"
#         Resource = "${aws_s3_bucket.dr_s3_primary.arn}/*"
#       },
#       {
#         Action   = ["s3:ReplicateObject", "s3:ReplicateDelete", "s3:ReplicateTags"]
#         Effect   = "Allow"
#         Resource = "${aws_s3_bucket.dr_s3_secondary.arn}/*"
#       },
#       {
#         Effect = "Allow"
#         Action = [
#           "kms:Decrypt", "kms:GenerateDataKey", "kms:GenerateDataKeyWithoutPlaintext",
#           "kms:DescribeKey", "kms:Encrypt", "kms:ReEncrypt*"
#         ]
#         Resource = aws_kms_key.dr_kms_mrk.arn
#       },
#       {
#         Effect = "Allow"
#         Action = [
#           "kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey", "kms:GenerateDataKeyWithoutPlaintext",
#           "kms:DescribeKey", "kms:ReEncrypt*"
#         ]
#         Resource = aws_kms_replica_key.dr_kms_replica.arn
#       }
#     ]
#   })
# }

# resource "aws_s3_bucket" "dr_s3_primary" {
#   bucket = "${var.s3_bucket_prefix}-${data.aws_caller_identity.current.account_id}-${data.aws_region.dr_primary.name}"
#   tags   = { Name = "${var.dr_stack_name}-assets" }
# }

# resource "aws_s3_bucket" "dr_s3_secondary" {
#   provider = aws.secondary
#   bucket   = "${var.s3_bucket_prefix}-${data.aws_caller_identity.current.account_id}-${data.aws_region.secondary.name}"
#   tags     = { Name = "${var.dr_stack_name}-assets-secondary" }
# }

# resource "aws_s3_bucket_versioning" "dr_s3_ver_primary" {
#   bucket = aws_s3_bucket.dr_s3_primary.id
#   versioning_configuration { status = "Enabled" }
# }

# resource "aws_s3_bucket_versioning" "dr_s3_ver_secondary" {
#   provider = aws.secondary
#   bucket   = aws_s3_bucket.dr_s3_secondary.id
#   versioning_configuration { status = "Enabled" }
# }

# resource "aws_s3_bucket_replication_configuration" "dr_s3_replication" {
#   role   = aws_iam_role.s3_replication.arn
#   bucket = aws_s3_bucket.dr_s3_primary.id
#   rule {
#     id     = "CRR"
#     status = "Enabled"
#     filter {}
#     delete_marker_replication { status = "Disabled" }

#     # AWS requires this when destination.encryption_configuration is set (KMS → KMS CRR).
#     source_selection_criteria {
#       sse_kms_encrypted_objects {
#         status = "Enabled"
#       }
#     }

#     destination {
#       bucket        = aws_s3_bucket.dr_s3_secondary.arn
#       storage_class = "STANDARD"
#       encryption_configuration {
#         replica_kms_key_id = aws_kms_replica_key.dr_kms_replica.arn
#       }
#     }
#   }
#   depends_on = [
#     aws_s3_bucket_versioning.dr_s3_ver_primary,
#     aws_s3_bucket_versioning.dr_s3_ver_secondary,
#     aws_s3_bucket_server_side_encryption_configuration.dr_s3_sse,
#     aws_s3_bucket_server_side_encryption_configuration.dr_s3_sse_secondary,
#     aws_kms_replica_key.dr_kms_replica,
#   ]
# }

# resource "aws_s3_object" "dr_s3_bg_primary" {
#   bucket                 = aws_s3_bucket.dr_s3_primary.id
#   key                    = var.background_image_key
#   source                 = var.background_image_path
#   content_type           = "image/jpeg"
#   server_side_encryption = "aws:kms"
#   kms_key_id             = aws_kms_key.dr_kms_mrk.arn
#   depends_on             = [aws_s3_bucket_replication_configuration.dr_s3_replication]
# }

# resource "aws_s3_object" "dr_s3_bg_secondary" {
#   provider               = aws.secondary
#   bucket                 = aws_s3_bucket.dr_s3_secondary.id
#   key                    = var.background_image_key
#   source                 = var.background_image_path
#   content_type           = "image/jpeg"
#   server_side_encryption = "aws:kms"
#   kms_key_id             = aws_kms_replica_key.dr_kms_replica.arn
#   depends_on = [
#     aws_s3_bucket_versioning.dr_s3_ver_secondary,
#     aws_kms_replica_key.dr_kms_replica,
#     aws_s3_object.dr_s3_bg_primary,
#   ]
# }

# resource "aws_s3_bucket_server_side_encryption_configuration" "dr_s3_sse" {
#   bucket = aws_s3_bucket.dr_s3_primary.id
#   rule {
#     apply_server_side_encryption_by_default {
#       sse_algorithm     = "aws:kms"
#       kms_master_key_id = aws_kms_key.dr_kms_mrk.arn
#     }
#     bucket_key_enabled = true
#   }
# }

# resource "aws_s3_bucket_policy" "dr_s3_policy_encrypt" {
#   bucket = aws_s3_bucket.dr_s3_primary.id
#   policy = jsonencode({
#     Version = "2012-10-17"
#     Statement = [{
#       Sid       = "DenyUnencryptedObjectUploads"
#       Effect    = "Deny"
#       Principal = "*"
#       Action    = "s3:PutObject"
#       Resource  = "${aws_s3_bucket.dr_s3_primary.arn}/*"
#       Condition = {
#         StringNotEquals = { "s3:x-amz-server-side-encryption" = "aws:kms" }
#       }
#     }]
#   })
# }

# resource "aws_s3_bucket_server_side_encryption_configuration" "dr_s3_sse_secondary" {
#   provider = aws.secondary
#   bucket   = aws_s3_bucket.dr_s3_secondary.id
#   rule {
#     apply_server_side_encryption_by_default {
#       sse_algorithm     = "aws:kms"
#       kms_master_key_id = aws_kms_replica_key.dr_kms_replica.arn
#     }
#     bucket_key_enabled = true
#   }
#   depends_on = [aws_kms_replica_key.dr_kms_replica]
# }

# resource "aws_s3_bucket_policy" "dr_s3_policy_encrypt_secondary" {
#   provider = aws.secondary
#   bucket   = aws_s3_bucket.dr_s3_secondary.id
#   policy = jsonencode({
#     Version = "2012-10-17"
#     Statement = [{
#       Sid       = "DenyUnencryptedObjectUploads"
#       Effect    = "Deny"
#       Principal = "*"
#       Action    = "s3:PutObject"
#       Resource  = "${aws_s3_bucket.dr_s3_secondary.arn}/*"
#       Condition = {
#         StringNotEquals = { "s3:x-amz-server-side-encryption" = "aws:kms" }
#       }
#     }]
#   })
#   depends_on = [aws_s3_bucket_server_side_encryption_configuration.dr_s3_sse_secondary]
# }

# resource "aws_dynamodb_table" "dr_dynamodb" {
#   name             = var.dynamodb_table_name
#   billing_mode     = "PAY_PER_REQUEST"
#   hash_key         = "id"
#   stream_enabled   = true
#   stream_view_type = "NEW_AND_OLD_IMAGES"

#   attribute {
#     name = "id"
#     type = "S"
#   }

#   server_side_encryption {
#     enabled     = true
#     kms_key_arn = aws_kms_key.dr_kms_mrk.arn
#   }

#   replica {
#     region_name = data.aws_region.secondary.name
#     kms_key_arn = aws_kms_replica_key.dr_kms_replica.arn
#   }

#   tags = { Name = "${var.dr_stack_name}-counter" }
# }

# resource "aws_dynamodb_table_item" "dr_ddb_visits" {
#   table_name = aws_dynamodb_table.dr_dynamodb.name
#   hash_key   = aws_dynamodb_table.dr_dynamodb.hash_key
#   item       = <<ITEM
# {
#   "id": {"S": "visits"},
#   "count": {"N": "0"}
# }
# ITEM
#   lifecycle {
#     ignore_changes = [item]
#   }
# }

# resource "aws_iam_role" "dr_iam_ec2" {
#   name = "${var.dr_stack_name}-instance-role"
#   assume_role_policy = jsonencode({
#     Version = "2012-10-17"
#     Statement = [{
#       Action    = "sts:AssumeRole"
#       Effect    = "Allow"
#       Principal = { Service = "ec2.amazonaws.com" }
#     }]
#   })
# }

# resource "aws_iam_role_policy" "dr_iam_ec2_policy" {
#   name = "${var.dr_stack_name}-access-policy"
#   role = aws_iam_role.dr_iam_ec2.id
#   policy = jsonencode({
#     Version = "2012-10-17"
#     Statement = [
#       {
#         Effect = "Allow"
#         Action = ["s3:GetObject", "s3:ListBucket"]
#         Resource = [
#           aws_s3_bucket.dr_s3_primary.arn,
#           "${aws_s3_bucket.dr_s3_primary.arn}/*",
#           aws_s3_bucket.dr_s3_secondary.arn,
#           "${aws_s3_bucket.dr_s3_secondary.arn}/*",
#         ]
#       },
#       {
#         Effect = "Allow"
#         Action = ["dynamodb:GetItem", "dynamodb:UpdateItem", "dynamodb:PutItem"]
#         Resource = [
#           aws_dynamodb_table.dr_dynamodb.arn,
#           "arn:aws:dynamodb:${data.aws_region.secondary.name}:${data.aws_caller_identity.current.account_id}:table/${var.dynamodb_table_name}",
#         ]
#       },
#       {
#         Effect = "Allow"
#         Action = [
#           "kms:Decrypt", "kms:DescribeKey", "kms:GenerateDataKey",
#           "kms:GenerateDataKeyWithoutPlaintext", "kms:CreateGrant", "kms:ReEncrypt*"
#         ]
#         Resource = [
#           aws_kms_key.dr_kms_mrk.arn,
#           aws_kms_replica_key.dr_kms_replica.arn
#         ]
#       }
#     ]
#   })
# }

# resource "aws_iam_instance_profile" "dr_iam_profile" {
#   name = "${var.dr_stack_name}-instance-profile"
#   role = aws_iam_role.dr_iam_ec2.name
# }

# resource "aws_launch_template" "dr_lt_primary" {
#   name_prefix   = "${var.dr_stack_name}-lt-"
#   image_id      = data.aws_ami.dr_amazon_linux.id
#   instance_type = var.instance_type

#   vpc_security_group_ids = [aws_security_group.dr_primary_app_sg.id]
#   iam_instance_profile { name = aws_iam_instance_profile.dr_iam_profile.name }

#   block_device_mappings {
#     device_name = "/dev/xvda"
#     ebs {
#       encrypted   = true
#       kms_key_id  = aws_kms_key.dr_kms_mrk.arn
#       volume_type = "gp3"
#       volume_size = 8
#     }
#   }

#   user_data = base64encode(<<-EOF
#     #!/bin/bash
#     exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1
#     yum update -y
#     yum install -y python3-pip unzip
#     pip3 install flask requests boto3 pytz prometheus-flask-exporter
#     mkdir -p /home/ec2-user/app
#     cat << 'PY_EOF' > /home/ec2-user/app/app.py
#     ${templatefile("${path.module}/app.py.tftpl", {
#     bucket_name = aws_s3_bucket.dr_s3_primary.bucket,
#     table_name  = var.dynamodb_table_name,
#     aws_region  = data.aws_region.dr_primary.name,
#     image_key   = var.background_image_key
# })}
#     PY_EOF
#     cat <<SVC_EOF > /etc/systemd/system/cloudpulse.service
#     [Unit]
#     Description=CloudPulse Flask App
#     After=network.target
#     [Service]
#     User=root
#     WorkingDirectory=/home/ec2-user/app
#     ExecStart=/usr/bin/python3 /home/ec2-user/app/app.py
#     StandardOutput=append:/home/ec2-user/app/app.log
#     StandardError=append:/home/ec2-user/app/app.log
#     Restart=always
#     [Install]
#     WantedBy=multi-user.target
#     SVC_EOF
#     systemctl daemon-reload
#     systemctl enable cloudpulse
#     systemctl start cloudpulse
#     wget -q https://github.com/prometheus/node_exporter/releases/download/v1.7.0/node_exporter-1.7.0.linux-amd64.tar.gz
#     tar xfz node_exporter-1.7.0.linux-amd64.tar.gz
#     cp node_exporter-1.7.0.linux-amd64/node_exporter /usr/local/bin/
#     cat <<NODE_EOF > /etc/systemd/system/node_exporter.service
#     [Unit]
#     Description=Node Exporter
#     After=network.target
#     [Service]
#     User=ec2-user
#     ExecStart=/usr/local/bin/node_exporter
#     [Install]
#     WantedBy=multi-user.target
#     NODE_EOF
#     systemctl enable node_exporter
#     systemctl start node_exporter
#   EOF
# )

# tag_specifications {
#   resource_type = "instance"
#   tags          = { Name = "${var.dr_stack_name}-server" }
# }
# }

# resource "aws_launch_template" "dr_lt_secondary" {
#   provider      = aws.secondary
#   name_prefix   = "${var.dr_stack_name}-lt-dr-"
#   image_id      = data.aws_ami.dr_amazon_linux_secondary.id
#   instance_type = var.instance_type

#   vpc_security_group_ids = [aws_security_group.dr_app_sg_secondary.id]
#   iam_instance_profile { name = aws_iam_instance_profile.dr_iam_profile.name }

#   block_device_mappings {
#     device_name = "/dev/xvda"
#     ebs {
#       encrypted   = true
#       kms_key_id  = aws_kms_replica_key.dr_kms_replica.arn
#       volume_type = "gp3"
#       volume_size = 8
#     }
#   }

#   user_data = base64encode(<<-EOF
#     #!/bin/bash
#     exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1
#     yum update -y
#     yum install -y python3-pip unzip
#     pip3 install flask requests boto3 pytz prometheus-flask-exporter
#     mkdir -p /home/ec2-user/app
#     cat << 'PY_EOF' > /home/ec2-user/app/app.py
#     ${templatefile("${path.module}/app.py.tftpl", {
#     bucket_name = aws_s3_bucket.dr_s3_secondary.bucket,
#     table_name  = var.dynamodb_table_name,
#     aws_region  = data.aws_region.secondary.name,
#     image_key   = var.background_image_key
# })}
#     PY_EOF
#     cat <<SVC_EOF > /etc/systemd/system/cloudpulse.service
#     [Unit]
#     Description=CloudPulse Flask App
#     After=network.target
#     [Service]
#     User=root
#     WorkingDirectory=/home/ec2-user/app
#     ExecStart=/usr/bin/python3 /home/ec2-user/app/app.py
#     StandardOutput=append:/home/ec2-user/app/app.log
#     StandardError=append:/home/ec2-user/app/app.log
#     Restart=always
#     [Install]
#     WantedBy=multi-user.target
#     SVC_EOF
#     systemctl daemon-reload
#     systemctl enable cloudpulse
#     systemctl start cloudpulse
#     wget -q https://github.com/prometheus/node_exporter/releases/download/v1.7.0/node_exporter-1.7.0.linux-amd64.tar.gz
#     tar xfz node_exporter-1.7.0.linux-amd64.tar.gz
#     cp node_exporter-1.7.0.linux-amd64/node_exporter /usr/local/bin/
#     cat <<NODE_EOF > /etc/systemd/system/node_exporter.service
#     [Unit]
#     Description=Node Exporter
#     After=network.target
#     [Service]
#     User=ec2-user
#     ExecStart=/usr/local/bin/node_exporter
#     [Install]
#     WantedBy=multi-user.target
#     NODE_EOF
#     systemctl enable node_exporter
#     systemctl start node_exporter
#   EOF
# )

# tag_specifications {
#   resource_type = "instance"
#   tags          = { Name = "${var.dr_stack_name}-server-dr" }
# }
# }

# resource "aws_lb_target_group" "dr_tg_primary" {
#   name_prefix = "drp-"
#   port        = 80
#   protocol    = "HTTP"
#   vpc_id      = aws_vpc.dr_vpc_primary.id
#   lifecycle { create_before_destroy = true }
#   health_check {
#     path                = "/"
#     interval            = 5
#     timeout             = 4
#     healthy_threshold   = 2
#     unhealthy_threshold = 2
#   }
#   tags = { Name = "${var.dr_stack_name}-tg" }
# }

# resource "aws_lb_target_group" "dr_tg_secondary" {
#   provider    = aws.secondary
#   name_prefix = "drs-"
#   port        = 80
#   protocol    = "HTTP"
#   vpc_id      = aws_vpc.dr_vpc_secondary.id
#   lifecycle { create_before_destroy = true }
#   health_check {
#     path                = "/"
#     interval            = 30
#     timeout             = 5
#     healthy_threshold   = 2
#     unhealthy_threshold = 2
#   }
#   tags = { Name = "${var.dr_stack_name}-tg-dr" }
# }

# resource "aws_lb" "dr_alb_primary" {
#   name               = "${var.dr_stack_name}-alb"
#   internal           = true
#   load_balancer_type = "application"
#   security_groups    = [aws_security_group.alb_sg.id]
#   subnets            = [aws_subnet.dr_primary_private.id, aws_subnet.dr_primary_private2.id]
#   tags               = { Name = "${var.dr_stack_name}-alb" }
# }

# resource "aws_lb" "dr_alb_secondary" {
#   provider           = aws.secondary
#   name               = "${var.dr_stack_name}-alb-dr"
#   internal           = true
#   load_balancer_type = "application"
#   security_groups    = [aws_security_group.alb_sg_dr.id]
#   subnets            = [aws_subnet.dr_private.id, aws_subnet.dr_private2.id]
#   tags               = { Name = "${var.dr_stack_name}-alb-dr" }
# }

# resource "aws_lb_listener" "dr_listener_primary" {
#   load_balancer_arn = aws_lb.dr_alb_primary.arn
#   port              = 80
#   protocol          = "HTTP"
#   default_action {
#     type = "fixed-response"
#     fixed_response {
#       content_type = "text/plain"
#       message_body = "Forbidden"
#       status_code  = "403"
#     }
#   }
# }

# resource "aws_lb_listener_rule" "dr_listener_rule_cf" {
#   listener_arn = aws_lb_listener.dr_listener_primary.arn
#   priority     = 10
#   action {
#     type             = "forward"
#     target_group_arn = aws_lb_target_group.dr_tg_primary.arn
#   }
#   condition {
#     http_header {
#       http_header_name = "X-CloudPulse-Origin-Verify"
#       values           = [random_password.cloudfront_origin_secret.result]
#     }
#   }
# }

# resource "aws_lb_listener" "dr_listener_secondary" {
#   provider          = aws.secondary
#   load_balancer_arn = aws_lb.dr_alb_secondary.arn
#   port              = 80
#   protocol          = "HTTP"
#   default_action {
#     type = "fixed-response"
#     fixed_response {
#       content_type = "text/plain"
#       message_body = "Forbidden"
#       status_code  = "403"
#     }
#   }
# }

# resource "aws_lb_listener_rule" "dr_listener_rule_cf_sec" {
#   provider     = aws.secondary
#   listener_arn = aws_lb_listener.dr_listener_secondary.arn
#   priority     = 10
#   action {
#     type             = "forward"
#     target_group_arn = aws_lb_target_group.dr_tg_secondary.arn
#   }
#   condition {
#     http_header {
#       http_header_name = "X-CloudPulse-Origin-Verify"
#       values           = [random_password.cloudfront_origin_secret.result]
#     }
#   }
# }

# resource "aws_autoscaling_group" "dr_asg_primary" {
#   name = "${var.dr_stack_name}-asg"
#   launch_template {
#     id      = aws_launch_template.dr_lt_primary.id
#     version = "$Latest"
#   }
#   enabled_metrics     = ["GroupInServiceInstances"]
#   min_size            = 2
#   max_size            = 4
#   desired_capacity    = 2
#   vpc_zone_identifier = [aws_subnet.dr_primary_private.id, aws_subnet.dr_primary_private2.id]
#   target_group_arns   = [aws_lb_target_group.dr_tg_primary.arn]
#   tag {
#     key                 = "Name"
#     value               = "${var.dr_stack_name}-server"
#     propagate_at_launch = true
#   }
# }

# resource "aws_autoscaling_group" "dr_asg_secondary" {
#   provider = aws.secondary
#   name     = "${var.dr_stack_name}-asg-dr"
#   launch_template {
#     id      = aws_launch_template.dr_lt_secondary.id
#     version = "$Latest"
#   }
#   min_size            = var.dr_standby_desired_capacity > 0 ? var.dr_standby_desired_capacity : 0
#   max_size            = 4
#   desired_capacity    = var.dr_standby_desired_capacity
#   vpc_zone_identifier = [aws_subnet.dr_private.id, aws_subnet.dr_private2.id]
#   target_group_arns   = [aws_lb_target_group.dr_tg_secondary.arn]
#   tag {
#     key                 = "Name"
#     value               = "${var.dr_stack_name}-server-dr"
#     propagate_at_launch = true
#   }
# }

# resource "aws_sns_topic" "dr_failover" {
#   name              = "${var.dr_stack_name}-dr-failover"
#   kms_master_key_id = aws_kms_key.dr_kms_mrk.id
# }

# # Encrypted topics need an explicit sns:Publish grant for CloudWatch; without it alarms fail with KMS-style errors.
# data "aws_iam_policy_document" "dr_failover_sns" {
#   statement {
#     sid    = "TopicOwnerAccess"
#     effect = "Allow"
#     principals {
#       type        = "AWS"
#       identifiers = ["*"]
#     }
#     actions = [
#       "SNS:Publish",
#       "SNS:RemovePermission",
#       "SNS:SetTopicAttributes",
#       "SNS:DeleteTopic",
#       "SNS:ListSubscriptionsByTopic",
#       "SNS:GetTopicAttributes",
#       "SNS:AddPermission",
#       "SNS:Subscribe",
#       "SNS:Receive",
#     ]
#     resources = [aws_sns_topic.dr_failover.arn]
#     condition {
#       test     = "StringEquals"
#       variable = "AWS:SourceOwner"
#       values   = [data.aws_caller_identity.current.account_id]
#     }
#   }

#   statement {
#     sid    = "AllowCloudWatchAlarmPublish"
#     effect = "Allow"
#     principals {
#       type        = "Service"
#       identifiers = ["cloudwatch.amazonaws.com"]
#     }
#     actions   = ["sns:Publish"]
#     resources = [aws_sns_topic.dr_failover.arn]
#     condition {
#       test     = "StringEquals"
#       variable = "aws:SourceAccount"
#       values   = [data.aws_caller_identity.current.account_id]
#     }
#   }
# }

# resource "aws_sns_topic_policy" "dr_failover" {
#   arn    = aws_sns_topic.dr_failover.arn
#   policy = data.aws_iam_policy_document.dr_failover_sns.json
# }

# resource "aws_cloudwatch_metric_alarm" "primary_health" {
#   alarm_name          = "${var.dr_stack_name}-primary-asg-zero-in-service"
#   comparison_operator = "LessThanThreshold"
#   evaluation_periods  = 1
#   datapoints_to_alarm = 1
#   metric_name         = "GroupInServiceInstances"
#   namespace           = "AWS/AutoScaling"
#   period              = 60
#   statistic           = "Average"
#   threshold           = 1
#   alarm_description   = "Primary ASG has zero InService instances (GroupInServiceInstances < 1 for 1 minute); SNS can invoke DR scale-up Lambda. OK when at least one instance is InService."
#   alarm_actions       = [aws_sns_topic.dr_failover.arn]
#   treat_missing_data  = "missing"
#   dimensions = {
#     AutoScalingGroupName = aws_autoscaling_group.dr_asg_primary.name
#   }
# }

# data "archive_file" "dr_scale_up" {
#   type        = "zip"
#   output_path = "${path.module}/dr_lambda_bundle.zip"
#   source {
#     content  = file("${path.module}/dr_lambda/index.py")
#     filename = "index.py"
#   }
# }

# resource "aws_iam_role" "lambda_dr" {
#   name = "${var.dr_stack_name}-lambda-dr"
#   assume_role_policy = jsonencode({
#     Version = "2012-10-17"
#     Statement = [{
#       Action    = "sts:AssumeRole"
#       Effect    = "Allow"
#       Principal = { Service = "lambda.amazonaws.com" }
#     }]
#   })
# }

# resource "aws_iam_role_policy" "lambda_dr" {
#   name = "${var.dr_stack_name}-lambda-dr-policy"
#   role = aws_iam_role.lambda_dr.id
#   policy = jsonencode({
#     Version = "2012-10-17"
#     Statement = [
#       {
#         Effect   = "Allow"
#         Action   = ["autoscaling:UpdateAutoScalingGroup"]
#         Resource = aws_autoscaling_group.dr_asg_secondary.arn
#       },
#       {
#         Effect   = "Allow"
#         Action   = ["autoscaling:DescribeAutoScalingGroups"]
#         Resource = "*"
#       },
#       {
#         Effect = "Allow"
#         Action = [
#           "logs:CreateLogGroup",
#           "logs:CreateLogStream",
#           "logs:PutLogEvents"
#         ]
#         Resource = "arn:aws:logs:${data.aws_region.dr_primary.name}:${data.aws_caller_identity.current.account_id}:*"
#       },
#       {
#         Effect = "Allow"
#         Action = [
#           "kms:Decrypt", "kms:DescribeKey", "kms:GenerateDataKey", "kms:GenerateDataKeyWithoutPlaintext"
#         ]
#         Resource = aws_kms_key.dr_kms_mrk.arn
#       }
#     ]
#   })
# }

# resource "aws_lambda_function" "dr_scale_up" {
#   # Must live in the same region as aws_sns_topic.dr_failover — SNS cannot invoke Lambda cross-region.
#   function_name    = "${var.dr_stack_name}-dr-scale-up"
#   runtime          = "python3.11"
#   handler          = "index.lambda_handler"
#   role             = aws_iam_role.lambda_dr.arn
#   kms_key_arn      = aws_kms_key.dr_kms_mrk.arn
#   filename         = data.archive_file.dr_scale_up.output_path
#   source_code_hash = data.archive_file.dr_scale_up.output_base64sha256
#   environment {
#     variables = {
#       ASG_REGION       = data.aws_region.secondary.name
#       ASG_NAME         = aws_autoscaling_group.dr_asg_secondary.name
#       DESIRED_CAPACITY = tostring(var.dr_lambda_scale_desired_capacity)
#       MIN_SIZE         = tostring(var.dr_lambda_scale_min_size)
#     }
#   }
#   tags = { Name = "${var.dr_stack_name}-dr-scale-up" }
# }

# resource "aws_sns_topic_subscription" "dr_lambda" {
#   count      = var.dr_route53_automatic_failover ? 1 : 0
#   topic_arn  = aws_sns_topic.dr_failover.arn
#   protocol   = "lambda"
#   endpoint   = aws_lambda_function.dr_scale_up.arn
#   depends_on = [aws_lambda_permission.dr_sns[0]]
# }

# resource "aws_lambda_permission" "dr_sns" {
#   count         = var.dr_route53_automatic_failover ? 1 : 0
#   statement_id  = "AllowExecutionFromSNS"
#   action        = "lambda:InvokeFunction"
#   function_name = aws_lambda_function.dr_scale_up.function_name
#   principal     = "sns.amazonaws.com"
#   source_arn    = aws_sns_topic.dr_failover.arn
# }

# resource "aws_wafv2_web_acl" "dr_waf" {
#   provider    = aws.us-east-1
#   name        = "${var.dr_stack_name}-waf-dr"
#   description = "WAF for CloudPulse DR lab"
#   scope       = "CLOUDFRONT"
#   default_action {
#     allow {}
#   }
#   rule {
#     name     = "SQLInjection"
#     priority = 1
#     statement {
#       managed_rule_group_statement {
#         vendor_name = "AWS"
#         name        = "AWSManagedRulesSQLiRuleSet"
#       }
#     }
#     override_action {
#       none {}
#     }
#     visibility_config {
#       cloudwatch_metrics_enabled = true
#       metric_name                = "SQLiDR"
#       sampled_requests_enabled   = true
#     }
#   }
#   rule {
#     name     = "RateLimit"
#     priority = 2
#     statement {
#       rate_based_statement {
#         limit = 1000
#       }
#     }
#     action {
#       block {}
#     }
#     visibility_config {
#       cloudwatch_metrics_enabled = true
#       metric_name                = "RateDR"
#       sampled_requests_enabled   = true
#     }
#   }
#   visibility_config {
#     cloudwatch_metrics_enabled = true
#     metric_name                = "CloudPulseDRWAF"
#     sampled_requests_enabled   = true
#   }
# }

# resource "aws_cloudfront_vpc_origin" "dr_cf_vpc_pri" {
#   vpc_origin_endpoint_config {
#     name                   = "${var.dr_stack_name}-alb-vpc-origin"
#     arn                    = aws_lb.dr_alb_primary.arn
#     http_port              = 80
#     https_port             = 443
#     origin_protocol_policy = "http-only"
#     origin_ssl_protocols {
#       items    = ["TLSv1.2"]
#       quantity = 1
#     }
#   }
# }

# resource "aws_cloudfront_vpc_origin" "dr_cf_vpc_sec" {
#   vpc_origin_endpoint_config {
#     name                   = "${var.dr_stack_name}-alb-dr-vpc-origin"
#     arn                    = aws_lb.dr_alb_secondary.arn
#     http_port              = 80
#     https_port             = 443
#     origin_protocol_policy = "http-only"
#     origin_ssl_protocols {
#       items    = ["TLSv1.2"]
#       quantity = 1
#     }
#   }
# }

# resource "aws_cloudfront_distribution" "dr_cf_dist" {
#   origin {
#     domain_name = aws_lb.dr_alb_primary.dns_name
#     origin_id   = "primary-alb"
#     custom_header {
#       name  = "X-CloudPulse-Origin-Verify"
#       value = random_password.cloudfront_origin_secret.result
#     }
#     vpc_origin_config {
#       vpc_origin_id = aws_cloudfront_vpc_origin.dr_cf_vpc_pri.id
#     }
#   }
#   origin {
#     domain_name = aws_lb.dr_alb_secondary.dns_name
#     origin_id   = "dr-alb"
#     custom_header {
#       name  = "X-CloudPulse-Origin-Verify"
#       value = random_password.cloudfront_origin_secret.result
#     }
#     vpc_origin_config {
#       vpc_origin_id = aws_cloudfront_vpc_origin.dr_cf_vpc_sec.id
#     }
#   }

#   origin_group {
#     origin_id = "app-failover"
#     failover_criteria {
#       status_codes = [403, 404, 500, 502, 503, 504]
#     }
#     member { origin_id = "primary-alb" }
#     member { origin_id = "dr-alb" }
#   }

#   depends_on = [
#     aws_cloudfront_vpc_origin.dr_cf_vpc_pri,
#     aws_cloudfront_vpc_origin.dr_cf_vpc_sec
#   ]

#   enabled             = true
#   is_ipv6_enabled     = true
#   default_root_object = ""
#   aliases             = var.cloudfront_aliases_dr

#   default_cache_behavior {
#     allowed_methods  = ["GET", "HEAD", "OPTIONS"]
#     cached_methods   = ["GET", "HEAD"]
#     target_origin_id = "app-failover"
#     forwarded_values {
#       query_string = true
#       cookies { forward = "all" }
#     }
#     viewer_protocol_policy = "redirect-to-https"
#     min_ttl                = 0
#     default_ttl            = 0
#     max_ttl                = 0
#   }

#   ordered_cache_behavior {
#     path_pattern     = "/background-image*"
#     allowed_methods  = ["GET", "HEAD"]
#     cached_methods   = ["GET", "HEAD"]
#     target_origin_id = "app-failover"
#     forwarded_values {
#       query_string = false
#       cookies { forward = "none" }
#     }
#     viewer_protocol_policy = "redirect-to-https"
#     min_ttl                = 0
#     default_ttl            = 86400
#     max_ttl                = 31536000
#   }

#   restrictions {
#     geo_restriction {
#       restriction_type = "none"
#     }
#   }

#   dynamic "viewer_certificate" {
#     for_each = length(var.cloudfront_aliases_dr) > 0 ? [1] : []
#     content {
#       acm_certificate_arn      = data.aws_acm_certificate.disaster.arn
#       ssl_support_method       = "sni-only"
#       minimum_protocol_version = "TLSv1.2_2021"
#     }
#   }

#   dynamic "viewer_certificate" {
#     for_each = length(var.cloudfront_aliases_dr) == 0 ? [1] : []
#     content {
#       cloudfront_default_certificate = true
#     }
#   }

#   web_acl_id = aws_wafv2_web_acl.dr_waf.arn
#   tags       = { Name = "${var.dr_stack_name}-cf-dr" }
# }

# output "dr_cloudfront_domain_name" {
#   description = "HTTPS URL host (append https://). Uses origin failover: primary ALB then DR ALB."
#   value       = aws_cloudfront_distribution.dr_cf_dist.domain_name
# }

# output "dr_primary_alb_dns" {
#   description = "Primary internal ALB DNS (reachable only via CloudFront VPC Origin / private network)."
#   value       = aws_lb.dr_alb_primary.dns_name
# }

# output "dr_secondary_alb_dns" {
#   description = "DR internal ALB DNS in aws.secondary (not internet-routable)."
#   value       = aws_lb.dr_alb_secondary.dns_name
# }

# output "dr_primary_failover_alarm_name" {
#   description = "CloudWatch alarm on primary ASG GroupInServiceInstances (ALARM when 0, OK when >= 1); publishes to SNS in var.aws_region."
#   value       = aws_cloudwatch_metric_alarm.primary_health.alarm_name
# }

# output "dr_sns_topic_arn" {
#   description = "SNS topic in var.aws_region; publishing invokes the DR Lambda when subscription is enabled."
#   value       = aws_sns_topic.dr_failover.arn
# }

# output "dr_manual_failover_aws_cli" {
#   description = "Manual capacity failover: publish to SNS (same path as automatic alarm)."
#   value       = "aws sns publish --region ${data.aws_region.dr_primary.name} --topic-arn ${aws_sns_topic.dr_failover.arn} --message '{\"default\":\"manual-dr-failover\"}'"
# }

# output "dr_manual_lambda_invoke_cli" {
#   description = "Manual failover: invoke the DR Lambda directly (scales the DR Auto Scaling group)."
#   value       = "aws lambda invoke --region ${data.aws_region.dr_primary.name} --function-name ${aws_lambda_function.dr_scale_up.function_name} --payload '{}' dr_response.json"
# }

# output "dr_automatic_failover_note" {
#   description = "How automatic failover is wired (for lab write-ups)."
#   value       = "Primary ASG AWS/AutoScaling GroupInServiceInstances alarm in ${data.aws_region.dr_primary.name} (ALARM when 0 InService) → SNS (same region) → Lambda in ${data.aws_region.dr_primary.name} calls Auto Scaling in ${data.aws_region.secondary.name} to scale DR ASG. CloudFront uses HA-style VPC origins + origin header, and origin group fails over on configured HTTP errors when DR has healthy targets. Toggle subscription with var.dr_route53_automatic_failover."
# }
