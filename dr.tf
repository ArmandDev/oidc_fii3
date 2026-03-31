# ============================================================
# CloudPulse — Disaster recovery (student lab)
#
# Use ONLY with other scenario files commented out (data_encryption, HA, main).
# Requires: provider.tf, certificate.tf (ACM in us-east-1), variables.tf, app.py.tftpl
#
# Pattern (same edge style as high_availability / data_encryption):
#   • Primary + DR: 2 public + 2 private AZs, NAT, internal ALB in private subnets
#   • ALB ingress: CloudFront managed prefix list only; listener 403 + header rule → targets
#   • CloudFront: VPC origins + shared X-CloudPulse-Origin-Verify header; origin failover group
#   • Global data: S3 CRR + DynamoDB replica (MRK per replica region)
#   • Automatic capacity: CloudWatch ALB HealthyHostCount (primary) → SNS → Lambda scales DR ASG
#     (Route 53 HTTP checks cannot reach internal ALBs, so no R53 health check here.)
#   • Manual: Terraform var dr_standby_desired_capacity, or SNS publish, or aws lambda invoke
# ============================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "aws_region" "secondary" {
  provider = aws.secondary
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_availability_zones" "secondary" {
  provider = aws.secondary
  state    = "available"
}

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_ami" "amazon_linux_secondary" {
  provider    = aws.secondary
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_acm_certificate" "disaster" {
  provider = aws.us-east-1
  domain   = "disaster.derherzen.com"
  statuses = ["ISSUED"]
}

data "aws_ec2_managed_prefix_list" "cloudfront_origin" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "random_password" "cloudfront_origin_secret" {
  length  = 48
  special = false
}

# ---------------------------------------------------------------------------
# KMS: multi-Region primary + replica for DynamoDB global replica requirement
# ---------------------------------------------------------------------------

resource "aws_kms_key" "cloudpulse" {
  description  = "CloudPulse MRK primary (DR stack)"
  multi_region = true
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "Enable IAM User Permissions"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "Allow EC2 and Auto Scaling use of the key"
        Effect    = "Allow"
        Principal = { Service = ["ec2.amazonaws.com", "autoscaling.amazonaws.com"] }
        Action = [
          "kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*",
          "kms:DescribeKey", "kms:CreateGrant"
        ]
        Resource = "*"
      },
      {
        Sid       = "Allow AWS Auto Scaling service-linked role use of the key"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling" }
        Action = [
          "kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
      },
      {
        Sid       = "Allow attachment of persistent resources"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling" }
        Action    = "kms:CreateGrant"
        Resource  = "*"
        Condition = { Bool = { "kms:GrantIsForAWSResource" = true } }
      }
    ]
  })
  tags = { Name = "${var.project_name}-kms" }
}

resource "aws_kms_replica_key" "cloudpulse_secondary" {
  provider        = aws.secondary
  primary_key_arn = aws_kms_key.cloudpulse.arn
  description     = "CloudPulse MRK replica for ${data.aws_region.secondary.name}"
  tags            = { Name = "${var.project_name}-kms-secondary" }
}

# ---------------------------------------------------------------------------
# PRIMARY region — network (matches HA-style layout)
# ---------------------------------------------------------------------------

resource "aws_vpc" "cloudpulse" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.project_name}-vpc" }
}

resource "aws_internet_gateway" "cloudpulse" {
  vpc_id = aws_vpc.cloudpulse.id
  tags   = { Name = "${var.project_name}-igw" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.cloudpulse.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 2, 0)
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.project_name}-public-subnet" }
}

resource "aws_subnet" "public2" {
  vpc_id                  = aws_vpc.cloudpulse.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 2, 1)
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.project_name}-public-subnet2" }
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.project_name}-nat-eip" }
}

resource "aws_nat_gateway" "cloudpulse" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id
  tags          = { Name = "${var.project_name}-nat" }
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.cloudpulse.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 2, 2)
  availability_zone = data.aws_availability_zones.available.names[0]
  tags              = { Name = "${var.project_name}-private-subnet" }
}

resource "aws_subnet" "private2" {
  vpc_id            = aws_vpc.cloudpulse.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 2, 3)
  availability_zone = data.aws_availability_zones.available.names[1]
  tags              = { Name = "${var.project_name}-private-subnet2" }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.cloudpulse.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.cloudpulse.id
  }
  tags = { Name = "${var.project_name}-private-rt" }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private2" {
  subnet_id      = aws_subnet.private2.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.cloudpulse.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.cloudpulse.id
  }
  tags = { Name = "${var.project_name}-public-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public2" {
  subnet_id      = aws_subnet.public2.id
  route_table_id = aws_route_table.public.id
}

# ---------------------------------------------------------------------------
# DR region — same layout as primary (public + private + NAT)
# ---------------------------------------------------------------------------

resource "aws_vpc" "cloudpulse_dr" {
  provider             = aws.secondary
  cidr_block           = var.dr_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.project_name}-vpc-dr" }
}

resource "aws_internet_gateway" "cloudpulse_dr" {
  provider = aws.secondary
  vpc_id   = aws_vpc.cloudpulse_dr.id
  tags     = { Name = "${var.project_name}-igw-dr" }
}

resource "aws_subnet" "dr_public" {
  provider                = aws.secondary
  vpc_id                  = aws_vpc.cloudpulse_dr.id
  cidr_block              = cidrsubnet(var.dr_vpc_cidr, 2, 0)
  availability_zone       = data.aws_availability_zones.secondary.names[0]
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.project_name}-public-dr-a" }
}

resource "aws_subnet" "dr_public2" {
  provider                = aws.secondary
  vpc_id                  = aws_vpc.cloudpulse_dr.id
  cidr_block              = cidrsubnet(var.dr_vpc_cidr, 2, 1)
  availability_zone       = data.aws_availability_zones.secondary.names[1]
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.project_name}-public-dr-b" }
}

resource "aws_eip" "nat_dr" {
  provider = aws.secondary
  domain   = "vpc"
  tags     = { Name = "${var.project_name}-nat-eip-dr" }
}

resource "aws_nat_gateway" "cloudpulse_dr" {
  provider      = aws.secondary
  allocation_id = aws_eip.nat_dr.id
  subnet_id     = aws_subnet.dr_public.id
  tags          = { Name = "${var.project_name}-nat-dr" }
}

resource "aws_subnet" "dr_private" {
  provider          = aws.secondary
  vpc_id            = aws_vpc.cloudpulse_dr.id
  cidr_block        = cidrsubnet(var.dr_vpc_cidr, 2, 2)
  availability_zone = data.aws_availability_zones.secondary.names[0]
  tags              = { Name = "${var.project_name}-private-dr-a" }
}

resource "aws_subnet" "dr_private2" {
  provider          = aws.secondary
  vpc_id            = aws_vpc.cloudpulse_dr.id
  cidr_block        = cidrsubnet(var.dr_vpc_cidr, 2, 3)
  availability_zone = data.aws_availability_zones.secondary.names[1]
  tags              = { Name = "${var.project_name}-private-dr-b" }
}

resource "aws_route_table" "dr_private" {
  provider = aws.secondary
  vpc_id   = aws_vpc.cloudpulse_dr.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.cloudpulse_dr.id
  }
  tags = { Name = "${var.project_name}-private-rt-dr" }
}

resource "aws_route_table_association" "dr_private" {
  provider       = aws.secondary
  subnet_id      = aws_subnet.dr_private.id
  route_table_id = aws_route_table.dr_private.id
}

resource "aws_route_table_association" "dr_private2" {
  provider       = aws.secondary
  subnet_id      = aws_subnet.dr_private2.id
  route_table_id = aws_route_table.dr_private.id
}

resource "aws_route_table" "dr_public" {
  provider = aws.secondary
  vpc_id   = aws_vpc.cloudpulse_dr.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.cloudpulse_dr.id
  }
  tags = { Name = "${var.project_name}-public-rt-dr" }
}

resource "aws_route_table_association" "dr_public" {
  provider       = aws.secondary
  subnet_id      = aws_subnet.dr_public.id
  route_table_id = aws_route_table.dr_public.id
}

resource "aws_route_table_association" "dr_public2" {
  provider       = aws.secondary
  subnet_id      = aws_subnet.dr_public2.id
  route_table_id = aws_route_table.dr_public.id
}

# ---------------------------------------------------------------------------
# Security groups
# ---------------------------------------------------------------------------

resource "aws_security_group" "alb_sg" {
  name        = "${var.project_name}-alb-sg"
  description = "Internal ALB - HTTP from CloudFront (prefix list, VPC Origin)"
  vpc_id      = aws_vpc.cloudpulse.id

  ingress {
    description     = "HTTP from CloudFront"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront_origin.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.project_name}-alb-sg" }
}

resource "aws_security_group" "cloudpulse_sg" {
  name        = "${var.project_name}-sg"
  description = "Primary app - from ALB, SSH"
  vpc_id      = aws_vpc.cloudpulse.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh_cidrs
  }
  ingress {
    description     = "App from ALB"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }
  ingress {
    description = "Grafana / Apps (lab)"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "Internal cluster ports"
    from_port   = 3000
    to_port     = 9999
    protocol    = "tcp"
    self        = true
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.project_name}-sg" }
}

resource "aws_security_group" "alb_sg_dr" {
  provider    = aws.secondary
  name        = "${var.project_name}-alb-sg-dr"
  description = "Internal DR ALB - HTTP from CloudFront (prefix list, VPC Origin)"
  vpc_id      = aws_vpc.cloudpulse_dr.id

  ingress {
    description     = "HTTP from CloudFront"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront_origin.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.project_name}-alb-sg-dr" }
}

resource "aws_security_group" "cloudpulse_sg_dr" {
  provider    = aws.secondary
  name        = "${var.project_name}-sg-dr"
  description = "DR app - from ALB, SSH"
  vpc_id      = aws_vpc.cloudpulse_dr.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh_cidrs
  }
  ingress {
    description     = "App from ALB"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg_dr.id]
  }
  ingress {
    description = "Internal cluster ports"
    from_port   = 3000
    to_port     = 9999
    protocol    = "tcp"
    self        = true
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.project_name}-sg-dr" }
}

# ---------------------------------------------------------------------------
# S3 + CRR
# ---------------------------------------------------------------------------

resource "aws_iam_role" "s3_replication" {
  name = "${var.project_name}-s3-replication-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Principal = { Service = "s3.amazonaws.com" }
      Effect    = "Allow"
    }]
  })
}

resource "aws_iam_role_policy" "s3_replication" {
  name = "${var.project_name}-s3-replication-policy"
  role = aws_iam_role.s3_replication.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = ["s3:GetReplicationConfiguration", "s3:ListBucket"]
        Effect   = "Allow"
        Resource = aws_s3_bucket.cloudpulse.arn
      },
      {
        Action = [
          "s3:GetObjectVersion",
          "s3:GetObjectVersionAcl",
          "s3:GetObjectVersionTagging"
        ]
        Effect   = "Allow"
        Resource = "${aws_s3_bucket.cloudpulse.arn}/*"
      },
      {
        Action   = ["s3:ReplicateObject", "s3:ReplicateDelete", "s3:ReplicateTags"]
        Effect   = "Allow"
        Resource = "${aws_s3_bucket.cloudpulse_secondary.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = aws_kms_key.cloudpulse.arn
      }
    ]
  })
}

resource "aws_s3_bucket" "cloudpulse" {
  bucket = "${var.s3_bucket_prefix}-${data.aws_caller_identity.current.account_id}-${data.aws_region.current.name}"
  tags   = { Name = "${var.project_name}-assets" }
}

resource "aws_s3_bucket" "cloudpulse_secondary" {
  provider = aws.secondary
  bucket   = "${var.s3_bucket_prefix}-${data.aws_caller_identity.current.account_id}-eu-west-3"
  tags     = { Name = "${var.project_name}-assets-secondary" }
}

resource "aws_s3_bucket_versioning" "cloudpulse" {
  bucket = aws_s3_bucket.cloudpulse.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_versioning" "cloudpulse_secondary" {
  provider = aws.secondary
  bucket   = aws_s3_bucket.cloudpulse_secondary.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_replication_configuration" "cloudpulse" {
  role   = aws_iam_role.s3_replication.arn
  bucket = aws_s3_bucket.cloudpulse.id
  rule {
    id     = "CRR"
    status = "Enabled"
    filter {}
    delete_marker_replication { status = "Disabled" }
    destination {
      bucket        = aws_s3_bucket.cloudpulse_secondary.arn
      storage_class = "STANDARD"
    }
  }
  depends_on = [
    aws_s3_bucket_versioning.cloudpulse,
    aws_s3_bucket_versioning.cloudpulse_secondary
  ]
}

resource "aws_s3_object" "background" {
  bucket                 = aws_s3_bucket.cloudpulse.id
  key                    = var.background_image_key
  source                 = var.background_image_path
  content_type           = "image/jpeg"
  server_side_encryption = "aws:kms"
  kms_key_id             = aws_kms_key.cloudpulse.arn
  depends_on             = [aws_s3_bucket_replication_configuration.cloudpulse]
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudpulse" {
  bucket = aws_s3_bucket.cloudpulse.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.cloudpulse.arn
    }
  }
}

resource "aws_s3_bucket_policy" "cloudpulse_encryption_enforce" {
  bucket = aws_s3_bucket.cloudpulse.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyUnencryptedObjectUploads"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:PutObject"
      Resource  = "${aws_s3_bucket.cloudpulse.arn}/*"
      Condition = {
        StringNotEquals = { "s3:x-amz-server-side-encryption" = "aws:kms" }
      }
    }]
  })
}

# ---------------------------------------------------------------------------
# DynamoDB global replica
# ---------------------------------------------------------------------------

resource "aws_dynamodb_table" "cloudpulse" {
  name         = var.dynamodb_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.cloudpulse.arn
  }

  replica {
    region_name = data.aws_region.secondary.name
    kms_key_arn = aws_kms_replica_key.cloudpulse_secondary.arn
  }

  tags = { Name = "${var.project_name}-counter" }
}

resource "aws_dynamodb_table_item" "visits" {
  table_name = aws_dynamodb_table.cloudpulse.name
  hash_key   = aws_dynamodb_table.cloudpulse.hash_key
  item       = <<ITEM
{
  "id": {"S": "visits"},
  "count": {"N": "0"}
}
ITEM
  lifecycle {
    ignore_changes = [item]
  }
}

# ---------------------------------------------------------------------------
# IAM — EC2 (shared by primary + DR launch templates)
# ---------------------------------------------------------------------------

resource "aws_iam_role" "cloudpulse_ec2" {
  name = "${var.project_name}-instance-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "cloudpulse_access" {
  name = "${var.project_name}-access-policy"
  role = aws_iam_role.cloudpulse_ec2.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.cloudpulse.arn,
          "${aws_s3_bucket.cloudpulse.arn}/*"
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:UpdateItem", "dynamodb:PutItem"]
        Resource = aws_dynamodb_table.cloudpulse.arn
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt", "kms:DescribeKey", "kms:GenerateDataKey",
          "kms:GenerateDataKeyWithoutPlaintext", "kms:CreateGrant", "kms:ReEncrypt*"
        ]
        Resource = [
          aws_kms_key.cloudpulse.arn,
          aws_kms_replica_key.cloudpulse_secondary.arn
        ]
      }
    ]
  })
}

resource "aws_iam_instance_profile" "cloudpulse" {
  name = "${var.project_name}-instance-profile"
  role = aws_iam_role.cloudpulse_ec2.name
}

resource "aws_launch_template" "cloudpulse" {
  name_prefix   = "${var.project_name}-lt-"
  image_id      = data.aws_ami.amazon_linux.id
  instance_type = var.instance_type

  vpc_security_group_ids = [aws_security_group.cloudpulse_sg.id]
  iam_instance_profile { name = aws_iam_instance_profile.cloudpulse.name }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      encrypted   = true
      kms_key_id  = aws_kms_key.cloudpulse.arn
      volume_type = "gp3"
      volume_size = 8
    }
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1
    yum update -y
    yum install -y python3-pip unzip
    pip3 install flask requests boto3 pytz prometheus-flask-exporter
    mkdir -p /home/ec2-user/app
    cat << 'PY_EOF' > /home/ec2-user/app/app.py
    ${templatefile("${path.module}/app.py.tftpl", {
    bucket_name = aws_s3_bucket.cloudpulse.bucket,
    table_name  = var.dynamodb_table_name,
    aws_region  = data.aws_region.current.name,
    image_key   = var.background_image_key
})}
    PY_EOF
    cat <<SVC_EOF > /etc/systemd/system/cloudpulse.service
    [Unit]
    Description=CloudPulse Flask App
    After=network.target
    [Service]
    User=root
    WorkingDirectory=/home/ec2-user/app
    ExecStart=/usr/bin/python3 /home/ec2-user/app/app.py
    StandardOutput=append:/home/ec2-user/app/app.log
    StandardError=append:/home/ec2-user/app/app.log
    Restart=always
    [Install]
    WantedBy=multi-user.target
    SVC_EOF
    systemctl daemon-reload
    systemctl enable cloudpulse
    systemctl start cloudpulse
    wget -q https://github.com/prometheus/node_exporter/releases/download/v1.7.0/node_exporter-1.7.0.linux-amd64.tar.gz
    tar xfz node_exporter-1.7.0.linux-amd64.tar.gz
    cp node_exporter-1.7.0.linux-amd64/node_exporter /usr/local/bin/
    cat <<NODE_EOF > /etc/systemd/system/node_exporter.service
    [Unit]
    Description=Node Exporter
    After=network.target
    [Service]
    User=ec2-user
    ExecStart=/usr/local/bin/node_exporter
    [Install]
    WantedBy=multi-user.target
    NODE_EOF
    systemctl enable node_exporter
    systemctl start node_exporter
  EOF
)

tag_specifications {
  resource_type = "instance"
  tags          = { Name = "${var.project_name}-server" }
}
}

resource "aws_launch_template" "cloudpulse_dr" {
  provider      = aws.secondary
  name_prefix   = "${var.project_name}-lt-dr-"
  image_id      = data.aws_ami.amazon_linux_secondary.id
  instance_type = var.instance_type

  vpc_security_group_ids = [aws_security_group.cloudpulse_sg_dr.id]
  iam_instance_profile { name = aws_iam_instance_profile.cloudpulse.name }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      encrypted   = true
      kms_key_id  = aws_kms_replica_key.cloudpulse_secondary.arn
      volume_type = "gp3"
      volume_size = 8
    }
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1
    yum update -y
    yum install -y python3-pip unzip
    pip3 install flask requests boto3 pytz prometheus-flask-exporter
    mkdir -p /home/ec2-user/app
    cat << 'PY_EOF' > /home/ec2-user/app/app.py
    ${templatefile("${path.module}/app.py.tftpl", {
    bucket_name = aws_s3_bucket.cloudpulse.bucket,
    table_name  = var.dynamodb_table_name,
    aws_region  = data.aws_region.secondary.name,
    image_key   = var.background_image_key
})}
    PY_EOF
    cat <<SVC_EOF > /etc/systemd/system/cloudpulse.service
    [Unit]
    Description=CloudPulse Flask App
    After=network.target
    [Service]
    User=root
    WorkingDirectory=/home/ec2-user/app
    ExecStart=/usr/bin/python3 /home/ec2-user/app/app.py
    StandardOutput=append:/home/ec2-user/app/app.log
    StandardError=append:/home/ec2-user/app/app.log
    Restart=always
    [Install]
    WantedBy=multi-user.target
    SVC_EOF
    systemctl daemon-reload
    systemctl enable cloudpulse
    systemctl start cloudpulse
    wget -q https://github.com/prometheus/node_exporter/releases/download/v1.7.0/node_exporter-1.7.0.linux-amd64.tar.gz
    tar xfz node_exporter-1.7.0.linux-amd64.tar.gz
    cp node_exporter-1.7.0.linux-amd64/node_exporter /usr/local/bin/
    cat <<NODE_EOF > /etc/systemd/system/node_exporter.service
    [Unit]
    Description=Node Exporter
    After=network.target
    [Service]
    User=ec2-user
    ExecStart=/usr/local/bin/node_exporter
    [Install]
    WantedBy=multi-user.target
    NODE_EOF
    systemctl enable node_exporter
    systemctl start node_exporter
  EOF
)

tag_specifications {
  resource_type = "instance"
  tags          = { Name = "${var.project_name}-server-dr" }
}
}

resource "aws_lb_target_group" "cloudpulse" {
  name_prefix = "drp-"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.cloudpulse.id
  lifecycle { create_before_destroy = true }
  health_check {
    path                = "/"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
  tags = { Name = "${var.project_name}-tg" }
}

resource "aws_lb_target_group" "cloudpulse_dr" {
  provider    = aws.secondary
  name_prefix = "drs-"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.cloudpulse_dr.id
  lifecycle { create_before_destroy = true }
  health_check {
    path                = "/"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
  tags = { Name = "${var.project_name}-tg-dr" }
}

resource "aws_lb" "cloudpulse" {
  name               = "${var.project_name}-alb"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = [aws_subnet.private.id, aws_subnet.private2.id]
  tags               = { Name = "${var.project_name}-alb" }
}

resource "aws_lb" "cloudpulse_dr" {
  provider           = aws.secondary
  name               = "${var.project_name}-alb-dr"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg_dr.id]
  subnets            = [aws_subnet.dr_private.id, aws_subnet.dr_private2.id]
  tags               = { Name = "${var.project_name}-alb-dr" }
}

resource "aws_lb_listener" "cloudpulse" {
  load_balancer_arn = aws_lb.cloudpulse.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Forbidden"
      status_code  = "403"
    }
  }
}

resource "aws_lb_listener_rule" "cloudpulse_cf_header" {
  listener_arn = aws_lb_listener.cloudpulse.arn
  priority     = 10
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.cloudpulse.arn
  }
  condition {
    http_header {
      http_header_name = "X-CloudPulse-Origin-Verify"
      values           = [random_password.cloudfront_origin_secret.result]
    }
  }
}

resource "aws_lb_listener" "cloudpulse_dr" {
  provider          = aws.secondary
  load_balancer_arn = aws_lb.cloudpulse_dr.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Forbidden"
      status_code  = "403"
    }
  }
}

resource "aws_lb_listener_rule" "cloudpulse_dr_cf_header" {
  provider     = aws.secondary
  listener_arn = aws_lb_listener.cloudpulse_dr.arn
  priority     = 10
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.cloudpulse_dr.arn
  }
  condition {
    http_header {
      http_header_name = "X-CloudPulse-Origin-Verify"
      values           = [random_password.cloudfront_origin_secret.result]
    }
  }
}

resource "aws_autoscaling_group" "cloudpulse" {
  name = "${var.project_name}-asg"
  launch_template {
    id      = aws_launch_template.cloudpulse.id
    version = "$Latest"
  }
  min_size            = 1
  max_size            = 3
  desired_capacity    = 1
  vpc_zone_identifier = [aws_subnet.private.id, aws_subnet.private2.id]
  target_group_arns   = [aws_lb_target_group.cloudpulse.arn]
  tag {
    key                 = "Name"
    value               = "${var.project_name}-server"
    propagate_at_launch = true
  }
}

resource "aws_autoscaling_group" "cloudpulse_dr" {
  provider = aws.secondary
  name     = "${var.project_name}-asg-dr"
  launch_template {
    id      = aws_launch_template.cloudpulse_dr.id
    version = "$Latest"
  }
  min_size            = var.dr_standby_desired_capacity > 0 ? 1 : 0
  max_size            = 3
  desired_capacity    = var.dr_standby_desired_capacity
  vpc_zone_identifier = [aws_subnet.dr_private.id, aws_subnet.dr_private2.id]
  target_group_arns   = [aws_lb_target_group.cloudpulse_dr.arn]
  tag {
    key                 = "Name"
    value               = "${var.project_name}-server-dr"
    propagate_at_launch = true
  }
}

resource "aws_sns_topic" "dr_failover" {
  name = "${var.project_name}-dr-failover"
}

resource "aws_cloudwatch_metric_alarm" "primary_health" {
  alarm_name          = "${var.project_name}-primary-unhealthy-hosts"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "HealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Average"
  threshold           = 1
  alarm_description   = "Primary internal ALB has fewer than 1 healthy target; SNS can invoke DR scale-up Lambda"
  alarm_actions       = [aws_sns_topic.dr_failover.arn]
  treat_missing_data  = "breaching"
  dimensions = {
    LoadBalancer = aws_lb.cloudpulse.arn_suffix
    TargetGroup  = aws_lb_target_group.cloudpulse.arn_suffix
  }
}

data "archive_file" "dr_scale_up" {
  type        = "zip"
  output_path = "${path.module}/dr_lambda_bundle.zip"
  source {
    content  = file("${path.module}/dr_lambda/index.py")
    filename = "index.py"
  }
}

resource "aws_iam_role" "lambda_dr" {
  name = "${var.project_name}-lambda-dr"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "lambda_dr" {
  name = "${var.project_name}-lambda-dr-policy"
  role = aws_iam_role.lambda_dr.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["autoscaling:UpdateAutoScalingGroup"]
        Resource = aws_autoscaling_group.cloudpulse_dr.arn
      },
      {
        Effect   = "Allow"
        Action   = ["autoscaling:DescribeAutoScalingGroups"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${data.aws_region.secondary.name}:${data.aws_caller_identity.current.account_id}:*"
      }
    ]
  })
}

resource "aws_lambda_function" "dr_scale_up" {
  provider         = aws.secondary
  function_name    = "${var.project_name}-dr-scale-up"
  runtime          = "python3.11"
  handler          = "index.lambda_handler"
  role             = aws_iam_role.lambda_dr.arn
  filename         = data.archive_file.dr_scale_up.output_path
  source_code_hash = data.archive_file.dr_scale_up.output_base64sha256
  environment {
    variables = {
      ASG_NAME         = aws_autoscaling_group.cloudpulse_dr.name
      DESIRED_CAPACITY = tostring(var.dr_lambda_scale_desired_capacity)
      MIN_SIZE         = tostring(var.dr_lambda_scale_min_size)
    }
  }
  tags = { Name = "${var.project_name}-dr-scale-up" }
}

resource "aws_sns_topic_subscription" "dr_lambda" {
  count      = var.dr_route53_automatic_failover ? 1 : 0
  topic_arn  = aws_sns_topic.dr_failover.arn
  protocol   = "lambda"
  endpoint   = aws_lambda_function.dr_scale_up.arn
  depends_on = [aws_lambda_permission.dr_sns[0]]
}

resource "aws_lambda_permission" "dr_sns" {
  count         = var.dr_route53_automatic_failover ? 1 : 0
  provider      = aws.secondary
  statement_id  = "AllowExecutionFromSNS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.dr_scale_up.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.dr_failover.arn
}

resource "aws_wafv2_web_acl" "cloudpulse" {
  provider    = aws.us-east-1
  name        = "${var.project_name}-waf-dr"
  description = "WAF for CloudPulse DR lab"
  scope       = "CLOUDFRONT"
  default_action {
    allow {}
  }
  rule {
    name     = "SQLInjection"
    priority = 1
    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesSQLiRuleSet"
      }
    }
    override_action {
      none {}
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "SQLiDR"
      sampled_requests_enabled   = true
    }
  }
  rule {
    name     = "RateLimit"
    priority = 2
    statement {
      rate_based_statement {
        limit = 1000
      }
    }
    action {
      block {}
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "RateDR"
      sampled_requests_enabled   = true
    }
  }
  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "CloudPulseDRWAF"
    sampled_requests_enabled   = true
  }
}

resource "aws_cloudfront_vpc_origin" "cloudpulse" {
  vpc_origin_endpoint_config {
    name                   = "${var.project_name}-alb-vpc-origin"
    arn                    = aws_lb.cloudpulse.arn
    http_port              = 80
    https_port             = 443
    origin_protocol_policy = "http-only"
    origin_ssl_protocols {
      items    = ["TLSv1.2"]
      quantity = 1
    }
  }
}

resource "aws_cloudfront_vpc_origin" "cloudpulse_dr" {
  vpc_origin_endpoint_config {
    name                   = "${var.project_name}-alb-dr-vpc-origin"
    arn                    = aws_lb.cloudpulse_dr.arn
    http_port              = 80
    https_port             = 443
    origin_protocol_policy = "http-only"
    origin_ssl_protocols {
      items    = ["TLSv1.2"]
      quantity = 1
    }
  }
}

resource "aws_cloudfront_distribution" "cloudpulse" {
  origin {
    domain_name = aws_lb.cloudpulse.dns_name
    origin_id   = "primary-alb"
    custom_header {
      name  = "X-CloudPulse-Origin-Verify"
      value = random_password.cloudfront_origin_secret.result
    }
    vpc_origin_config {
      vpc_origin_id = aws_cloudfront_vpc_origin.cloudpulse.id
    }
  }
  origin {
    domain_name = aws_lb.cloudpulse_dr.dns_name
    origin_id   = "dr-alb"
    custom_header {
      name  = "X-CloudPulse-Origin-Verify"
      value = random_password.cloudfront_origin_secret.result
    }
    vpc_origin_config {
      vpc_origin_id = aws_cloudfront_vpc_origin.cloudpulse_dr.id
    }
  }

  origin_group {
    origin_id = "app-failover"
    failover_criteria {
      status_codes = [403, 404, 500, 502, 503, 504]
    }
    member { origin_id = "primary-alb" }
    member { origin_id = "dr-alb" }
  }

  depends_on = [
    aws_cloudfront_vpc_origin.cloudpulse,
    aws_cloudfront_vpc_origin.cloudpulse_dr
  ]

  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = ""
  aliases             = var.cloudfront_aliases_dr

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "app-failover"
    forwarded_values {
      query_string = true
      cookies { forward = "all" }
    }
    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 0
    max_ttl                = 0
  }

  ordered_cache_behavior {
    path_pattern     = "/background-image*"
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "app-failover"
    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }
    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 86400
    max_ttl                = 31536000
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  dynamic "viewer_certificate" {
    for_each = length(var.cloudfront_aliases_dr) > 0 ? [1] : []
    content {
      acm_certificate_arn      = data.aws_acm_certificate.disaster.arn
      ssl_support_method       = "sni-only"
      minimum_protocol_version = "TLSv1.2_2021"
    }
  }

  dynamic "viewer_certificate" {
    for_each = length(var.cloudfront_aliases_dr) == 0 ? [1] : []
    content {
      cloudfront_default_certificate = true
    }
  }

  web_acl_id = aws_wafv2_web_acl.cloudpulse.arn
  tags       = { Name = "${var.project_name}-cf-dr" }
}

# ---------------------------------------------------------------------------
# Outputs — URLs and failover commands for students
# ---------------------------------------------------------------------------

output "dr_cloudfront_domain_name" {
  description = "HTTPS URL host (append https://). Uses origin failover: primary ALB then DR ALB."
  value       = aws_cloudfront_distribution.cloudpulse.domain_name
}

output "dr_primary_alb_dns" {
  description = "Primary internal ALB DNS (reachable only via CloudFront VPC Origin / private network)."
  value       = aws_lb.cloudpulse.dns_name
}

output "dr_secondary_alb_dns" {
  description = "DR internal ALB DNS in aws.secondary (not internet-routable)."
  value       = aws_lb.cloudpulse_dr.dns_name
}

output "dr_primary_failover_alarm_name" {
  description = "CloudWatch alarm on primary ALB HealthyHostCount (triggers SNS in var.aws_region when unhealthy)."
  value       = aws_cloudwatch_metric_alarm.primary_health.alarm_name
}

output "dr_sns_topic_arn" {
  description = "SNS topic in var.aws_region; publishing invokes the DR Lambda when subscription is enabled."
  value       = aws_sns_topic.dr_failover.arn
}

output "dr_manual_failover_aws_cli" {
  description = "Manual capacity failover: publish to SNS (same path as automatic alarm)."
  value       = "aws sns publish --region ${data.aws_region.current.name} --topic-arn ${aws_sns_topic.dr_failover.arn} --message '{\"default\":\"manual-dr-failover\"}'"
}

output "dr_manual_lambda_invoke_cli" {
  description = "Manual failover: invoke the DR Lambda directly (scales the DR Auto Scaling group)."
  value       = "aws lambda invoke --region ${data.aws_region.secondary.name} --function-name ${aws_lambda_function.dr_scale_up.function_name} --payload '{}' dr_response.json"
}

output "dr_automatic_failover_note" {
  description = "How automatic failover is wired (for lab write-ups)."
  value       = "Primary internal ALB AWS/ApplicationELB HealthyHostCount alarm in ${data.aws_region.current.name} → SNS → Lambda in ${data.aws_region.secondary.name} scales DR ASG. CloudFront uses HA-style VPC origins + origin header, and origin group fails over on configured HTTP errors when DR has healthy targets. Toggle subscription with var.dr_route53_automatic_failover."
}
