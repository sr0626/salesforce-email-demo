###############################################################################
# Console-authored Connect contact flows — versioned, drift-safe.
#
# These flows are built/edited in the Connect console (the flow designer) and
# exported to flows/*.json. This file keeps them under Terraform **without ever
# overwriting your manual console changes**:
#
#   lifecycle { ignore_changes = all }
#     -> once a flow is imported into state, `terraform apply` will NOT push the
#        flows/*.json content over the live (console-edited) flow. The JSON stays a
#        version-controlled reference; the console remains the editing surface.
#
#   count = var.manage_console_flows ? 1 : 0
#     -> off by default so TF can't create a DUPLICATE of the existing console flow.
#
# To (optionally) bring a flow into TF state — one-time:
#   1. set  manage_console_flows = true  in terraform.tfvars
#   2. terraform import 'aws_connect_contact_flow.email_inbound[0]'  <instance_id>:<flow_id>
#      terraform import 'aws_connect_contact_flow.email_agent_guide[0]' <instance_id>:<flow_id>
#      (flow_id = the contact-flow id from the console URL; instance_id below)
#   3. terraform plan  -> shows "0 to change" thanks to ignore_changes.
#
# instance_id: 0f141da4-0141-49a4-aa6f-a6fb9a3bb116
#
# NOTE: flows that are BUILT by Terraform (jsonencode in modules/connect) are NOT
# here and are managed normally: Email-Case-Routing, Owner-<key>-Routing.
###############################################################################

variable "manage_console_flows" {
  type        = bool
  description = "Track the console-authored flows (Email-Inbound-Routing, Email-Agent-Guide) in TF state after import. Even when true, lifecycle.ignore_changes=all means apply never overwrites manual console edits."
  default     = false
}

resource "aws_connect_contact_flow" "email_inbound" {
  count       = var.manage_console_flows ? 1 : 0
  instance_id = module.connect.instance_id
  name        = "Email-Inbound-Routing"
  type        = "CONTACT_FLOW"
  description = "Native-email inbound routing: Lambda flow-mode -> dynamic owner queue; Email-Case-Queue fallback on Lambda error"
  content     = file("${path.module}/flows/Email-Inbound-Routing.json")

  lifecycle {
    ignore_changes = all # never overwrite manual console edits
  }
}

resource "aws_connect_contact_flow" "email_agent_guide" {
  count       = var.manage_console_flows ? 1 : 0
  instance_id = module.connect.instance_id
  name        = "Email-Agent-Guide"
  type        = "CONTACT_FLOW"
  description = "SF-360 screen-pop guide (Show View / Detail) shown on email accept"
  content     = file("${path.module}/flows/Email-Agent-Guide.json")

  lifecycle {
    ignore_changes = all
  }
}
