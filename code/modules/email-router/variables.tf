variable "instance_alias" {
  type        = string
  description = "Resource-name prefix (the Connect instance alias)."
}

variable "lambda_function_name" {
  type        = string
  description = "Name of the router Lambda function."
}

variable "lambda_runtime" {
  type        = string
  description = "Lambda runtime."
  default     = "python3.12"
}

variable "lambda_timeout" {
  type        = number
  description = "Lambda timeout in seconds."
  default     = 30
}

variable "lambda_memory_size" {
  type        = number
  description = "Lambda memory (MB)."
  default     = 256
}

variable "kms_key_arn" {
  type        = string
  description = "KMS key ARN to encrypt Lambda environment variables and that the role may use for S3/DynamoDB/Secrets decryption. Empty string uses AWS-owned keys and omits the KMS IAM statement."
  default     = ""
}

# --- wiring from other modules ---

variable "inbound_bucket_name" { type = string }
variable "inbound_bucket_arn" { type = string }
variable "ownership_table_name" { type = string }
variable "ownership_table_arn" { type = string }
variable "routing_log_table_name" { type = string }
variable "routing_log_table_arn" { type = string }
variable "salesforce_secret_arn" { type = string }
variable "connect_instance_id" { type = string }
variable "connect_instance_arn" { type = string }
variable "contact_flow_arn" { type = string }

# --- behavior ---

variable "salesforce_api_version" {
  type        = string
  description = "Salesforce REST API version to query."
  default     = "v60.0"
}

variable "shared_mailboxes" {
  type        = string
  description = "Comma-separated shared mailbox addresses."
}

variable "case_id_regex" {
  type        = string
  description = "Regex to extract the Case Number from the subject (group 1)."
}

variable "owner_flow_map" {
  type        = map(string)
  description = "Map of Salesforce OwnerId -> owner-specific contact flow ARN. The Lambda routes a Task via the matching owner's flow; unmapped owners fall back to contact_flow_arn."
  default     = {}
}

variable "inbound_object_prefix" {
  type        = string
  description = "S3 key prefix SES writes raw email under; the Lambda reads <prefix><messageId> to build the body preview + link."
  default     = "inbound/"
}

variable "auto_create_case" {
  type        = bool
  description = "When an email has no Case # and no prior owner, create a new Salesforce Case (Email-to-Case style) and route to its owner."
  default     = true
}

variable "log_email_to_salesforce" {
  type        = bool
  description = "Log each inbound email onto its Salesforce Case as an incoming EmailMessage (shows in case history)."
  default     = true
}

variable "link_customer_to_contact" {
  type        = bool
  description = "Link cases to a Salesforce Contact/Account (matched by sender email, find-or-create) so the agent sees the customer 360 (history, open cases, account activity)."
  default     = true
}
