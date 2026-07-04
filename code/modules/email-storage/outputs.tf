output "bucket_name" {
  value = aws_s3_bucket.inbound.bucket
}

output "bucket_arn" {
  value = aws_s3_bucket.inbound.arn
}

output "ownership_table_name" {
  value = aws_dynamodb_table.mailbox_ownership.name
}

output "ownership_table_arn" {
  value = aws_dynamodb_table.mailbox_ownership.arn
}

output "routing_log_table_name" {
  value = aws_dynamodb_table.email_routing_log.name
}

output "routing_log_table_arn" {
  value = aws_dynamodb_table.email_routing_log.arn
}
