provider "aws" {
  region = "us-east-1"  
}

variable "aws_region" {
   type  = string
   default = "us-east-1"
}

#  secret key for CloudFront authentication
resource "random_string" "cloudfront_secret" {
  length  = 16
  special = false
  upper   = false
}

data "aws_region" "current" {}
