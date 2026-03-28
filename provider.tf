terraform {
  backend "s3" {
    bucket  = "kdsjhfhdsohgiodshg6548"
    key     = "terraform.tfstate"
    region  = "eu-north-1"
    encrypt = true
  }
}