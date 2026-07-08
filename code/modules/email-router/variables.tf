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

variable "owner_queue_map" {
  type        = map(string)
  description = "Flow mode (native email): map of Salesforce OwnerId -> Connect queue ARN. The inbound email flow Sets working queue to the returned targetQueueArn; unmapped owners fall back to fallback_queue_arn. Empty until the native-email queues are wired."
  default     = {}
}

variable "fallback_queue_arn" {
  type        = string
  description = "Flow mode (native email): shared queue ARN used when the owner isn't in owner_queue_map. Empty string lets the email flow branch to a default queue."
  default     = ""
}

variable "owner_name_map" {
  type        = map(string)
  description = "Map of Salesforce OwnerId -> agent display name (\"First Last\"), so the SLA alert can name the agent behind each owner queue. Unmapped owners show a dash; the fallback queue shows \"Shared / unassigned\"."
  default     = {}
}

variable "connect_email_bucket_name" {
  type        = string
  description = "Flow mode (Fix B): the S3 bucket where Connect stores native-email message bodies (EMAIL_MESSAGES storage). Empty disables body fetch (logs subject+metadata only)."
  default     = ""
}

variable "connect_email_bucket_arn" {
  type        = string
  description = "ARN of connect_email_bucket_name, used to grant the Lambda role read access. Empty omits the S3 read statement."
  default     = ""
}

variable "connect_email_prefix" {
  type        = string
  description = "S3 key prefix under which Connect writes EMAIL_MESSAGES objects (e.g. connect/salesforce-email-demo/EmailMessages)."
  default     = ""
}

variable "flow_debug" {
  type        = bool
  description = "When true, the Lambda logs full flow / contact-event payloads (verbose, includes PII). Off by default; turn on to troubleshoot."
  default     = false
}

variable "inbound_object_prefix" {
  type        = string
  description = "S3 key prefix SES writes raw email under; the Lambda reads <prefix><messageId> to build the body preview + link."
  default     = "inbound/"
}

# --- EventBridge / cost toggles ---

variable "outbound_log_enabled" {
  type        = bool
  description = "Toggle the S4-B outbound-log EventBridge rule (agent reply -> SF Case). true (default) logs the full thread; false leaves the rule DISABLED so no invokes fire when the instance is idle."
  default     = true
}

# --- SLA alert (owner-timeout) ---

variable "sla_alert_enabled" {
  type        = bool
  description = "Toggle the scheduled owner-timeout SLA check. false leaves the EventBridge rule DISABLED (created but not firing) so you can turn it on only for the demo. true polls on sla_check_rate."
  default     = false
}

variable "sla_alert_email" {
  type        = string
  description = "Supervisor recipient(s) for the SLA alert email (SES). Comma-separated for multiple. Empty disables the alert (no send)."
  default     = ""
}

variable "sla_from_address" {
  type        = string
  description = "From address for the SLA alert email. Must be a verified SES identity — any local part at the verified ccaas.evolvity.com domain works (e.g. alerts@ccaas.evolvity.com). Empty disables the alert."
  default     = ""
}

variable "sla_threshold_seconds" {
  type        = number
  description = "SLA breach threshold: alert when an owner queue's oldest unhandled email is at least this many seconds old. Default 5 min; lower (e.g. 120) for a snappier demo."
  default     = 300
}

variable "sla_check_rate" {
  type        = string
  description = "EventBridge schedule expression for how often the SLA check runs (e.g. \"rate(5 minutes)\"). Only fires when sla_alert_enabled = true."
  default     = "rate(5 minutes)"
}

variable "sla_realert_minutes" {
  type        = number
  description = "Re-alert cooldown: don't email again for the same queue within this many minutes, so a standing breach doesn't notify every scheduled tick. Default 60."
  default     = 60
}

variable "sla_context_hours" {
  type        = number
  description = "How far back the SLA alert pulls email context (sender/subject/time/case) from the routing log. Wider than the threshold so an email waiting many hours still lists. Default 72h."
  default     = 72
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

variable "case_status_on_reply" {
  type        = string
  description = "On the agent's first reply, advance the Salesforce Case Status to this (from \"New\" only, so it never overrides Working/Escalated/Closed). Empty string disables. Closing stays a manual agent decision."
  default     = "Working"
}

variable "link_customer_to_contact" {
  type        = bool
  description = "Link cases to a Salesforce Contact/Account (matched by sender email, find-or-create) so the agent sees the customer 360 (history, open cases, account activity)."
  default     = true
}
