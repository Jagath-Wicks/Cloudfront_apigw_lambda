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

resource "aws_lambda_permission" "apigw_lambda" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.html_lambda.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.html_api.execution_arn}/*/*"
}

// Create Lambda deployment
// SSM for store the text
resource "aws_ssm_parameter" "dynamic_string" {
  name  = "/dynamic_string"
  type  = "String"
  value = "Initial Dynamic String"
}

resource "aws_iam_role" "lambda_exec" {
  name = "lambda_exec_role"
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource "aws_iam_policy_attachment" "lambda_ssm_policy" {
  name       = "lambda-ssm-policy"
  roles      = [aws_iam_role.lambda_exec.name]
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMReadOnlyAccess"
}

resource "aws_lambda_function" "html_lambda" {
  function_name    = "html_lambda"
  runtime         = "python3.9"
  handler         = "lambda_function.lambda_handler"
  role            = aws_iam_role.lambda_exec.arn
  filename        = "lambda.zip"  
  source_code_hash = filebase64sha256("lambda.zip")
  
  environment {
    variables = {
      PARAM_NAME = "/dynamic_string"
    }
  }
}
// End  Lambda deployment



// Create APIGW

resource "aws_api_gateway_resource" "proxy" {
  rest_api_id = aws_api_gateway_rest_api.html_api.id
  parent_id   = aws_api_gateway_rest_api.html_api.root_resource_id
  path_part   = "html"
}

resource "aws_api_gateway_method" "get_html" {
  rest_api_id   = aws_api_gateway_rest_api.html_api.id
  resource_id   = aws_api_gateway_resource.proxy.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "lambda_integration" {
  rest_api_id = aws_api_gateway_rest_api.html_api.id
  resource_id = aws_api_gateway_resource.proxy.id
  http_method = aws_api_gateway_method.get_html.http_method
  integration_http_method = "POST"
  type = "AWS_PROXY"
  uri = aws_lambda_function.html_lambda.invoke_arn
}

resource "aws_api_gateway_rest_api" "html_api" {
  name        = "HTML API"
  description = "API to serve dynamic HTML page"
}

resource "aws_api_gateway_stage" "html_stage" {
  stage_name    = "prod"
  rest_api_id   = aws_api_gateway_rest_api.html_api.id
  deployment_id = aws_api_gateway_deployment.html_deployment.id
}

resource "aws_api_gateway_deployment" "html_deployment" {
  rest_api_id = aws_api_gateway_rest_api.html_api.id

  triggers = {
    redeployment = timestamp()
  }

  lifecycle {
    create_before_destroy = true
  }
}

# APIGW  WAF WebACL Association
resource "aws_wafv2_web_acl_association" "waf_apigw_association" {
  resource_arn = aws_api_gateway_stage.html_stage.arn 
  web_acl_arn  = aws_wafv2_web_acl.apigw_waf.arn
}
// End APIGW



// CloudFront

# Create  CloudFront Distribution
resource "aws_cloudfront_distribution" "example_cf" {
  origin {
    domain_name = "${aws_api_gateway_rest_api.html_api.id}.execute-api.${var.aws_region}.amazonaws.com"
    origin_id   = "APIGatewayOrigin"

    #  CloudFront  connects to API Gateway
    origin_path = "/prod" # Matches API Gateway deployment stage

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
    
    custom_header {
      name  = "x-cloudfront-secret"
      value = random_string.cloudfront_secret.result
    }

  }

  enabled = true
  default_root_object = ""

  // web_acl_id = aws_wafv2_web_acl.cloudfront.arn
  // web_acl_id = aws_wafv2_web_acl.cloudfront.arn
   web_acl_id = aws_wafv2_web_acl.waf.arn

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD", "OPTIONS", "PUT", "PATCH", "POST", "DELETE"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "APIGatewayOrigin"

    viewer_protocol_policy = "redirect-to-https"

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }
}
// End CloudFront


// WAF APiGW

# AWS WAF WebACL - To make sure APIGW acces is only allowd via CloudFront - Uses a secret pass from CloudFront
resource "aws_wafv2_web_acl" "apigw_waf" {
  name        = "apigw-cloudfront-waf"
  scope       = "REGIONAL"  
  description = "WAF to allow only CloudFront requests with a secret header"

  default_action {
    block {}
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "apigw-waf-metrics"
    sampled_requests_enabled   = true
  }

  # Allow requests with the correct CloudFront secret header
  rule {
    name     = "allow-cloudfront-header"
    priority = 1

    action {
      allow {}
    }

    statement {
      byte_match_statement {
        field_to_match {
          single_header {
            name = "x-cloudfront-secret"
          }
        }

        positional_constraint = "EXACTLY"
        search_string         = random_string.cloudfront_secret.result

        text_transformation {
          priority = 1
          type     = "NONE"
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "allow-cloudfront-header"
      sampled_requests_enabled   = true
    }
  }
}
// WAF APiGW End


// WAF Cloudfront - rate-limit-rule To prevent DDOS attck  
resource "aws_wafv2_web_acl" "waf" {
  name        = "my-waf"
  scope       = "CLOUDFRONT" 
  description = "WAF with rate limit rule"

  default_action {
    allow {}
  }

  rule {
    name     = "rate-limit-rule"
    priority = 1

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = 100 
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rate-limit-rule"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "my-waf"
    sampled_requests_enabled   = true
  }
}

// End WAF CloudFront 

// Outputs
output "cloudfront_distribution_domain_name" {
  value = "${aws_cloudfront_distribution.example_cf.domain_name}/html"
  description = "The CloudFront Distribution Domain Name"
}

output "cloudfront_distribution_id" {
  value = aws_cloudfront_distribution.example_cf.id
  description = "The CloudFront Distribution ID"
}

output "api_url" {
  value = "${aws_api_gateway_deployment.html_deployment.invoke_url}prod/html"
}
// End Outputs
