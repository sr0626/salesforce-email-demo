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
      Sid    = "RoutingLogWriteRead"
      Effect = "Allow"
      # Query added for S4-B (map an outbound reply back to its Case) + SLA re-alert
      # cooldown markers. Scan added for the SLA alert's recent-email context list.
      Action   = ["dynamodb:PutItem", "dynamodb:Query", "dynamodb:Scan"]
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
    {
      # SLA alert (owner-timeout): read real-time queue metrics to find the oldest
      # unhandled email + resolve friendly queue names for the alert. These authorize
      # at the QUEUE sub-resource (instance/<id>/queue/<id>), so the grant must include
      # /* — the instance ARN alone gets AccessDenied on the queue resource.
      Sid      = "ReadConnectQueueMetrics"
      Effect   = "Allow"
      Action   = ["connect:GetCurrentMetricData", "connect:DescribeQueue"]
      Resource = [var.connect_instance_arn, "${var.connect_instance_arn}/*"]
    },
  ]

  # SLA alert: send the supervisor an HTML email via SES. SendEmail is authorized on
  # the sending identity; scoped by a FromAddress condition to the configured sender.
  ses_statements = [
    {
      Sid      = "SendSlaAlertEmail"
      Effect   = "Allow"
      Action   = ["ses:SendEmail"]
      Resource = "*"
      Condition = {
        "StringEquals" = { "ses:FromAddress" = var.sla_from_address }
      }
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
    Statement = concat(local.base_statements, local.kms_statements, local.connect_email_statements, local.ses_statements)
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
      INBOUND_BUCKET        = var.inbound_bucket_name
      INBOUND_PREFIX        = var.inbound_object_prefix
      RENDERED_PREFIX       = "rendered/"
      OWNERSHIP_TABLE       = var.ownership_table_name
      ROUTING_LOG_TABLE     = var.routing_log_table_name
      SF_SECRET_ARN         = var.salesforce_secret_arn
      SF_API_VERSION        = var.salesforce_api_version
      CONNECT_INSTANCE_ID   = var.connect_instance_id
      TASK_FLOW_ARN         = var.contact_flow_arn
      OWNER_FLOW_MAP        = jsonencode(var.owner_flow_map)
      OWNER_QUEUE_MAP       = jsonencode(var.owner_queue_map)
      OWNER_NAME_MAP        = jsonencode(var.owner_name_map)
      FALLBACK_QUEUE_ARN    = var.fallback_queue_arn
      CONNECT_EMAIL_BUCKET  = var.connect_email_bucket_name
      CONNECT_EMAIL_PREFIX  = var.connect_email_prefix
      SHARED_MAILBOXES      = var.shared_mailboxes
      CASE_ID_REGEX         = var.case_id_regex
      AUTO_CREATE_CASE      = var.auto_create_case ? "true" : "false"
      LOG_EMAIL_TO_SF       = var.log_email_to_salesforce ? "true" : "false"
      CASE_STATUS_ON_REPLY  = var.case_status_on_reply
      LINK_CONTACT          = var.link_customer_to_contact ? "true" : "false"
      FLOW_DEBUG            = var.flow_debug ? "true" : "false"
      SLA_FROM_ADDRESS      = var.sla_from_address
      SLA_ALERT_EMAILS      = var.sla_alert_email
      SLA_THRESHOLD_SECONDS = tostring(var.sla_threshold_seconds)
      SLA_REALERT_SECONDS   = tostring(var.sla_realert_minutes * 60)
      SLA_CONTEXT_HOURS     = tostring(var.sla_context_hours)
      CONNECT_ACCESS_URL    = "https://${var.instance_alias}.my.connect.aws"
    }
  }
}

# NOTE: no aws_lambda_permission for SES here. The SES receipt rule's Lambda
# action (created manually in the console, doc 05) adds the invoke permission
# automatically when you accept the "Allow SES to invoke this function?" prompt.

########################################
# S4-B: outbound email -> Salesforce logging
# EventBridge subscribes to Connect Contact Events (COMPLETED email contacts) and
# invokes the router in outbound-log mode. Connect emits these to the default event
# bus; creating the rule is the subscription (no Kinesis).
########################################
resource "aws_cloudwatch_event_rule" "outbound_email_completed" {
  name        = "${var.lambda_function_name}-outbound-email-completed"
  description = "Connect email contacts completed -> log agent outbound to the SF Case"
  # Toggle: disable to stop all outbound-logging invokes when the instance is idle.
  state = var.outbound_log_enabled ? "ENABLED" : "DISABLED"
  event_pattern = jsonencode({
    source      = ["aws.connect"]
    detail-type = ["Amazon Connect Contact Event"]
    detail = {
      channel   = ["EMAIL"]
      eventType = ["COMPLETED"]
      # initiationMethod filtered in the Lambda (AGENT_REPLY / OUTBOUND) so a casing
      # difference in the event can't silently drop the rule match.
    }
  })
}

resource "aws_cloudwatch_event_target" "outbound_email_lambda" {
  rule      = aws_cloudwatch_event_rule.outbound_email_completed.name
  target_id = "email-router-outbound-log"
  arn       = aws_lambda_function.router.arn
}

resource "aws_lambda_permission" "eventbridge_outbound" {
  statement_id  = "AllowEventBridgeOutboundLog"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.router.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.outbound_email_completed.arn
}

########################################
# Owner-timeout SLA alert
# A scheduled EventBridge rule invokes the router in sla_check mode; the Lambda polls
# Connect OLDEST_CONTACT_AGE per owner queue and emails a supervisor (SES HTML) on a
# breach. There is deliberately no overflow queue (validated gap #5) — this is
# alert-only. The rule is toggled by sla_alert_enabled so it can stay DISABLED except
# during demos. Delivery is SES (HTML table) from var.sla_from_address to
# var.sla_alert_email — no SNS topic/subscription-confirmation dance.
########################################
resource "aws_cloudwatch_event_rule" "sla_check" {
  name                = "${var.lambda_function_name}-sla-check"
  description         = "Owner-timeout SLA check: alert on unhandled emails past threshold"
  schedule_expression = var.sla_check_rate
  # Toggle: created but DISABLED unless sla_alert_enabled = true (turn on for the demo).
  state = var.sla_alert_enabled ? "ENABLED" : "DISABLED"
}

resource "aws_cloudwatch_event_target" "sla_check_lambda" {
  rule      = aws_cloudwatch_event_rule.sla_check.name
  target_id = "email-router-sla-check"
  arn       = aws_lambda_function.router.arn
  input     = jsonencode({ task = "sla_check" })
}

resource "aws_lambda_permission" "eventbridge_sla" {
  statement_id  = "AllowEventBridgeSlaCheck"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.router.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.sla_check.arn
}
