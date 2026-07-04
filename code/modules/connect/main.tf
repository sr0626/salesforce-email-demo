# Amazon Connect instance + routing for Salesforce-case email Tasks.
# Cost-minimal: Task channel only; no recording, no Kinesis streaming, no
# Contact Lens (those need separate resources we deliberately do not create).

resource "aws_connect_instance" "this" {
  identity_management_type = "CONNECT_MANAGED"
  instance_alias           = var.instance_alias

  inbound_calls_enabled     = true
  outbound_calls_enabled    = true
  contact_flow_logs_enabled = true

  # explicitly OFF for cost:
  contact_lens_enabled             = false
  auto_resolve_best_voices_enabled = false
  early_media_enabled              = false
  multi_party_conference_enabled   = false
}

# Hours of operation — 24x7
resource "aws_connect_hours_of_operation" "always_open" {
  instance_id = aws_connect_instance.this.id
  name        = "Always-Open"
  description = "24x7 open for the email-routing POC"
  time_zone   = var.hours_timezone

  dynamic "config" {
    for_each = ["MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY", "SUNDAY"]
    content {
      day = config.value
      start_time {
        hours   = 0
        minutes = 0
      }
      end_time {
        hours   = 23
        minutes = 59
      }
    }
  }
}

# Queue — Task channel only
resource "aws_connect_queue" "email" {
  instance_id           = aws_connect_instance.this.id
  name                  = var.queue_name
  description           = "Shared queue for Salesforce-case email Tasks — agents see ownerName/caseId attributes on each task"
  hours_of_operation_id = aws_connect_hours_of_operation.always_open.hours_of_operation_id
  max_contacts          = var.queue_max_contacts
}

# Routing profile — TASK only
resource "aws_connect_routing_profile" "email" {
  instance_id               = aws_connect_instance.this.id
  name                      = var.routing_profile_name
  description               = "Routing profile for agents handling Salesforce-case email Tasks"
  default_outbound_queue_id = aws_connect_queue.email.queue_id

  media_concurrencies {
    channel     = "TASK"
    concurrency = var.task_concurrency
  }

  queue_configs {
    channel  = "TASK"
    delay    = 0
    priority = 1
    queue_id = aws_connect_queue.email.queue_id
  }
}

# Optional demo agent — created only when var.agent_username is set. Uses a
# SOFT_PHONE config (no claimed phone number). Assigned the email routing
# profile so it can receive the Tasks the router creates.
data "aws_connect_security_profile" "agent" {
  count       = var.agent_username != "" ? 1 : 0
  instance_id = aws_connect_instance.this.id
  name        = var.agent_security_profile_name
}

resource "aws_connect_user" "agent" {
  count = var.agent_username != "" ? 1 : 0

  instance_id          = aws_connect_instance.this.id
  name                 = var.agent_username
  password             = var.agent_password
  routing_profile_id   = aws_connect_routing_profile.email.routing_profile_id
  security_profile_ids = [data.aws_connect_security_profile.agent[0].security_profile_id]

  phone_config {
    phone_type  = "SOFT_PHONE"
    auto_accept = false
  }

  identity_info {
    first_name = var.agent_first_name
    last_name  = var.agent_last_name
  }
}

# ---- Owner-targeted routing: per-owner queue + routing profile + flow + agent ----
# Each owner's Task is routed by the Lambda to that owner's dedicated flow, which
# targets that owner's queue, served only by that owner's agent.

data "aws_connect_security_profile" "owner_agent" {
  count       = length(var.agents) > 0 ? 1 : 0
  instance_id = aws_connect_instance.this.id
  name        = var.agent_security_profile_name
}

resource "aws_connect_queue" "owner" {
  for_each              = var.agents
  instance_id           = aws_connect_instance.this.id
  name                  = "Owner-${each.key}-Queue"
  description           = "Owner-targeted queue for SF owner ${each.value.salesforce_owner_id} (${each.value.first_name} ${each.value.last_name})"
  hours_of_operation_id = aws_connect_hours_of_operation.always_open.hours_of_operation_id
  max_contacts          = var.queue_max_contacts
}

resource "aws_connect_routing_profile" "owner" {
  for_each                  = var.agents
  instance_id               = aws_connect_instance.this.id
  name                      = "Owner-${each.key}-Profile"
  description               = "Owner-targeted routing profile for ${each.key}"
  default_outbound_queue_id = aws_connect_queue.owner[each.key].queue_id

  media_concurrencies {
    channel     = "TASK"
    concurrency = var.task_concurrency
  }

  queue_configs {
    channel  = "TASK"
    delay    = 0
    priority = 1
    queue_id = aws_connect_queue.owner[each.key].queue_id
  }
}

resource "aws_connect_contact_flow" "owner" {
  for_each    = var.agents
  instance_id = aws_connect_instance.this.id
  name        = "Owner-${each.key}-Routing"
  type        = "CONTACT_FLOW"
  description = "Routes Tasks for SF owner ${each.value.salesforce_owner_id} into Owner-${each.key}-Queue"

  content = jsonencode({
    Version     = "2019-10-30"
    StartAction = "t01"
    Actions = [
      {
        Identifier = "t01"
        Type       = "UpdateContactTargetQueue"
        Parameters = { QueueId = aws_connect_queue.owner[each.key].queue_id }
        Transitions = {
          NextAction = "t02"
          Errors     = [{ NextAction = "t_end", ErrorType = "NoMatchingError" }]
          Conditions = []
        }
      },
      {
        Identifier = "t02"
        Type       = "TransferContactToQueue"
        Parameters = {}
        Transitions = {
          NextAction = "t_end"
          Errors = [
            { NextAction = "t_end", ErrorType = "NoMatchingError" },
            { NextAction = "t_end", ErrorType = "QueueAtCapacity" }
          ]
          Conditions = []
        }
      },
      { Identifier = "t_end", Type = "DisconnectParticipant", Parameters = {}, Transitions = {} }
    ]
  })
}

resource "aws_connect_user" "owner" {
  for_each = var.agents

  instance_id          = aws_connect_instance.this.id
  name                 = each.value.username
  password             = each.value.password
  routing_profile_id   = aws_connect_routing_profile.owner[each.key].routing_profile_id
  security_profile_ids = [data.aws_connect_security_profile.owner_agent[0].security_profile_id]

  phone_config {
    phone_type  = "SOFT_PHONE"
    auto_accept = false
  }

  identity_info {
    first_name = each.value.first_name
    last_name  = each.value.last_name
  }
}

# Task contact flow — set target queue, transfer the Task in, disconnect.
resource "aws_connect_contact_flow" "email_task" {
  instance_id = aws_connect_instance.this.id
  name        = var.contact_flow_name
  type        = "CONTACT_FLOW"
  description = "Routes Salesforce-case email Tasks into the ${var.queue_name}"

  content = jsonencode({
    Version     = "2019-10-30"
    StartAction = "t01"
    Actions = [
      {
        Identifier = "t01"
        Type       = "UpdateContactTargetQueue"
        Parameters = { QueueId = aws_connect_queue.email.queue_id }
        Transitions = {
          NextAction = "t02"
          Errors     = [{ NextAction = "t_end", ErrorType = "NoMatchingError" }]
          Conditions = []
        }
      },
      {
        Identifier = "t02"
        Type       = "TransferContactToQueue"
        Parameters = {}
        # On a successful queue transfer the contact leaves the flow, so this
        # NextAction is effectively unreachable; point it at the same single
        # Disconnect as the error branches so there's no orphan block.
        Transitions = {
          NextAction = "t_end"
          Errors = [
            { NextAction = "t_end", ErrorType = "NoMatchingError" },
            { NextAction = "t_end", ErrorType = "QueueAtCapacity" }
          ]
          Conditions = []
        }
      },
      { Identifier = "t_end", Type = "DisconnectParticipant", Parameters = {}, Transitions = {} }
    ]
  })
}
