# # ============================================================
# # CloudPulse — encryption at rest (KMS) + data in transit
# # Private app tier, ALB, CloudFront (HTTPS), WAF
# # us-east-1 provider: certificate.tf (ACM for CloudFront)
# # HA variant (same base + CRR, DynamoDB replica, ASG×2): high_availability.tf
# # ============================================================
# terraform {
#   required_providers {
#     aws = {
#       source  = "hashicorp/aws"
#       version = "~> 5.0"
#     }
#     random = {
#       source  = "hashicorp/random"
#       version = "~> 3.6"
#     }
#   }
# }

# provider "aws" {
#   region = var.aws_region
# }

# data "aws_caller_identity" "current" {}
# data "aws_region" "current" {}
# data "aws_availability_zones" "available" {
#   state = "available"
# }

# data "aws_ami" "amazon_linux" {
#   most_recent = true
#   owners      = ["amazon"]

#   filter {
#     name   = "name"
#     values = ["al2023-ami-*-x86_64"]
#   }

#   filter {
#     name   = "virtualization-type"
#     values = ["hvm"]
#   }
# }

# # CloudFront → origin requests use addresses in this AWS-managed prefix list.
# data "aws_ec2_managed_prefix_list" "cloudfront_origin" {
#   name = "com.amazonaws.global.cloudfront.origin-facing"
# }

# # Shared secret: CloudFront adds it on every origin request; ALB forwards only if it matches.
# resource "random_password" "cloudfront_origin_secret" {
#   length  = 48
#   special = false
# }

# data "aws_acm_certificate" "transit" {
#   provider = aws.us-east-1

#   domain   = "transit.derherzen.com"
#   statuses = ["ISSUED"]
# }

# resource "aws_kms_key" "cloudpulse" {
#   description = "KMS key for CloudPulse infrastructure encryption"

#   policy = jsonencode({
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
#           "kms:GenerateDataKey*",
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
#           "kms:GenerateDataKey*",
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
#         Condition = {
#           Bool = {
#             "kms:GrantIsForAWSResource" = true
#           }
#         }
#       }
#     ]
#   })

#   tags = { Name = "${var.project_name}-kms" }
# }


# # ============================================================
# # PHASE 1: Network — VPC, public + private, NAT
# # ============================================================

# resource "aws_vpc" "cloudpulse" {
#   cidr_block           = var.vpc_cidr
#   enable_dns_support   = true
#   enable_dns_hostnames = true
#   tags                 = { Name = "${var.project_name}-vpc" }
# }

# resource "aws_internet_gateway" "cloudpulse" {
#   vpc_id = aws_vpc.cloudpulse.id
#   tags   = { Name = "${var.project_name}-igw" }
# }

# resource "aws_subnet" "public" {
#   vpc_id                  = aws_vpc.cloudpulse.id
#   cidr_block              = cidrsubnet(var.vpc_cidr, 2, 0)
#   availability_zone       = data.aws_availability_zones.available.names[0]
#   map_public_ip_on_launch = true
#   tags                    = { Name = "${var.project_name}-public-subnet" }
# }

# resource "aws_subnet" "public2" {
#   vpc_id                  = aws_vpc.cloudpulse.id
#   cidr_block              = cidrsubnet(var.vpc_cidr, 2, 1)
#   availability_zone       = data.aws_availability_zones.available.names[1]
#   map_public_ip_on_launch = true
#   tags                    = { Name = "${var.project_name}-public-subnet2" }
# }

# resource "aws_eip" "nat" {
#   domain = "vpc"
#   tags   = { Name = "${var.project_name}-nat-eip" }
# }

# resource "aws_nat_gateway" "cloudpulse" {
#   allocation_id = aws_eip.nat.id
#   subnet_id     = aws_subnet.public.id
#   tags          = { Name = "${var.project_name}-nat" }
# }

# resource "aws_subnet" "private" {
#   vpc_id            = aws_vpc.cloudpulse.id
#   cidr_block        = cidrsubnet(var.vpc_cidr, 2, 2)
#   availability_zone = data.aws_availability_zones.available.names[0]
#   tags              = { Name = "${var.project_name}-private-subnet" }
# }

# resource "aws_subnet" "private2" {
#   vpc_id            = aws_vpc.cloudpulse.id
#   cidr_block        = cidrsubnet(var.vpc_cidr, 2, 3)
#   availability_zone = data.aws_availability_zones.available.names[1]
#   tags              = { Name = "${var.project_name}-private-subnet2" }
# }

# resource "aws_route_table" "private" {
#   vpc_id = aws_vpc.cloudpulse.id
#   route {
#     cidr_block     = "0.0.0.0/0"
#     nat_gateway_id = aws_nat_gateway.cloudpulse.id
#   }
#   tags = { Name = "${var.project_name}-private-rt" }
# }

# resource "aws_route_table_association" "private" {
#   subnet_id      = aws_subnet.private.id
#   route_table_id = aws_route_table.private.id
# }

# resource "aws_route_table_association" "private2" {
#   subnet_id      = aws_subnet.private2.id
#   route_table_id = aws_route_table.private.id
# }

# resource "aws_route_table" "public" {
#   vpc_id = aws_vpc.cloudpulse.id
#   route {
#     cidr_block = "0.0.0.0/0"
#     gateway_id = aws_internet_gateway.cloudpulse.id
#   }
#   tags = { Name = "${var.project_name}-public-rt" }
# }

# resource "aws_route_table_association" "public" {
#   subnet_id      = aws_subnet.public.id
#   route_table_id = aws_route_table.public.id
# }

# resource "aws_route_table_association" "public2" {
#   subnet_id      = aws_subnet.public2.id
#   route_table_id = aws_route_table.public.id
# }


# # ============================================================
# # PHASE 2: Security groups + S3 (SSE-KMS + deny unencrypted PUT)
# # ============================================================

# resource "aws_security_group" "cloudpulse_sg" {
#   name        = "${var.project_name}-sg"
#   description = "App tier - SSH, metrics; app port from ALB only"
#   vpc_id      = aws_vpc.cloudpulse.id

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
#     description = "Grafana / Apps"
#     from_port   = 3000
#     to_port     = 3000
#     protocol    = "tcp"
#     cidr_blocks = ["0.0.0.0/0"]
#   }

#   ingress {
#     description = "Allow all internal traffic between cluster nodes"
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

#   tags = { Name = "${var.project_name}-sg" }
# }

# resource "aws_security_group" "alb_sg" {
#   name        = "${var.project_name}-alb-sg"
#   description = "Internal ALB - HTTP only from CloudFront (prefix list, VPC Origin)"
#   vpc_id      = aws_vpc.cloudpulse.id

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

#   tags = { Name = "${var.project_name}-alb-sg" }
# }

# resource "aws_s3_bucket" "cloudpulse" {
#   bucket = "${var.s3_bucket_prefix}-${data.aws_caller_identity.current.account_id}-${data.aws_region.current.name}"
#   tags   = { Name = "${var.project_name}-assets" }
# }

# resource "aws_s3_object" "background" {
#   bucket                 = aws_s3_bucket.cloudpulse.id
#   key                    = var.background_image_key
#   source                 = var.background_image_path
#   content_type           = "image/jpeg"
#   server_side_encryption = "aws:kms"
#   kms_key_id             = aws_kms_key.cloudpulse.arn
# }

# resource "aws_s3_bucket_server_side_encryption_configuration" "cloudpulse" {
#   bucket = aws_s3_bucket.cloudpulse.id

#   rule {
#     apply_server_side_encryption_by_default {
#       sse_algorithm     = "aws:kms"
#       kms_master_key_id = aws_kms_key.cloudpulse.arn
#     }
#   }
# }

# resource "aws_s3_bucket_policy" "cloudpulse_encryption_enforce" {
#   bucket = aws_s3_bucket.cloudpulse.id

#   policy = jsonencode({
#     Version = "2012-10-17"
#     Statement = [
#       {
#         Sid       = "DenyUnencryptedObjectUploads"
#         Effect    = "Deny"
#         Principal = "*"
#         Action    = "s3:PutObject"
#         Resource  = "${aws_s3_bucket.cloudpulse.arn}/*"
#         Condition = {
#           StringNotEquals = {
#             "s3:x-amz-server-side-encryption" = "aws:kms"
#           }
#         }
#       }
#     ]
#   })
# }


# # ============================================================
# # PHASE 3: DynamoDB (KMS)
# # ============================================================

# resource "aws_dynamodb_table" "cloudpulse" {
#   name         = var.dynamodb_table_name
#   billing_mode = "PAY_PER_REQUEST"
#   hash_key     = "id"

#   attribute {
#     name = "id"
#     type = "S"
#   }

#   server_side_encryption {
#     enabled     = true
#     kms_key_arn = aws_kms_key.cloudpulse.arn
#   }

#   tags = { Name = "${var.project_name}-counter" }
# }

# resource "aws_dynamodb_table_item" "visits" {
#   table_name = aws_dynamodb_table.cloudpulse.name
#   hash_key   = aws_dynamodb_table.cloudpulse.hash_key

#   item = <<ITEM
# {
#   "id": {"S": "visits"},
#   "count": {"N": "0"}
# }
# ITEM

#   lifecycle {
#     ignore_changes = [item]
#   }
# }


# # ============================================================
# # PHASE 4: IAM + launch template (KMS EBS) + ASG in private subnets
# # ============================================================

# resource "aws_iam_role" "cloudpulse_ec2" {
#   name = "${var.project_name}-instance-role"
#   assume_role_policy = jsonencode({
#     Version = "2012-10-17"
#     Statement = [{
#       Action    = "sts:AssumeRole", Effect = "Allow"
#       Principal = { Service = "ec2.amazonaws.com" }
#     }]
#   })
# }

# resource "aws_iam_role_policy" "cloudpulse_access" {
#   name = "${var.project_name}-access-policy"
#   role = aws_iam_role.cloudpulse_ec2.id
#   policy = jsonencode({
#     Version = "2012-10-17"
#     Statement = [
#       {
#         Effect = "Allow"
#         Action = ["s3:GetObject", "s3:ListBucket"]
#         Resource = [aws_s3_bucket.cloudpulse.arn,
#         "${aws_s3_bucket.cloudpulse.arn}/*"]
#       },
#       {
#         Effect = "Allow"
#         Action = ["dynamodb:GetItem", "dynamodb:UpdateItem",
#         "dynamodb:PutItem"]
#         Resource = aws_dynamodb_table.cloudpulse.arn
#       },
#       {
#         Effect = "Allow"
#         Action = [
#           "kms:Decrypt",
#           "kms:DescribeKey",
#           "kms:GenerateDataKey",
#           "kms:GenerateDataKeyWithoutPlaintext",
#           "kms:CreateGrant",
#           "kms:ReEncrypt*"
#         ]
#         Resource = aws_kms_key.cloudpulse.arn
#       }
#     ]
#   })
# }

# resource "aws_iam_instance_profile" "cloudpulse" {
#   name = "${var.project_name}-instance-profile"
#   role = aws_iam_role.cloudpulse_ec2.name
# }

# resource "aws_launch_template" "cloudpulse" {
#   name_prefix   = "${var.project_name}-lt"
#   image_id      = data.aws_ami.amazon_linux.id
#   instance_type = var.instance_type

#   vpc_security_group_ids = [aws_security_group.cloudpulse_sg.id]

#   iam_instance_profile {
#     name = aws_iam_instance_profile.cloudpulse.name
#   }

#   block_device_mappings {
#     device_name = "/dev/xvda"
#     ebs {
#       encrypted   = true
#       kms_key_id  = aws_kms_key.cloudpulse.arn
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
#     bucket_name = aws_s3_bucket.cloudpulse.bucket,
#     table_name  = var.dynamodb_table_name,
#     aws_region  = var.aws_region,
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

#     wget https://github.com/prometheus/node_exporter/releases/download/v1.7.0/node_exporter-1.7.0.linux-amd64.tar.gz
#     tar xvfz node_exporter-1.7.0.linux-amd64.tar.gz
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

#     curl -L https://github.com/grafana/loki/releases/download/v2.9.1/promtail-linux-amd64.zip -o promtail.zip
#     unzip promtail.zip
#     mv promtail-linux-amd64 /usr/local/bin/promtail

#     cat <<PROM_EOF > /etc/promtail-config.yml
#     server:
#       http_listen_port: 9080
#       grpc_listen_port: 0

#     positions:
#       filename: /tmp/positions.yaml

#     clients:
#       - url: http://10.0.0.20:3100/loki/api/v1/push

#     scrape_configs:
#     - job_name: flask-logs
#       static_configs:
#       - targets:
#           - localhost
#         labels:
#           job: cloudpulse
#           instance: ${var.project_name}-server
#           __path__: /home/ec2-user/app/app.log
#     PROM_EOF

#     docker run -d --restart unless-stopped --name=node-exporter -p 9100:9100 prom/node-exporter

#     cat <<P_SVC_EOF > /etc/systemd/system/promtail.service
#     [Unit]
#     Description=Promtail service
#     After=network.target

#     [Service]
#     Type=simple
#     User=root
#     ExecStart=/usr/local/bin/promtail -config.file=/etc/promtail-config.yml

#     [Install]
#     WantedBy=multi-user.target
#     P_SVC_EOF

#     systemctl enable promtail
#     systemctl start promtail
#   EOF
# )

# tags = {
#   Name = "${var.project_name}-server"
# }
# }

# resource "aws_autoscaling_group" "cloudpulse" {
#   name = "${var.project_name}-asg"
#   launch_template {
#     id      = aws_launch_template.cloudpulse.id
#     version = "$Latest"
#   }
#   min_size            = 1
#   max_size            = 3
#   desired_capacity    = 1
#   vpc_zone_identifier = [aws_subnet.private.id, aws_subnet.private2.id]
#   target_group_arns   = [aws_lb_target_group.cloudpulse.arn]

#   tag {
#     key                 = "Name"
#     value               = "${var.project_name}-server"
#     propagate_at_launch = true
#   }
# }


# # ============================================================
# # PHASE 5: Application load balancer
# # ============================================================

# resource "aws_lb" "cloudpulse" {
#   name               = "${var.project_name}-alb"
#   internal           = true
#   load_balancer_type = "application"
#   security_groups    = [aws_security_group.alb_sg.id]
#   subnets            = [aws_subnet.private.id, aws_subnet.private2.id]
#   tags               = { Name = "${var.project_name}-alb" }
# }

# resource "aws_lb_target_group" "cloudpulse" {
#   name_prefix = "cloudp"
#   port        = 80
#   protocol    = "HTTP"
#   vpc_id      = aws_vpc.cloudpulse.id

#   lifecycle {
#     create_before_destroy = true
#   }

#   health_check {
#     path                = "/"
#     interval            = 30
#     timeout             = 5
#     healthy_threshold   = 2
#     unhealthy_threshold = 2
#   }
#   tags = { Name = "${var.project_name}-tg" }
# }


# resource "aws_lb_listener" "cloudpulse" {
#   load_balancer_arn = aws_lb.cloudpulse.arn
#   port              = "80"
#   protocol          = "HTTP"
#   # Reject callers that are not CloudFront (wrong secret) or bypass CloudFront (SG blocks anyway).
#   default_action {
#     type = "fixed-response"
#     fixed_response {
#       content_type = "text/plain"
#       message_body = "Forbidden"
#       status_code  = "403"
#     }
#   }
# }

# resource "aws_lb_listener_rule" "cloudfront_origin_secret_header" {
#   listener_arn = aws_lb_listener.cloudpulse.arn
#   priority     = 10

#   action {
#     type             = "forward"
#     target_group_arn = aws_lb_target_group.cloudpulse.arn
#   }

#   condition {
#     http_header {
#       http_header_name = "X-CloudPulse-Origin-Verify"
#       values           = [random_password.cloudfront_origin_secret.result]
#     }
#   }
# }

# # CloudFront -> internal ALB via VPC Origin (private AWS network, not public internet).
# # Registry docs show https-only + e.g. 8080/8443 as one valid example; those values must
# # match the ALB listeners. We use http-only + port 80 because aws_lb_listener.cloudpulse is HTTP:80 only.
# # To use https-only here, add an HTTPS listener (443) on the ALB with a regional ACM cert, then set
# # origin_protocol_policy = "https-only" and https_port to that listener port.
# resource "aws_cloudfront_vpc_origin" "cloudpulse" {
#   vpc_origin_endpoint_config {
#     name                   = "${var.project_name}-alb-vpc-origin"
#     arn                    = aws_lb.cloudpulse.arn
#     http_port              = 80
#     https_port             = 443
#     origin_protocol_policy = "http-only"

#     origin_ssl_protocols {
#       items    = ["TLSv1.2"]
#       quantity = 1
#     }
#   }
# }


# # ============================================================
# # PHASE 6: WAF (CloudFront scope) + CloudFront (HTTPS to viewers)
# # ============================================================

# resource "aws_wafv2_web_acl" "cloudpulse" {
#   provider    = aws.us-east-1
#   name        = "${var.project_name}-waf"
#   description = "WAF for CloudPulse"
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
#       metric_name                = "SQLInjection"
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
#       metric_name                = "RateLimit"
#       sampled_requests_enabled   = true
#     }
#   }
#   visibility_config {
#     cloudwatch_metrics_enabled = true
#     metric_name                = "CloudPulseWAF"
#     sampled_requests_enabled   = true
#   }
# }

# resource "aws_cloudfront_distribution" "cloudpulse" {
#   origin {
#     domain_name = aws_lb.cloudpulse.dns_name
#     origin_id   = "ALBOrigin"
#     custom_header {
#       name  = "X-CloudPulse-Origin-Verify"
#       value = random_password.cloudfront_origin_secret.result
#     }
#     vpc_origin_config {
#       vpc_origin_id = aws_cloudfront_vpc_origin.cloudpulse.id
#     }
#   }

#   depends_on          = [aws_cloudfront_vpc_origin.cloudpulse]
#   enabled             = true
#   is_ipv6_enabled     = true
#   default_root_object = ""
#   aliases             = var.cloudfront_aliases
#   default_cache_behavior {
#     allowed_methods  = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
#     cached_methods   = ["GET", "HEAD"]
#     target_origin_id = "ALBOrigin"
#     forwarded_values {
#       query_string = true
#       cookies {
#         forward = "all"
#       }
#     }
#     viewer_protocol_policy = "redirect-to-https"
#     min_ttl                = 0
#     default_ttl            = 3600
#     max_ttl                = 86400
#   }

#   ordered_cache_behavior {
#     path_pattern     = "/background-image*"
#     allowed_methods  = ["GET", "HEAD"]
#     cached_methods   = ["GET", "HEAD"]
#     target_origin_id = "ALBOrigin"
#     forwarded_values {
#       query_string = false
#       cookies {
#         forward = "none"
#       }
#     }
#     viewer_protocol_policy = "redirect-to-https"
#     min_ttl                = 86400
#     default_ttl            = 86400
#     max_ttl                = 31536000
#   }
#   restrictions {
#     geo_restriction {
#       restriction_type = "none"
#     }
#   }
#   dynamic "viewer_certificate" {
#     for_each = length(var.cloudfront_aliases) > 0 ? [1] : []
#     content {
#       acm_certificate_arn      = data.aws_acm_certificate.transit.arn
#       ssl_support_method       = "sni-only"
#       minimum_protocol_version = "TLSv1.2_2021"
#     }
#   }

#   dynamic "viewer_certificate" {
#     for_each = length(var.cloudfront_aliases) == 0 ? [1] : []
#     content {
#       cloudfront_default_certificate = true
#     }
#   }

#   web_acl_id = aws_wafv2_web_acl.cloudpulse.arn
#   tags       = { Name = "${var.project_name}-cf" }
# }


# # ============================================================
# # PHASE 7: CloudWatch alarms
# # ============================================================

# resource "aws_cloudwatch_metric_alarm" "alb_healthy_hosts" {
#   alarm_name          = "${var.project_name}-alb-healthy-hosts"
#   comparison_operator = "LessThanThreshold"
#   evaluation_periods  = "2"
#   metric_name         = "HealthyHostCount"
#   namespace           = "AWS/ApplicationELB"
#   period              = "300"
#   statistic           = "Average"
#   threshold           = "1"
#   alarm_description   = "This metric monitors ALB healthy host count"
#   alarm_actions       = []
#   treat_missing_data  = "breaching"

#   dimensions = {
#     LoadBalancer = aws_lb.cloudpulse.arn_suffix
#     TargetGroup  = aws_lb_target_group.cloudpulse.arn_suffix
#   }
# }

# resource "aws_cloudwatch_metric_alarm" "asg_cpu" {
#   alarm_name          = "${var.project_name}-asg-cpu-high"
#   comparison_operator = "GreaterThanThreshold"
#   evaluation_periods  = "2"
#   metric_name         = "GroupAverageCPUUtilization"
#   namespace           = "AWS/AutoScaling"
#   period              = "300"
#   statistic           = "Average"
#   threshold           = "80"
#   alarm_description   = "This metric monitors ASG CPU utilization"
#   alarm_actions       = []
#   treat_missing_data  = "notBreaching"

#   dimensions = {
#     AutoScalingGroupName = aws_autoscaling_group.cloudpulse.name
#   }
# }

# resource "aws_cloudwatch_metric_alarm" "cloudfront_5xx" {
#   alarm_name          = "${var.project_name}-cloudfront-5xx"
#   provider            = aws.us-east-1
#   comparison_operator = "GreaterThanThreshold"
#   evaluation_periods  = "1"
#   metric_name         = "5xxErrorRate"
#   namespace           = "AWS/CloudFront"
#   period              = "300"
#   statistic           = "Average"
#   threshold           = "5"
#   alarm_description   = "This metric monitors CloudFront 5xx error rate"
#   alarm_actions       = []
#   treat_missing_data  = "notBreaching"

#   dimensions = {
#     DistributionId = aws_cloudfront_distribution.cloudpulse.id
#     Region         = "Global"
#   }
# }

# resource "aws_cloudwatch_metric_alarm" "dynamodb_throttled_reads" {
#   alarm_name          = "${var.project_name}-dynamodb-throttled-reads"
#   comparison_operator = "GreaterThanThreshold"
#   evaluation_periods  = "1"
#   metric_name         = "ThrottledRequests"
#   namespace           = "AWS/DynamoDB"
#   period              = "300"
#   statistic           = "Sum"
#   threshold           = "5"
#   alarm_description   = "This metric monitors DynamoDB throttled read requests"
#   alarm_actions       = []
#   treat_missing_data  = "notBreaching"

#   dimensions = {
#     TableName = aws_dynamodb_table.cloudpulse.name
#   }
# }
