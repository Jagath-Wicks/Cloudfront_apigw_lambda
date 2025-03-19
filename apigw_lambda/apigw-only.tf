
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

output "api_url" {
  value = "${aws_api_gateway_deployment.html_deployment.invoke_url}prod/html"
}
