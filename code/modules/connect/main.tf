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
  # NOTE: quick-connect→queue association is a CONSOLE step (see the owner queue
  # note above and docs/10) — inline here would create a TF dependency cycle.
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
  # Native email channel (hybrid): lets shared-profile agents (demo.agent,
  # supervisor) also receive native email contacts as a fallback.
  media_concurrencies {
    channel     = "EMAIL"
    concurrency = var.email_concurrency
  }

  queue_configs {
    channel  = "TASK"
    delay    = 0
    priority = 1
    queue_id = aws_connect_queue.email.queue_id
  }
  queue_configs {
    channel  = "EMAIL"
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
  count       = length(var.agents) > 0 || length(var.specialists) > 0 ? 1 : 0
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
  # NOTE: quick-connect→queue association (for agent-to-agent transfer) is a CONSOLE
  # step, not set here: doing it inline creates a TF dependency cycle
  # (queue → quick_connect → user → routing_profile → queue). See docs/10.
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
  # Native email channel — routes native email contacts to this owner's agent.
  media_concurrencies {
    channel     = "EMAIL"
    concurrency = var.email_concurrency
  }

  queue_configs {
    channel  = "TASK"
    delay    = 0
    priority = 1
    queue_id = aws_connect_queue.owner[each.key].queue_id
  }
  queue_configs {
    channel  = "EMAIL"
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

# ---- Specialists (S6): queue + routing profile + user reachable ONLY via routing
# rules. No owner contact flow and NOT in owner_queue_map/fallback, so the sole path
# to a specialist is a matched rule that Sets working queue to their queue.
resource "aws_connect_queue" "specialist" {
  for_each              = var.specialists
  instance_id           = aws_connect_instance.this.id
  name                  = "${each.value.first_name} ${each.value.last_name}"
  description           = "Specialist queue for ${each.key} — reachable only via S6 routing rules"
  hours_of_operation_id = aws_connect_hours_of_operation.always_open.hours_of_operation_id
  max_contacts          = var.queue_max_contacts
}

resource "aws_connect_routing_profile" "specialist" {
  for_each                  = var.specialists
  instance_id               = aws_connect_instance.this.id
  name                      = "${each.value.first_name} ${each.value.last_name} Profile"
  description               = "Specialist routing profile for ${each.key}"
  default_outbound_queue_id = aws_connect_queue.specialist[each.key].queue_id

  media_concurrencies {
    channel     = "EMAIL"
    concurrency = var.email_concurrency
  }
  queue_configs {
    channel  = "EMAIL"
    delay    = 0
    priority = 1
    queue_id = aws_connect_queue.specialist[each.key].queue_id
  }
}

resource "aws_connect_user" "specialist" {
  for_each = var.specialists

  instance_id          = aws_connect_instance.this.id
  name                 = each.value.username
  password             = each.value.password
  routing_profile_id   = aws_connect_routing_profile.specialist[each.key].routing_profile_id
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

# ---- Collaboration (final-exercise step 8): USER quick connects so an agent can
# transfer/consult a colleague. Associate them to a queue in the console to make
# them appear in the agent's transfer list (kept out of Terraform to avoid a
# queue<->quickconnect<->user dependency cycle).
data "aws_connect_contact_flow" "agent_transfer" {
  count       = length(var.agents) > 0 ? 1 : 0
  instance_id = aws_connect_instance.this.id
  name        = "Default agent transfer"
}

resource "aws_connect_quick_connect" "owner" {
  for_each    = var.agents
  instance_id = aws_connect_instance.this.id
  name        = "Transfer-to-${each.key}"
  description = "Transfer/consult ${each.value.first_name} ${each.value.last_name}"

  quick_connect_config {
    quick_connect_type = "USER"
    user_config {
      user_id         = aws_connect_user.owner[each.key].user_id
      contact_flow_id = data.aws_connect_contact_flow.agent_transfer[0].contact_flow_id
    }
  }
}

# ---- Reporting / supervisor review (final-exercise steps 10 & 11): a supervisor
# user with a manager security profile can view Connect's native real-time +
# historical dashboards, contact search (routing decisions + attributes), and the
# email-routing-log audit table.
data "aws_connect_security_profile" "supervisor" {
  count       = var.supervisor_username != "" ? 1 : 0
  instance_id = aws_connect_instance.this.id
  name        = var.supervisor_security_profile_name
}

resource "aws_connect_user" "supervisor" {
  count = var.supervisor_username != "" ? 1 : 0

  instance_id          = aws_connect_instance.this.id
  name                 = var.supervisor_username
  password             = var.supervisor_password
  routing_profile_id   = aws_connect_routing_profile.email.routing_profile_id
  security_profile_ids = [data.aws_connect_security_profile.supervisor[0].security_profile_id]

  phone_config {
    phone_type  = "SOFT_PHONE"
    auto_accept = false
  }

  identity_info {
    first_name = var.supervisor_first_name
    last_name  = var.supervisor_last_name
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
