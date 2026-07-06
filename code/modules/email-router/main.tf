locals {
  use_cmk = var.kms_key_arn != ""

  base_statements = [
    {
      Sid      = "ReadRawWriteRenderedEmail"
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:PutObject"]
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

  # Flow mode (native email): read the message body Connect stored in its
  # EMAIL_MESSAGES bucket (Fix B). Only added when the bucket is configured.
  connect_email_statements = var.connect_email_bucket_arn != "" ? [
    {
      Sid      = "ReadConnectEmailMessages"
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:ListBucket"]
      Resource = [var.connect_email_bucket_arn, "${var.connect_email_bucket_arn}/*"]
    },
  ] : []
}

data "archive_file" "lambda" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/build/index.zip"
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
  name = "EmailRoutingAccess"
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = concat(local.base_statements, local.kms_statements, local.connect_email_statements)
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
      INBOUND_PREFIX      = var.inbound_object_prefix
      RENDERED_PREFIX     = "rendered/"
      OWNERSHIP_TABLE     = var.ownership_table_name
      ROUTING_LOG_TABLE   = var.routing_log_table_name
      SF_SECRET_ARN       = var.salesforce_secret_arn
      SF_API_VERSION      = var.salesforce_api_version
      CONNECT_INSTANCE_ID = var.connect_instance_id
      TASK_FLOW_ARN       = var.contact_flow_arn
      OWNER_FLOW_MAP      = jsonencode(var.owner_flow_map)
      OWNER_QUEUE_MAP     = jsonencode(var.owner_queue_map)
      FALLBACK_QUEUE_ARN  = var.fallback_queue_arn
      CONNECT_EMAIL_BUCKET = var.connect_email_bucket_name
      CONNECT_EMAIL_PREFIX = var.connect_email_prefix
      SHARED_MAILBOXES    = var.shared_mailboxes
      CASE_ID_REGEX       = var.case_id_regex
      AUTO_CREATE_CASE    = var.auto_create_case ? "true" : "false"
      LOG_EMAIL_TO_SF     = var.log_email_to_salesforce ? "true" : "false"
      LINK_CONTACT        = var.link_customer_to_contact ? "true" : "false"
    }
  }
}

# NOTE: no aws_lambda_permission for SES here. The SES receipt rule's Lambda
# action (created manually in the console, doc 05) adds the invoke permission
# automatically when you accept the "Allow SES to invoke this function?" prompt.
