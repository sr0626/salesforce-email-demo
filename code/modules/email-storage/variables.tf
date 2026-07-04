variable "instance_alias" {
  type        = string
  description = "Resource-name prefix (the Connect instance alias)."
}

variable "account_id" {
  type        = string
  description = "AWS account id (used in the globally-unique S3 bucket name and the SES SourceAccount condition)."
}

variable "kms_key_arn" {
  type        = string
  description = "KMS key ARN for S3 + DynamoDB encryption. Empty string falls back to SSE-S3 / AWS-owned keys."
  default     = ""
}

variable "ownership_table_suffix" {
  type        = string
  description = "Suffix (after instance_alias) for the ownership DynamoDB table."
  default     = "mailbox-ownership"
}

variable "routing_log_table_suffix" {
  type        = string
  description = "Suffix (after instance_alias) for the routing-log DynamoDB table."
  default     = "email-routing-log"
}
