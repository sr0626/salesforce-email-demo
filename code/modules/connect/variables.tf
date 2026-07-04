variable "instance_alias" {
  type        = string
  description = "Amazon Connect instance alias (must be globally unique within the account/region)."
}

variable "queue_name" {
  type        = string
  description = "Name of the Connect queue that holds email Tasks."
  default     = "Email-Case-Queue"
}

variable "queue_max_contacts" {
  type        = number
  description = "Max concurrent contacts allowed in the queue."
  default     = 25
}

variable "routing_profile_name" {
  type        = string
  description = "Name of the Connect routing profile for email-Task agents."
  default     = "Email-Routing-Profile"
}

variable "task_concurrency" {
  type        = number
  description = "Per-agent concurrent TASK capacity on the routing profile."
  default     = 5
}

variable "hours_timezone" {
  type        = string
  description = "Time zone for the 24x7 hours-of-operation resource."
  default     = "UTC"
}

variable "contact_flow_name" {
  type        = string
  description = "Name of the Task routing contact flow."
  default     = "Email-Case-Routing"
}

# --- Optional demo agent (created only when agent_username is set) ---

variable "agent_username" {
  type        = string
  description = "Login username for an optional demo agent. Leave empty to not create an agent (create it manually in the console instead)."
  default     = ""
}

variable "agent_password" {
  type        = string
  description = "Password for the demo agent (Connect complexity: >=8 chars, upper, lower, number). Stored in local tfstate — set via tfvars or TF_VAR_agent_password. Required if agent_username is set."
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
  description = "Name of an existing Connect security profile to assign the agent."
  default     = "Agent"
}

# --- Owner-targeted routing: one agent + dedicated queue/flow per Salesforce owner ---

variable "agents" {
  description = "Per-owner demo agents. Map key = logical name (e.g. \"epic\"). Each maps a Salesforce OwnerId to a Connect agent with a dedicated queue + contact flow, so Tasks route to that owner's agent."
  type = map(object({
    username            = string
    password            = string
    first_name          = string
    last_name           = string
    salesforce_owner_id = string
  }))
  default = {}
}
