output "connect_console_url" {
  description = "Amazon Connect access URL for this instance."
  value       = "https://${var.instance_alias}.my.connect.aws"
}

output "connect_instance_arn" {
  value = module.connect.instance_arn
}

output "email_queue_arn" {
  value = module.connect.queue_arn
}

output "contact_flow_arn" {
  value = module.connect.contact_flow_arn
}

output "inbound_bucket" {
  description = "S3 bucket the SES receipt rule writes raw email into (Phase B, doc 05)."
  value       = module.email_storage.bucket_name
}

output "ownership_table" {
  value = module.email_storage.ownership_table_name
}

output "routing_log_table" {
  value = module.email_storage.routing_log_table_name
}

output "salesforce_secret_name" {
  description = "Populate this secret post-apply via: aws secretsmanager put-secret-value (doc 06)."
  value       = module.salesforce_secret.secret_name
}

output "email_router_lambda_arn" {
  description = "Router Lambda ARN — used as the SES receipt rule's Lambda action (Phase B, doc 05)."
  value       = module.email_router.lambda_arn
}

# SES is manual (doc 05); the DKIM CNAMEs come from the SES console, not
# Terraform. The only fixed piece worth surfacing as a reminder is the MX value.
output "ses_mx_reminder" {
  value = "Add MX for ${var.ses_domain}: 10 inbound-smtp.${var.region}.amazonaws.com (see docs/05-setup-ses-evolvity.md)"
}
