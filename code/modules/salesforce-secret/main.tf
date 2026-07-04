# Secrets Manager secret holding the Salesforce Client Credentials app creds.
# Terraform seeds a PLACEHOLDER only; the real client_id/client_secret are set
# post-apply via `aws secretsmanager put-secret-value` (docs/06). Never commit
# real values.

resource "aws_secretsmanager_secret" "salesforce" {
  name        = "${var.instance_alias}-${var.secret_suffix}"
  description = "Salesforce Connected/External App credentials for the email router Lambda — populate via CLI after apply, never store real values in code"
  kms_key_id  = var.kms_key_arn != "" ? var.kms_key_arn : null
}

resource "aws_secretsmanager_secret_version" "salesforce" {
  secret_id = aws_secretsmanager_secret.salesforce.id
  secret_string = jsonencode({
    client_id     = "REPLACE_ME"
    client_secret = "REPLACE_ME"
    login_url     = var.salesforce_login_url
  })

  # the real value is set out-of-band via `aws secretsmanager put-secret-value`;
  # don't let Terraform revert it on every apply:
  lifecycle {
    ignore_changes = [secret_string]
  }
}
