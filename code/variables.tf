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
  description = "Regex to extract a Salesforce Case Number from the email subject; capture group 1 is the number."
  default     = "Case\\s*#?(\\d{5,10})"
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
