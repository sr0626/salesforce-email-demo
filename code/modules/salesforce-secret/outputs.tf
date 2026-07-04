output "secret_arn" {
  value = aws_secretsmanager_secret.salesforce.arn
}

output "secret_name" {
  value = aws_secretsmanager_secret.salesforce.name
}
