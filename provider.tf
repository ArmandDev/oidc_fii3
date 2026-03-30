terraform {
  backend "s3" {
    bucket  = "oidcstate79874132464"
    key     = "terraform.tfstate"
    region  = "eu-north-1"
    encrypt = true
  }
}