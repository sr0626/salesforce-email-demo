########################################
# Core
########################################

variable "region" {
  type        = string
  description = "AWS region. Must support SES email receiving (us-west-2 / us-east-1 / eu-west-1)."
  default     = "us-west-2"
}

variable "instance_alias" {
  type        = string
  description = "Amazon Connect instance alias; also the prefix for other resource names. Must match ^[a-z0-9-]{1,45}$."
  default     = "salesforce-email-demo"

  validation {
    condition     = can(regex("^[a-z0-9-]{1,45}$", var.instance_alias))
    error_message = "instance_alias must be 1-45 chars, lowercase letters, digits, and hyphens only."
  }
}

variable "project_name" {
  type        = string
  description = "Value for the Project tag applied to every resource (kept generic/company-neutral)."
  default     = "salesforce-email-demo"
}

variable "extra_tags" {
  type        = map(string)
  description = "Additional tags merged into the provider default_tags."
  default     = {}
}

variable "kms_key_arn" {
  type        = string
  description = "ARN of an EXISTING KMS key used to encrypt S3, DynamoDB, Secrets Manager, and Lambda env vars. Set to \"\" to fall back to AWS-managed/SSE-S3 encryption. NOTE: for the SES-written inbound bucket, the key policy must also allow ses.amazonaws.com (see docs/05)."
  default     = "arn:aws:kms:us-west-2:044336301301:key/71cf9f1f-81c0-4cc4-8534-6682359b842e"
}

########################################
# SES / routing
########################################

variable "ses_domain" {
  type        = string
  description = "SES receiving subdomain (managed manually in the console; used here only for the MX reminder output)."
  default     = "ccaas.evolvity.com"
}

variable "shared_mailboxes" {
  type        = string
  description = "Comma-separated list of shared mailbox addresses the router treats as shared (ownership-continuity fallback)."
  default     = "ordersuccess@ccaas.evolvity.com"
}

variable "inbound_object_prefix" {
  type        = string
  description = "S3 key prefix the SES receipt rule writes raw email under (set the same prefix in the SES S3 action, doc 05). Surfaced for reference."
  default     = "inbound/"
}

variable "connect_email_bucket_name" {
  type        = string
  description = "Native-email (Fix B): the console-created S3 bucket where Connect stores EMAIL_MESSAGES bodies. The Lambda reads message bodies from here to log them on the SF Case. Empty disables body fetch (subject+metadata only)."
  default     = "salesforce-email-demo-email-storage"
}

variable "connect_email_prefix" {
  type        = string
  description = "S3 key prefix under which Connect writes EMAIL_MESSAGES objects (confirmed from a real object key). The Lambda lists <prefix>/YYYY/MM/DD/ and matches the contact id in the filename."
  default     = "connect/salesforce-email-demo/EmailMessages"
}

variable "flow_debug" {
  type        = bool
  description = "Turn on verbose Lambda payload logging (flow + contact events). Off by default; set true in tfvars to capture a real event during troubleshooting."
  default     = false
}

variable "case_status_on_reply" {
  type        = string
  description = "On the agent's first reply, advance the Salesforce Case Status to this (from \"New\" only; never overrides Working/Escalated/Closed). Empty disables. Closing stays manual."
  default     = "Working"
}

########################################
# EventBridge / cost toggles
########################################

variable "outbound_log_enabled" {
  type        = bool
  description = "Toggle the S4-B outbound-log EventBridge rule. true (default) logs agent replies to the SF Case; false disables the rule so nothing fires when the instance is idle."
  default     = true
}

########################################
# Owner-timeout SLA alert
########################################

variable "sla_alert_enabled" {
  type        = bool
  description = "Toggle the scheduled owner-timeout SLA check. false leaves the EventBridge rule DISABLED (created but not firing); flip to true only for the demo."
  default     = false
}

variable "sla_alert_email" {
  type        = string
  description = "Supervisor recipient(s) for the SLA alert email (SES). Comma-separated for multiple. Empty disables the alert."
  default     = ""
}

variable "sla_from_address" {
  type        = string
  description = "From address for the SLA alert email — must be a verified SES identity (any local part at the verified domain, e.g. alerts@ccaas.evolvity.com). Empty disables the alert."
  default     = ""
}

variable "sla_threshold_seconds" {
  type        = number
  description = "Alert when an owner queue's oldest unhandled email is at least this many seconds old. Default 5 min; lower (e.g. 120) for a snappier demo."
  default     = 300
}

variable "sla_check_rate" {
  type        = string
  description = "EventBridge schedule expression for the SLA check cadence (e.g. \"rate(5 minutes)\"). Only fires when sla_alert_enabled = true."
  default     = "rate(5 minutes)"
}

variable "sla_realert_minutes" {
  type        = number
  description = "Re-alert cooldown (minutes): don't re-email for the same queue within this window, so a standing breach doesn't notify every tick. Default 60."
  default     = 60
}

variable "sla_context_hours" {
  type        = number
  description = "How far back the SLA alert pulls email context (sender/subject/time/case) from the routing log. Wider than the threshold so a long-waiting email still lists. Default 72h."
  default     = 72
}

########################################
# Salesforce
########################################

variable "salesforce_login_url" {
  type        = string
  description = "Salesforce OAuth token host. This org requires its My Domain URL (NOT login.salesforce.com) for the Client Credentials flow. Only seeds the placeholder secret; the real value is set post-apply via put-secret-value."
  default     = "https://orgfarm-ad53113bc6-dev-ed.develop.my.salesforce.com"
}

variable "salesforce_api_version" {
  type        = string
  description = "Salesforce REST API version the Lambda queries against."
  default     = "v60.0"
}

variable "case_id_regex" {
  type        = string
  description = "Regex to extract a Salesforce Case Number from the email subject; capture group 1 is the number. Tolerates 'Case #NNNNN', 'Case # NNNNN', 'Case NNNNN', 'Case: NNNNN', '[Case NNNNN]' (case-insensitive). A bare number without the word 'Case' is intentionally NOT matched (too ambiguous)."
  default     = "Case\\s*[#:]?\\s*(\\d{5,10})"
}

variable "auto_create_case" {
  type        = bool
  description = "When an email has no Case # and no prior owner, create a new Salesforce Case and route to its owner."
  default     = true
}

variable "log_email_to_salesforce" {
  type        = bool
  description = "Log each inbound email onto its Salesforce Case as an incoming EmailMessage (shows in case history)."
  default     = true
}

variable "link_customer_to_contact" {
  type        = bool
  description = "Link cases to a Salesforce Contact/Account (by sender email) so the agent sees the customer 360."
  default     = true
}

########################################
# Connect
########################################

variable "connect_queue_name" {
  type        = string
  description = "Name of the Connect queue that holds email Tasks."
  default     = "Email-Case-Queue"
}

variable "connect_queue_max_contacts" {
  type        = number
  description = "Max concurrent contacts allowed in the queue."
  default     = 25
}

variable "connect_routing_profile_name" {
  type        = string
  description = "Name of the Connect routing profile for email-Task agents."
  default     = "Email-Routing-Profile"
}

variable "connect_task_concurrency" {
  type        = number
  description = "Per-agent concurrent TASK capacity on the routing profile."
  default     = 5
}

variable "connect_hours_timezone" {
  type        = string
  description = "Time zone for the 24x7 hours-of-operation resource."
  default     = "UTC"
}

variable "connect_contact_flow_name" {
  type        = string
  description = "Name of the Task routing contact flow."
  default     = "Email-Case-Routing"
}

# --- Optional demo agent (created only when agent_username is set) ---

variable "agent_username" {
  type        = string
  description = "Login username for an optional demo agent. Empty = don't create one (create manually in console)."
  default     = ""
}

variable "agent_password" {
  type        = string
  description = "Demo agent password (>=8 chars, with upper, lower, number). Stored in local tfstate — set in terraform.tfvars or via TF_VAR_agent_password. Required when agent_username is set."
  default     = ""
  sensitive   = true
}

variable "agent_first_name" {
  type        = string
  description = "Demo agent first name."
  default     = "Demo"
}

variable "agent_last_name" {
  type        = string
  description = "Demo agent last name."
  default     = "Agent"
}

variable "agent_security_profile_name" {
  type        = string
  description = "Existing Connect security profile to assign the agent."
  default     = "Agent"
}

# --- Supervisor user (reporting / review — final-exercise steps 10 & 11) ---

variable "supervisor_username" {
  type        = string
  description = "Login for an optional supervisor user (native dashboards, contact search). Empty = don't create."
  default     = ""
}

variable "supervisor_password" {
  type        = string
  description = "Supervisor password (>=8 chars, upper, lower, number). Stored in local tfstate."
  default     = ""
  sensitive   = true
}

variable "supervisor_first_name" {
  type        = string
  description = "Supervisor first name."
  default     = "Demo"
}

variable "supervisor_last_name" {
  type        = string
  description = "Supervisor last name."
  default     = "Supervisor"
}

variable "supervisor_security_profile_name" {
  type        = string
  description = "Existing Connect security profile for the supervisor (e.g. CallCenterManager)."
  default     = "CallCenterManager"
}

# --- Owner-targeted routing: one agent + dedicated queue/flow per Salesforce owner ---

variable "agents" {
  description = "Per-owner demo agents. Map key = logical name; each maps a Salesforce OwnerId to a Connect agent + dedicated queue/flow so Tasks route to that owner's agent."
  type = map(object({
    username            = string
    password            = string
    first_name          = string
    last_name           = string
    salesforce_owner_id = string
  }))
  default = {}
}

########################################
# Lambda
########################################

variable "lambda_function_name" {
  type        = string
  description = "Name of the email router Lambda function."
  default     = "email-case-router-lambda"
}

variable "lambda_runtime" {
  type        = string
  description = "Lambda runtime for the router function."
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
