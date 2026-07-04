locals {
  use_cmk = var.kms_key_arn != ""

  base_statements = [
    {
      Sid      = "ReadRawEmail"
      Effect   = "Allow"
      Action   = "s3:GetObject"
      Resource = "${var.inbound_bucket_arn}/*"
    },
    {
      Sid      = "OwnershipTableRW"
      Effect   = "Allow"
      Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:Query"]
      Resource = var.ownership_table_arn
    },
    {
      Sid      = "RoutingLogWrite"
      Effect   = "Allow"
      Action   = ["dynamodb:PutItem"]
      Resource = var.routing_log_table_arn
    },
    {
      Sid      = "SalesforceSecretRead"
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = var.salesforce_secret_arn
    },
    {
      Sid      = "StartConnectTask"
      Effect   = "Allow"
      Action   = "connect:StartTaskContact"
      Resource = "${var.connect_instance_arn}/*"
    },
  ]

  # When a CMK is in use, the Lambda needs to use it to decrypt the secret and
  # any KMS-encrypted S3 objects / DynamoDB items it reads.
  kms_statements = local.use_cmk ? [
    {
      Sid      = "UseCustomerKey"
      Effect   = "Allow"
      Action   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
      Resource = var.kms_key_arn
    },
  ] : []
}

data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/src/index.py"
  output_path = "${path.module}/build/index.zip"
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
  name = "EmailRoutingAccess"
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = concat(local.base_statements, local.kms_statements)
  })
}

resource "aws_lambda_function" "router" {
  function_name    = var.lambda_function_name
  runtime          = var.lambda_runtime
  handler          = "index.handler"
  role             = aws_iam_role.lambda.arn
  timeout          = var.lambda_timeout
  memory_size      = var.lambda_memory_size
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256

  kms_key_arn = local.use_cmk ? var.kms_key_arn : null

  environment {
    variables = {
      INBOUND_BUCKET      = var.inbound_bucket_name
      OWNERSHIP_TABLE     = var.ownership_table_name
      ROUTING_LOG_TABLE   = var.routing_log_table_name
      SF_SECRET_ARN       = var.salesforce_secret_arn
      SF_API_VERSION      = var.salesforce_api_version
      CONNECT_INSTANCE_ID = var.connect_instance_id
      TASK_FLOW_ARN       = var.contact_flow_arn
      OWNER_FLOW_MAP      = jsonencode(var.owner_flow_map)
      SHARED_MAILBOXES    = var.shared_mailboxes
      CASE_ID_REGEX       = var.case_id_regex
    }
  }
}

# NOTE: no aws_lambda_permission for SES here. The SES receipt rule's Lambda
# action (created manually in the console, doc 05) adds the invoke permission
# automatically when you accept the "Allow SES to invoke this function?" prompt.
