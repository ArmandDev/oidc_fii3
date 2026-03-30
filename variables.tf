variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "eu-north-1"
}

variable "project_name" {
  description = "Project name used for tagging and naming"
  type        = string
  default     = "cloudpulse"
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
  description = "Prefix for the S3 bucket (account ID + region + -an appended automatically)"
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
  description = "Name of the DynamoDB table"
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