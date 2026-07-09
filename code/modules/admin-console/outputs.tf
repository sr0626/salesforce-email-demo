output "console_url" {
  description = "Admin console URL (Lambda Function URL). Open in a browser and enter the token."
  value       = aws_lambda_function_url.admin.function_url
}

output "console_token" {
  description = "Bearer token for the admin console (enter on the login screen)."
  value       = local.token
  sensitive   = true
}
