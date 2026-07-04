variable "instance_alias" {
  type        = string
  description = "Resource-name prefix (the Connect instance alias)."
}

variable "salesforce_login_url" {
  type        = string
  description = "Salesforce OAuth token host — seeds the placeholder secret only."
}

variable "kms_key_arn" {
  type        = string
  description = "KMS key ARN to encrypt the secret. Empty string uses the AWS-managed aws/secretsmanager key."
  default     = ""
}

variable "secret_suffix" {
  type        = string
  description = "Suffix (after instance_alias) for the Secrets Manager secret name."
  default     = "salesforce-credentials"
}
