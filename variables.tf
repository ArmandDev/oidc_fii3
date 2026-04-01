variable "aws_region" {
  description = "AWS region for the default provider (Session 3 / main.tf stack). For CI, align GitHub secret AWS_REGION with this when possible."
  type        = string
  default     = "eu-west-2"
}

variable "project_name" {
  description = "Name prefix for DR stack (dr.tf): tags, IAM, ASG, etc. Session 3 (main.tf) uses var.main_stack_name instead so resources do not clash."
  type        = string
  default     = "cloudpulse"
}

variable "main_stack_name" {
  description = "Name prefix for Session 3 only (main.tf): VPC/SG/IAM/EC2 tags and names. Separate from var.project_name so main and DR never share the same AWS resource names."
  type        = string
  default     = "cloudpulse-session3"
}

variable "main_s3_bucket_prefix" {
  description = "S3 bucket name prefix for main.tf only; suffix is account ID and region (same pattern as DR’s var.s3_bucket_prefix)."
  type        = string
  default     = "cloudpulse-session3-assets"
}

variable "main_dynamodb_table_name" {
  description = "DynamoDB table name for the Session 3 app (main.tf). Distinct from var.dynamodb_table_name used when DR resources are enabled."
  type        = string
  default     = "CloudPulseCounterSession3"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/24"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet"
  type        = string
  default     = "10.0.0.0/26"
}

variable "s3_bucket_prefix" {
  description = "S3 bucket name prefix for DR stack (dr.tf) when those resources are enabled; main.tf uses var.main_s3_bucket_prefix."
  type        = string
  default     = "cloudpulse-assets"
}

variable "background_image_path" {
  description = "Local path to the background image"
  type        = string
  default     = "background.jpeg"
}

variable "background_image_key" {
  description = "S3 object key for the background image"
  type        = string
  default     = "background.jpeg"
}

variable "dynamodb_table_name" {
  description = "DynamoDB table name for DR stack (dr.tf) when enabled; main.tf uses var.main_dynamodb_table_name."
  type        = string
  default     = "CloudPulseCounter"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.micro"
}

variable "allowed_ssh_cidrs" {
  description = "CIDR blocks allowed to SSH into instances"
  type        = list(string)
  default     = ["0.0.0.0/0"] # Change to your IP for security
}

variable "common_tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default = {
    ManagedBy = "terraform"
    Project   = "cloudpulse"
  }
}

# --- Disaster recovery (dr.tf) ---

variable "dr_vpc_cidr" {
  description = "CIDR for the DR (secondary region) VPC; must not overlap routing intent with primary VPC if you ever peer (here regions differ so overlap is OK)."
  type        = string
  default     = "10.1.0.0/24"
}

variable "cloudfront_aliases_dr" {
  description = "CloudFront CNAMEs for the DR scenario (e.g. disaster.derherzen.com). Use [] for default *.cloudfront.net only."
  type        = list(string)
  default     = ["disaster.derherzen.com"]
}

variable "dr_standby_desired_capacity" {
  description = "Cold DR site: keep at 0 to save cost; set to 1+ to warm standby manually via Terraform."
  type        = number
  default     = 0
}

variable "dr_lambda_scale_min_size" {
  description = "When failover/Capacity Lambda runs, set DR ASG MinSize to this value (match primary capacity for parity)."
  type        = number
  default     = 2
}

variable "dr_lambda_scale_desired_capacity" {
  description = "When failover/Capacity Lambda runs, set DR ASG DesiredCapacity to this value."
  type        = number
  default     = 2
}

variable "dr_route53_automatic_failover" {
  description = <<-EOT
    When true, CloudWatch alarm on the primary ASG GroupInServiceInstances (ALARM when 0) publishes to SNS (in var.aws_region),
    which invokes the DR Lambda to scale the secondary ASG. (Name is historical; Route 53 HTTP checks are not used for internal ALBs.)
    Set false to use only manual triggers (Terraform capacity, SNS publish, or Lambda invoke).
  EOT
  type        = bool
  default     = true
}