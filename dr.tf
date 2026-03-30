# # ============================================================
# # CloudPulse Infrastructure — Session 3 (Disaster Recovery Version)
# # ============================================================
# terraform {
#   required_providers {
#     aws = {
#       source  = "hashicorp/aws"
#       version = "~> 5.0"
#     }
#     archive = {
#       source  = "hashicorp/archive"
#       version = "~> 2.0"
#     }
#   }
# }

# provider "aws" {
#   region = var.aws_region
# }

# provider "aws" {
#   alias  = "secondary"
#   region = "eu-west-3"
# }

# # us-east-1 provider is defined in certificate.tf (required for ACM / CloudFront).

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

# # Data source for ACM certificate
# data "aws_acm_certificate" "disaster" {
#   provider = aws.us-east-1
#   domain   = "disaster.derherzen.com"
#   statuses = ["ISSUED"]
# }

# resource "aws_kms_key" "cloudpulse" {
#   description = "KMS key for CloudPulse infrastructure encryption"
#   tags        = { Name = "${var.project_name}-kms" }
# }


# # ============================================================
# # PHASE 1: Network — VPC + Subnet + Route table
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
#   cidr_block              = var.public_subnet_cidr
#   availability_zone       = data.aws_availability_zones.available.names[0]
#   map_public_ip_on_launch = true
#   tags                    = { Name = "${var.project_name}-public-subnet" }
# }

# resource "aws_subnet" "public2" {
#   vpc_id                  = aws_vpc.cloudpulse.id
#   cidr_block              = "10.0.1.0/26"
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
#   cidr_block        = "10.0.2.0/26"
#   availability_zone = data.aws_availability_zones.available.names[0]
#   tags              = { Name = "${var.project_name}-private-subnet" }
# }

# resource "aws_subnet" "private2" {
#   vpc_id            = aws_vpc.cloudpulse.id
#   cidr_block        = "10.0.3.0/26"
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
# # PHASE 2: Security Group (module) + S3
# # ============================================================
# # NOTE: After uncommenting, run "terraform init" before apply
# #       (required because the module is new)
# # ============================================================

# resource "aws_security_group" "cloudpulse_sg" {
#   name        = "${var.project_name}-sg"
#   description = "Allow SSH, HTTP, and App ports"
#   vpc_id      = aws_vpc.cloudpulse.id
#   # Standard SSH & HTTP
#   ingress {
#     description = "SSH"
#     from_port   = 22
#     to_port     = 22
#     protocol    = "tcp"
#     cidr_blocks = var.allowed_ssh_cidrs
#   }

#   ingress {
#     description = "App from ALB"
#     from_port   = 8089
#     to_port     = 8089
#     protocol    = "tcp"
#     security_groups = [aws_security_group.alb_sg.id]
#   }

#   # Custom Application Ports
#   ingress {
#     description = "Grafana / Apps"
#     from_port   = 3000
#     to_port     = 3000
#     protocol    = "tcp"
#     cidr_blocks = ["0.0.0.0/0"]
#   }
#   # --- PRIVATE ACCESS (Self-Referencing) ---
#   # These ports are only reachable BY the instances inside this SG.

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
#   description = "Allow HTTP from internet"
#   vpc_id      = aws_vpc.cloudpulse.id

#   ingress {
#     description = "HTTP"
#     from_port   = 80
#     to_port     = 80
#     protocol    = "tcp"
#     cidr_blocks = ["0.0.0.0/0"]
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

#   replication_configuration {
#     role = aws_iam_role.s3_replication.arn
#     rules {
#       id     = "CRR"
#       status = "Enabled"
#       destination {
#         bucket = aws_s3_bucket.cloudpulse_secondary.arn
#         storage_class = "STANDARD"
#       }
#     }
#   }
# }

# resource "aws_s3_object" "background" {
#   bucket       = aws_s3_bucket.cloudpulse.id
#   key          = var.background_image_key
#   source       = var.background_image_path
#   content_type = "image/jpeg"
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

# resource "aws_s3_bucket" "cloudpulse_secondary" {
#   provider = aws.secondary
#   bucket   = "${var.s3_bucket_prefix}-${data.aws_caller_identity.current.account_id}-eu-west-3"
#   tags     = { Name = "${var.project_name}-assets-secondary" }
# }


# # ============================================================
# # PHASE 3: DynamoDB
# # ============================================================


# resource "aws_dynamodb_table" "cloudpulse" {
#   name         = var.dynamodb_table_name
#   billing_mode = "PAY_PER_REQUEST" # No capacity planning — you pay only for actual reads/writes
#   hash_key     = "id"

#   attribute {
#     name = "id"
#     type = "S"
#   }

#   server_side_encryption {
#     enabled     = true
#     kms_key_arn = aws_kms_key.cloudpulse.arn
#   }

#   replica {
#     region_name = "eu-west-3"
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
# # PHASE 4: IAM + EC2
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

# resource "aws_iam_role" "s3_replication" {
#   name = "${var.project_name}-s3-replication-role"
#   assume_role_policy = jsonencode({
#     Version = "2012-10-17"
#     Statement = [{
#       Action = "sts:AssumeRole"
#       Principal = {
#         Service = "s3.amazonaws.com"
#       }
#       Effect = "Allow"
#     }]
#   })
# }

# resource "aws_iam_role_policy" "s3_replication" {
#   name = "${var.project_name}-s3-replication-policy"
#   role = aws_iam_role.s3_replication.id
#   policy = jsonencode({
#     Version = "2012-10-17"
#     Statement = [
#       {
#         Action = [
#           "s3:GetReplicationConfiguration",
#           "s3:ListBucket"
#         ]
#         Effect = "Allow"
#         Resource = aws_s3_bucket.cloudpulse.arn
#       },
#       {
#         Action = [
#           "s3:GetObjectVersion",
#           "s3:GetObjectVersionAcl",
#           "s3:GetObjectVersionTagging"
#         ]
#         Effect = "Allow"
#         Resource = "${aws_s3_bucket.cloudpulse.arn}/*"
#       },
#       {
#         Action = [
#           "s3:ReplicateObject",
#           "s3:ReplicateDelete",
#           "s3:ReplicateTags"
#         ]
#         Effect = "Allow"
#         Resource = aws_s3_bucket.cloudpulse_secondary.arn
#       }
#     ]
#   })
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

#     # 1. Install App dependencies
#     yum update -y
#     yum install -y python3-pip unzip
#     pip3 install flask requests boto3 pytz prometheus-flask-exporter

#     mkdir -p /home/ec2-user/app

#     # 2. Inject the Flask app
#     cat << 'PY_EOF' > /home/ec2-user/app/app.py
#     ${templatefile("${path.module}/app.py.tftpl", {
#   bucket_name = aws_s3_bucket.cloudpulse.bucket,
#   table_name  = var.dynamodb_table_name,
#   aws_region  = var.aws_region,
#   image_key   = var.background_image_key
# })}
#     PY_EOF

#     # 3. Setup Flask Service (Redirecting logs to a file for Promtail)
#     cat <<SVC_EOF > /etc/systemd/system/cloudpulse.service
#     [Unit]
#     Description=CloudPulse Flask App
#     After=network.target

#     [Service]
#     User=root
#     WorkingDirectory=/home/ec2-user/app
#     # Standard output/error redirected to app.log for Loki
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

#     # 4. Install Node Exporter (Metrics for Port 9100)
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

#     # 5. Install Promtail (Log shipping to Port 3100)
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
#   )

#   tags = {
#     Name = "${var.project_name}-server"
#   }
# }

# resource "aws_autoscaling_group" "cloudpulse" {
#   name                = "${var.project_name}-asg"
#   launch_template {
#     id      = aws_launch_template.cloudpulse.id
#     version = "$Latest"
#   }
#   min_size            = 2
#   max_size            = 3
#   desired_capacity    = 2
#   vpc_zone_identifier = [aws_subnet.private.id, aws_subnet.private2.id]
#   target_group_arns   = [aws_lb_target_group.cloudpulse.arn]

#   tag {
#     key                 = "Name"
#     value               = "${var.project_name}-server"
#     propagate_at_launch = true
#   }
# }

# # ============================================================
# # PHASE 5: CloudWatch Alarms
# # ============================================================

# # CloudWatch alarm for Route 53 health check status
# resource "aws_cloudwatch_metric_alarm" "health_check_status" {
#   alarm_name          = "${var.project_name}-health-check-failure"
#   comparison_operator = "LessThanThreshold"
#   evaluation_periods  = "1"
#   metric_name         = "HealthCheckStatus"
#   namespace           = "AWS/Route53"
#   period              = "60"
#   statistic           = "Minimum"
#   threshold           = "1"
#   alarm_description   = "This metric monitors Route 53 health check status"
#   alarm_actions       = [aws_sns_topic.dr_trigger.arn]

#   dimensions = {
#     HealthCheckId = aws_route53_health_check.primary.id
#   }
# }

# # CloudWatch alarm for Lambda errors
# resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
#   alarm_name          = "${var.project_name}-lambda-errors"
#   comparison_operator = "GreaterThanThreshold"
#   evaluation_periods  = "1"
#   metric_name         = "Errors"
#   namespace           = "AWS/Lambda"
#   period              = "300"
#   statistic           = "Sum"
#   threshold           = "0"
#   alarm_description   = "This metric monitors Lambda function errors"
#   alarm_actions       = [aws_sns_topic.dr_trigger.arn]

#   dimensions = {
#     FunctionName = aws_lambda_function.dr_scale_up.function_name
#   }
# }

# # ============================================================
# # PHASE 6: ALB
# # ============================================================

# resource "aws_lb" "cloudpulse" {
#   name               = "${var.project_name}-alb"
#   internal           = false
#   load_balancer_type = "application"
#   security_groups    = [aws_security_group.alb_sg.id]
#   subnets            = [aws_subnet.public.id, aws_subnet.public2.id]
#   tags               = { Name = "${var.project_name}-alb" }
# }

# resource "aws_lb_target_group" "cloudpulse" {
#   name     = "${var.project_name}-tg"
#   port     = 8089
#   protocol = "HTTP"
#   vpc_id   = aws_vpc.cloudpulse.id
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
#   default_action {
#     type             = "forward"
#     target_group_arn = aws_lb_target_group.cloudpulse.arn
#   }
# }

# # ============================================================
# # PHASE 7: WAF
# # ============================================================

# resource "aws_wafv2_web_acl" "cloudpulse" {
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

# # ============================================================
# # PHASE 8: CloudFront
# # ============================================================

# resource "aws_cloudfront_distribution" "cloudpulse" {
#   origin {
#     domain_name = aws_lb.cloudpulse.dns_name
#     origin_id   = "ALBOrigin"
#     custom_origin_config {
#       http_port              = 80
#       https_port             = 443
#       origin_protocol_policy = "http-only"
#       origin_ssl_protocols   = ["TLSv1.2"]
#     }
#   }
#   enabled             = true
#   is_ipv6_enabled     = true
#   default_root_object = ""
#   aliases             = ["disaster.derherzen.com"]
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
#   restrictions {
#     geo_restriction {
#       restriction_type = "none"
#     }
#   }
#   viewer_certificate {
#     acm_certificate_arn = data.aws_acm_certificate.disaster.arn
#     ssl_support_method  = "sni-only"
#   }
#   web_acl_id = aws_wafv2_web_acl.cloudpulse.arn
#   tags       = { Name = "${var.project_name}-cf" }
# }

# # ============================================================
# # DR Components
# # ============================================================

# resource "aws_route53_health_check" "primary" {
#   fqdn              = aws_lb.cloudpulse.dns_name
#   port              = 80
#   type              = "HTTP"
#   resource_path     = "/"
#   failure_threshold = 3
#   request_interval  = 30
# }

# resource "aws_sns_topic" "dr_trigger" {
#   name = "${var.project_name}-dr-trigger"
# }

# resource "aws_cloudwatch_metric_alarm" "dr_failover" {
#   alarm_name          = "${var.project_name}-dr-failover"
#   comparison_operator = "LessThanThreshold"
#   evaluation_periods  = "1"
#   metric_name         = "HealthCheckStatus"
#   namespace           = "AWS/Route53"
#   period              = "60"
#   statistic           = "Minimum"
#   threshold           = "1"
#   alarm_description   = "Trigger DR failover"
#   alarm_actions       = [aws_sns_topic.dr_trigger.arn]
#   dimensions = {
#     HealthCheckId = aws_route53_health_check.primary.id
#   }
# }

# resource "aws_iam_role" "lambda_exec" {
#   name = "${var.project_name}-lambda-exec"
#   assume_role_policy = jsonencode({
#     Version = "2012-10-17"
#     Statement = [{
#       Action = "sts:AssumeRole"
#       Principal = {
#         Service = "lambda.amazonaws.com"
#       }
#       Effect = "Allow"
#     }]
#   })
# }

# resource "aws_iam_role_policy" "lambda_exec" {
#   name = "${var.project_name}-lambda-policy"
#   role = aws_iam_role.lambda_exec.id
#   policy = jsonencode({
#     Version = "2012-10-17"
#     Statement = [
#       {
#         Action = "autoscaling:UpdateAutoScalingGroup"
#         Effect = "Allow"
#         Resource = "*"
#       },
#       {
#         Action = "logs:CreateLogGroup"
#         Effect = "Allow"
#         Resource = "arn:aws:logs:eu-west-3:*:*"
#       },
#       {
#         Action = "logs:CreateLogStream"
#         Effect = "Allow"
#         Resource = "arn:aws:logs:eu-west-3:*:log-group:/aws/lambda/*:*"
#       },
#       {
#         Action = "logs:PutLogEvents"
#         Effect = "Allow"
#         Resource = "arn:aws:logs:eu-west-3:*:log-group:/aws/lambda/*:*:*"
#       }
#     ]
#   })
# }

# data "archive_file" "lambda_zip" {
#   type        = "zip"
#   output_path = "${path.module}/lambda.zip"
#   source {
#     content  = <<EOF
# import boto3

# def lambda_handler(event, context):
#     client = boto3.client('autoscaling', region_name='eu-west-3')
#     client.update_auto_scaling_group(
#         AutoScalingGroupName='${var.project_name}-asg',
#         MinSize=2,
#         DesiredCapacity=2
#     )
#     return {
#         'statusCode': 200,
#         'body': 'DR activated'
#     }
# EOF
#     filename = "index.py"
#   }
# }

# resource "aws_lambda_function" "dr_scale_up" {
#   provider         = aws.secondary
#   function_name    = "${var.project_name}-dr-scale-up"
#   runtime          = "python3.9"
#   handler          = "index.lambda_handler"
#   role             = aws_iam_role.lambda_exec.arn
#   filename         = data.archive_file.lambda_zip.output_path
#   source_code_hash = data.archive_file.lambda_zip.output_base64sha256
# }

# resource "aws_sns_topic_subscription" "dr_lambda" {
#   topic_arn = aws_sns_topic.dr_trigger.arn
#   protocol  = "lambda"
#   endpoint  = aws_lambda_function.dr_scale_up.arn
# }

# resource "aws_lambda_permission" "sns_invoke" {
#   provider      = aws.secondary
#   statement_id  = "AllowExecutionFromSNS"
#   action        = "lambda:InvokeFunction"
#   function_name = aws_lambda_function.dr_scale_up.function_name
#   principal     = "sns.amazonaws.com"
#   source_arn    = aws_sns_topic.dr_trigger.arn
# }

# # ============================================================
# # Outputs
# # ============================================================

# output "cloudfront_domain_name" {
#   description = "CloudFront distribution domain name"
#   value       = aws_cloudfront_distribution.cloudpulse.domain_name
# }