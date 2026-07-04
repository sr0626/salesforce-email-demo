output "instance_id" {
  value = aws_connect_instance.this.id
}

output "instance_arn" {
  value = aws_connect_instance.this.arn
}

output "queue_id" {
  value = aws_connect_queue.email.queue_id
}

output "queue_arn" {
  value = aws_connect_queue.email.arn
}

output "routing_profile_id" {
  value = aws_connect_routing_profile.email.routing_profile_id
}

output "contact_flow_id" {
  value = aws_connect_contact_flow.email_task.contact_flow_id
}

output "contact_flow_arn" {
  value = aws_connect_contact_flow.email_task.arn
}

output "agent_username" {
  description = "The demo agent username, if one was created."
  value       = var.agent_username != "" ? var.agent_username : null
}

output "owner_flow_map" {
  description = "Map of Salesforce OwnerId -> that owner's contact flow ARN (Lambda routes each Task by owner)."
  value       = { for k, a in var.agents : a.salesforce_owner_id => aws_connect_contact_flow.owner[k].arn }
}
