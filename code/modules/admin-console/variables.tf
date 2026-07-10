variable "lambda_function_name" {
  type        = string
  description = "Name of the admin-console Lambda function."
}

variable "lambda_runtime" {
  type    = string
  default = "python3.12"
}

variable "kms_key_arn" {
  type        = string
  description = "CMK for the Lambda env + DynamoDB access. Empty = AWS-owned keys."
  default     = ""
}

variable "routing_rules_table_name" { type = string }
variable "routing_rules_table_arn" { type = string }
variable "email_templates_table_name" { type = string }
variable "email_templates_table_arn" { type = string }

variable "owner_name_map" {
  type        = map(string)
  description = "SalesforceOwnerId -> display name, so the console shows friendly owner names in the rule target dropdown."
  default     = {}
}

variable "admin_token" {
  type        = string
  description = "Bearer token gating the console API. Empty auto-generates one (see the admin_console_token output). Set explicitly to pin it."
  default     = ""
  sensitive   = true
}

variable "qr_knowledge_base_id" {
  type        = string
  description = "Amazon Q in Connect QUICK_RESPONSES knowledge base id bound to the instance (from list-integration-associations WISDOM_QUICK_RESPONSES). Enables the templates 'Publish to Q' button. Empty leaves publishing disabled."
  default     = ""
}

variable "qr_knowledge_base_arn" {
  type        = string
  description = "ARN of qr_knowledge_base_id, for the wisdom/qconnect IAM grant. Empty omits the statement."
  default     = ""
}
