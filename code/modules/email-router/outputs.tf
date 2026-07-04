output "lambda_arn" {
  value = aws_lambda_function.router.arn
}

output "lambda_name" {
  value = aws_lambda_function.router.function_name
}

output "role_arn" {
  value = aws_iam_role.lambda.arn
}
