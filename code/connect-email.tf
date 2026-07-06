###############################################################################
# Amazon Connect NATIVE EMAIL CHANNEL — outbound reply (final-exercise steps 3 & 9)
#
# STATUS: STAGED / NOT ACTIVE (everything below is commented out).
#   We prototyped the pieces in the console first (Manage email → Add Domain
#   ccaas.evolvity.com; Data storage → Email messages; a test address
#   support@ccaas.evolvity.com). This file CODIFIES that setup so we can manage
#   it as IaC when we cut over. It is intentionally left commented so:
#     • `terraform validate` / `apply` are unaffected right now, and
#     • we don't create duplicates of the console-created resources.
#
# TO ACTIVATE (when we do the real build):
#   1. Provider check — confirm the installed hashicorp/aws version supports
#      `aws_connect_email_address` and the `EMAIL_MESSAGES` storage type. Bump
#      `required_providers` in main.tf if needed.
#   2. Reconcile the console-prototyped resources — either `terraform import`
#      them (storage config + email address) OR delete them in the console and
#      let Terraform create them fresh.
#   3. Build the inbound EMAIL flow in the console, export its JSON to
#      flows/email-inbound.json, and reference it below (same pattern we used
#      for the task flow). The Lambda gets a "flow mode" entry that RETURNS the
#      routing decision (owner/queue) and keeps its SF side-effects.
#   4. Uncomment the block, set the bucket/flow refs, `terraform validate`, then
#      apply. Cut `ordersuccess@` over only after the test address is proven.
#
# Full design + open-question resolutions: docs/09-outbound-connect-email-plan.md
###############################################################################

# --- Master switch (kept out of the apply until we activate) -----------------
# variable "enable_connect_email" {
#   type        = bool
#   description = "Turn on the Connect native email channel (outbound). Keep false until the inbound flow is built and console-created resources are imported."
#   default     = false
# }
#
# variable "connect_email_local_part" {
#   type        = string
#   description = "Local part of the Connect email address. Use a test address first (support), then cut over to ordersuccess."
#   default     = "support"
# }
#
# variable "connect_email_display_name" {
#   type        = string
#   description = "Friendly sender name shown to customers on replies."
#   default     = "Evolvity Order Success"
# }
#
# variable "connect_email_messages_bucket" {
#   type        = string
#   description = "S3 bucket backing Connect's EMAIL_MESSAGES data storage. Console-prototyped as salesforce-email-demo-email-storage. The agent workspace fetches email bodies from here in-browser, so it needs a CORS policy (below)."
#   default     = "salesforce-email-demo-email-storage"
# }
#
# variable "connect_workspace_origin" {
#   type        = string
#   description = "Agent workspace origin for the CORS allow-list. Scheme+host only, NO trailing slash/path. New instances: https://<alias>.my.connect.aws"
#   default     = "https://salesforce-email-demo.my.connect.aws"
# }
#
# locals {
#   connect_email = var.enable_connect_email ? 1 : 0
# }

/* ─────────────── STAGED TERRAFORM (uncomment to activate) ───────────────────

# 1) EMAIL DATA STORAGE (S3) — where Connect stores email bodies/attachments.
#    Prototyped in console at: <bucket>/connect/salesforce-email-demo/EmailMessages
#    NOTE: import the console-created one, or delete it first, to avoid a clash.
resource "aws_connect_instance_storage_config" "email_messages" {
  count         = local.connect_email
  instance_id   = module.connect.instance_id
  resource_type = "EMAIL_MESSAGES"           # VERIFY this enum in the provider version

  storage_config {
    storage_type = "S3"
    s3_config {
      bucket_name   = module.email_storage.bucket_name   # or a dedicated *-email-storage bucket
      bucket_prefix = "connect/salesforce-email-demo/EmailMessages"

      # Use the existing customer-managed key (Connect's service role can use it
      # via the key's in-account "ViaService" statement).
      encryption_config {
        encryption_type = "KMS"
        key_id          = var.kms_key_arn
      }
    }
  }
}

# 1b) CORS on the EMAIL_MESSAGES bucket — REQUIRED for agents to view/reply.
#     Connect's agent workspace loads the email body directly from S3 in the
#     browser; without this the workspace shows:
#       "Failed to get email message … your CORS policy on your S3 bucket is invalid"
#     AllowedOrigins MUST be scheme+host only (no trailing slash). The console-
#     prototyped bucket is salesforce-email-demo-email-storage — import it or
#     manage it here on cutover.
resource "aws_s3_bucket_cors_configuration" "email_messages" {
  count  = local.connect_email
  bucket = var.connect_email_messages_bucket

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "PUT", "POST", "DELETE", "HEAD"]
    allowed_origins = [var.connect_workspace_origin]
    expose_headers  = ["x-amz-request-id", "x-amz-id-2", "ETag"]
    max_age_seconds = 3000
  }
}

# 2) INBOUND EMAIL FLOW — routes an inbound email to the owner's queue/agent.
#    Build it in the Connect flow designer (email-capable), then export JSON:
#      Entry → Check contact attributes (Email Subject / SES spam+virus verdict)
#            → Invoke AWS Lambda (routing Lambda in "flow mode": returns
#              ownerId/targetQueueArn; still does SF owner lookup / reassign
#              re-verify / Contact-Account 360 / EmailMessage logging)
#            → Set working queue (DYNAMIC, from the Lambda's returned attribute)
#            → Transfer to queue → Disconnect
#    aws_connect_contact_flow takes arbitrary flow JSON (as with the task flow).
resource "aws_connect_contact_flow" "email_inbound" {
  count       = local.connect_email
  instance_id = module.connect.instance_id
  name        = "Email-Inbound-Routing"
  type        = "CONTACT_FLOW"                # VERIFY correct type for email flows
  description = "Routes inbound Connect emails to the Salesforce Case Owner's queue"
  content     = file("${path.module}/flows/email-inbound.json")  # export from console
}

# 3) OUTBOUND EMAIL FLOW — applied to agent replies + agent-initiated outbound.
#    Can start from the built-in "Default outbound flow"; author a custom one if
#    you need branding/tracking. Export JSON like above.
# resource "aws_connect_contact_flow" "email_outbound" {
#   count       = local.connect_email
#   instance_id = module.connect.instance_id
#   name        = "Email-Outbound"
#   type        = "OUTBOUND_WHISPER"          # VERIFY outbound-email flow type
#   content     = file("${path.module}/flows/email-outbound.json")
# }

# 4) EMAIL ADDRESS — provisions <local_part>@<ses_domain> and binds the inbound flow.
#    Domain ccaas.evolvity.com is already SES-verified and added to Connect.
#    VERIFY the exact resource name + argument names against the provider docs
#    (aws_connect_email_address); flow-association arg may differ.
resource "aws_connect_email_address" "shared" {
  count         = local.connect_email
  instance_id   = module.connect.instance_id
  email_address = "${var.connect_email_local_part}@${var.ses_domain}"
  display_name  = var.connect_email_display_name
  description   = "Connect native email channel (outbound + inbound)"
  # inbound flow binding — CONFIRM arg name, e.g.:
  # inbound_flow_id = aws_connect_contact_flow.email_inbound[0].contact_flow_id
}

# 5) QUEUE + ROUTING PROFILE email config (may be console-only depending on
#    provider coverage — VERIFY):
#    - Queue: outbound email config → default From = the email address above +
#      the outbound email flow.
#    - Routing profile: add the EMAIL channel (media concurrency) + max contacts
#      (outbound-initiated = 2x that).
#    Extend modules/connect (queue/routing_profile) with these once confirmed.

# 6) SECURITY PROFILE permission "Contact Control Panel (CCP) - Initiate email
#    conversations" for agents who send replies. Built-in "Agent" profile may
#    need this added → console, or a custom aws_connect_security_profile.

──────────────────────────────────────────────────────────────────────────── */

###############################################################################
# WHAT WE KEEP from the task-based build (unchanged by this file):
#   - modules/email-router Lambda (SF owner lookup/create/360/logging/reassign) —
#     add a "flow mode" return path; drop StartTaskContact + the S3 rendered view.
#   - modules/email-storage DynamoDB (ownership + audit log).
#   - Owner->queue/agent mapping, agents, supervisor, quick connects.
#   - SES domain identity (ccaas.evolvity.com) — reused by Connect email.
# RETIRE when cutting ordersuccess@ over: the custom SES receipt rule
#   (route-to-email-router → our Lambda) so Connect ingests via StartEmailContact.
# Snapshot to fall back to: branch backup/task-based-architecture.
###############################################################################
