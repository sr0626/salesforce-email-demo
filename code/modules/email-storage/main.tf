locals {
  use_cmk = var.kms_key_arn != ""
}

########################################
# S3 inbound-email bucket (+ SES PutObject policy)
########################################

resource "aws_s3_bucket" "inbound" {
  bucket = "${var.instance_alias}-inbound-email-${var.account_id}"

  # raw email survives teardown for audit
  lifecycle {
    prevent_destroy = true
  }
}

# Encrypt objects. With a CMK, SES must also be allowed to use the key — its key
# POLICY must permit ses.amazonaws.com (kms:GenerateDataKey/Encrypt, scoped to
# this account). See docs/05-setup-ses-evolvity.md. bucket_key_enabled reduces
# KMS API calls/cost.
resource "aws_s3_bucket_server_side_encryption_configuration" "inbound" {
  bucket = aws_s3_bucket.inbound.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = local.use_cmk ? "aws:kms" : "AES256"
      kms_master_key_id = local.use_cmk ? var.kms_key_arn : null
    }
    bucket_key_enabled = local.use_cmk
  }
}

resource "aws_s3_bucket_public_access_block" "inbound" {
  bucket                  = aws_s3_bucket.inbound.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "inbound" {
  bucket = aws_s3_bucket.inbound.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowSESPuts"
      Effect    = "Allow"
      Principal = { Service = "ses.amazonaws.com" }
      Action    = "s3:PutObject"
      Resource  = "${aws_s3_bucket.inbound.arn}/*"
      Condition = { StringEquals = { "aws:SourceAccount" = var.account_id } }
    }]
  })
}

########################################
# DynamoDB — MailboxOwnership (current state, upserted)
########################################

resource "aws_dynamodb_table" "mailbox_ownership" {
  name         = "${var.instance_alias}-${var.ownership_table_suffix}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "mailbox"       # e.g. ordersuccess@ccaas.evolvity.com
  range_key    = "customerEmail" # the external customer's address

  attribute {
    name = "mailbox"
    type = "S"
  }
  attribute {
    name = "customerEmail"
    type = "S"
  }

  dynamic "server_side_encryption" {
    for_each = local.use_cmk ? [1] : []
    content {
      enabled     = true
      kms_key_arn = var.kms_key_arn
    }
  }
}

########################################
# DynamoDB — EmailRoutingLog (append-only audit trail)
########################################

resource "aws_dynamodb_table" "email_routing_log" {
  name         = "${var.instance_alias}-${var.routing_log_table_suffix}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "emailId"   # SES messageId
  range_key    = "timestamp" # ISO8601

  attribute {
    name = "emailId"
    type = "S"
  }
  attribute {
    name = "timestamp"
    type = "S"
  }

  dynamic "server_side_encryption" {
    for_each = local.use_cmk ? [1] : []
    content {
      enabled     = true
      kms_key_arn = var.kms_key_arn
    }
  }
}
