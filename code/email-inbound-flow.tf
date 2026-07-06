###############################################################################
# Connect inbound EMAIL contact flow (native email channel) — managed as code.
#
# Authored in the console (email-capable flow designer) and exported to
# flows/Email-Inbound-Routing.json. That file is the version-controlled source of
# truth; this resource applies it so the flow is reproducible IaC.
#
# Flow logic (flows/Email-Inbound-Routing.json):
#   Set event (DefaultAgentUI = Email-Agent-Guide)      -> screen-pop guide on accept
#   -> Invoke Lambda (email-case-router-lambda, flow mode)
#   -> Set contact attributes (caseId/ownerName/salesforceCaseUrl/ownerId from $.External)
#   -> Set working queue  (DYNAMIC $.External.targetQueueArn)   -> owner-targeted
#   -> Transfer to queue
#   Lambda-error branch -> Set working queue = Email-Case-Queue (shared fallback)
#
# The two load-bearing routing rules (do not regress):
#   * MAIN "Set working queue"  = dynamic  $.External.targetQueueArn  (owner routing)
#   * Lambda-ERROR "Set working queue" = manual Email-Case-Queue      (safety net)
# A manual queue on the MAIN path sends every email to the shared queue and defeats
# owner-targeting; a dynamic queue on the ERROR path drops the email on Lambda failure.
#
# ── ACTIVATION (one-time; the flow already exists in the console) ────────────
# Off by default (count=0) so it can't try to CREATE a duplicate on apply. To adopt
# the existing flow:
#   1. Ensure flows/Email-Inbound-Routing.json is the CURRENT export (re-export after
#      any console edit, e.g. the Lambda-error-branch fix).
#   2. Set  manage_email_inbound_flow = true  in terraform.tfvars.
#   3. Import the existing flow (flow_id = the Email-Inbound-Routing contact-flow id
#      from the console URL):
#        terraform import 'aws_connect_contact_flow.email_inbound[0]' \
#          0f141da4-0141-49a4-aa6f-a6fb9a3bb116:<flow_id>
#   4. terraform plan  (expect no/minor diff vs the exported JSON) -> terraform apply.
#
# NOTE: the exported JSON has hardcoded ARNs (Lambda, the Email-Agent-Guide flow,
# queues) — instance-specific. Full portability would templatefile() these; file()
# is fine for this instance.
###############################################################################

variable "manage_email_inbound_flow" {
  type        = bool
  description = "Manage the console-created Email-Inbound-Routing flow via Terraform. Keep false until you terraform import it (see this file) to avoid a duplicate-name create."
  default     = false
}

resource "aws_connect_contact_flow" "email_inbound" {
  count       = var.manage_email_inbound_flow ? 1 : 0
  instance_id = module.connect.instance_id
  name        = "Email-Inbound-Routing"
  type        = "CONTACT_FLOW"
  description = "Native-email inbound routing (Lambda flow-mode -> owner queue; Email-Case-Queue fallback on Lambda error)"
  content     = file("${path.module}/flows/Email-Inbound-Routing.json")
}
