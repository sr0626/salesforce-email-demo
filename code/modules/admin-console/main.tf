terraform {
  required_providers {
    random = { source = "hashicorp/random" }
  }
}

locals {
  use_cmk = var.kms_key_arn != ""
  # Auto-generate a token when none is pinned, so the console is never left open.
  token = var.admin_token != "" ? var.admin_token : random_password.token.result
}

resource "random_password" "token" {
  length  = 32
  special = false
}

data "archive_file" "lambda" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/build/admin.zip"
  excludes    = ["__pycache__"]
}

resource "aws_iam_role" "lambda" {
  name = "${var.lambda_function_name}-execution-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "access" {
  name = "AdminConsoleAccess"
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Sid    = "RulesAndTemplatesCRUD"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem",
          "dynamodb:Scan", "dynamodb:Query",
        ]
        Resource = [var.routing_rules_table_arn, var.email_templates_table_arn]
      },
      ], local.use_cmk ? [{
        Sid      = "UseCustomerKey"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
        Resource = var.kms_key_arn
      }] : [],
      var.qr_knowledge_base_arn != "" ? [{
        # Publish templates as quick responses into the instance's QUICK_RESPONSES KB.
        # Amazon Q in Connect still uses the wisdom: IAM namespace (some accounts also
        # expose qconnect:) — grant both to be safe. Covers the KB + its quick-responses.
        Sid    = "PublishQuickResponses"
        Effect = "Allow"
        Action = [
          "wisdom:CreateQuickResponse", "wisdom:UpdateQuickResponse",
          "wisdom:SearchQuickResponses", "wisdom:GetQuickResponse",
          "qconnect:CreateQuickResponse", "qconnect:UpdateQuickResponse",
          "qconnect:SearchQuickResponses", "qconnect:GetQuickResponse",
        ]
        # Create/Search act on the KB; Get/Update act on the quick-response sub-resource,
        # which is a SEPARATE ARN path (…:quick-response/<kb>/*, not knowledge-base/<kb>/*).
        Resource = [
          var.qr_knowledge_base_arn,
          "${var.qr_knowledge_base_arn}/*",
          "${replace(var.qr_knowledge_base_arn, ":knowledge-base/", ":quick-response/")}/*",
        ]
    }] : [])
  })
}

resource "aws_lambda_function" "admin" {
  function_name    = var.lambda_function_name
  runtime          = var.lambda_runtime
  handler          = "index.handler"
  role             = aws_iam_role.lambda.arn
  timeout          = 15
  memory_size      = 256
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  kms_key_arn      = local.use_cmk ? var.kms_key_arn : null

  environment {
    variables = {
      ROUTING_RULES_TABLE   = var.routing_rules_table_name
      EMAIL_TEMPLATES_TABLE = var.email_templates_table_name
      ADMIN_TOKEN           = local.token
      OWNER_NAME_MAP        = jsonencode(var.owner_name_map)
      QR_KNOWLEDGE_BASE_ID  = var.qr_knowledge_base_id
    }
  }
}

# Function URL — the console (HTML + JSON API) is served straight from the Lambda.
# authorization_type NONE: the HTML shell is public, but every /api/* call requires
# the bearer token (checked in-code), so rules/templates can't be read or changed
# without it. Swap to AWS_IAM + SigV4, or front with Cognito, for production auth.
resource "aws_lambda_function_url" "admin" {
  function_name      = aws_lambda_function.admin.function_name
  authorization_type = "NONE"
}
