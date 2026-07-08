# Operations Runbook — CCaaS Email-Routing POC

Day-2 operational reference for the whole stack: deploy/redeploy, the console-only
steps Terraform can't reproduce, feature toggles & cost levers, per-component ops,
validation, troubleshooting, secrets, teardown, and a resource inventory.

This is the **"how to run it"** doc. For **why** and **build spec** see
[00-context](00-context.md) / [01-architecture](01-architecture.md) /
[02-implementation-spec](02-implementation-spec.md); for **current feature status**
see [08-implementation-status](08-implementation-status.md).

> **Global rules:** never run `git` or AWS CLI without explicit per-command OK; never
> auto-claim a phone number. `terraform.tfvars` and tfstate are **gitignored** (hold
> secrets) — never commit them.

---

## 1. Component map (what's deployed)

| Layer | Resource | Managed by |
|---|---|---|
| Telephony/CCaaS | Amazon **Connect** instance, queues, routing profiles, contact flows, agents/supervisor | Terraform (`modules/connect`) + **console** for native-email bits (§4) |
| Inbound email | **SES** domain `ccaas.evolvity.com`, DKIM, receipt rule → S3, mailboxes `ordersuccess@` (native) / `taskdemo@` (Task) | **Console/manual** ([05](05-setup-ses-evolvity.md)) |
| Compute | **Lambda** `email-case-router-lambda` (4 modes: SES-task, flow, outbound-log, sla_check) | Terraform (`modules/email-router`) |
| State/audit | **DynamoDB** `…-mailbox-ownership`, `…-email-routing-log` (both `PAY_PER_REQUEST`) | Terraform (`modules/email-storage`) |
| Email bodies | **S3** inbound bucket (SES raw) + Connect **EMAIL_MESSAGES** bucket (native) | TF (inbound) / console (EMAIL_MESSAGES) |
| CRM | **Salesforce** Dev org; secret in **Secrets Manager** (Client Credentials OAuth) | TF seeds placeholder; **value set post-apply** ([06](06-setup-salesforce-dev-org.md)) |
| Eventing | **EventBridge** rules: `…-outbound-email-completed` (S4-B), `…-sla-check` (owner-timeout) | Terraform |
| Alerts | **SES HTML email** — owner-timeout alert from `sla_from_address` (verified domain) → `sla_alert_email` | Terraform (IAM `ses:SendEmail`) |
| Encryption | Customer-managed **KMS** key (S3/DynamoDB/Secrets/Lambda env) | pre-existing key, referenced |

Region **us-west-2**, account **044336301301**, instance alias **salesforce-email-demo**.

---

## 2. Prerequisites (one-time)

See [03-prerequisites-and-setup](03-prerequisites-and-setup.md). In short: Terraform ≥1.6,
AWS creds, the SES subdomain + DNS (MX/DKIM/SPF), a Salesforce Dev org + Connected App,
and the KMS key (its policy already allows SES).

---

## 3. Deploy / redeploy

```bash
cd code
terraform init      # first time
terraform plan      # always eyeball before apply
terraform apply
```

**Post-apply steps (not in Terraform):**
1. **Salesforce secret** — put the real Client Credentials into the seeded secret
   (`salesforce_secret_name` output) — [06](06-setup-salesforce-dev-org.md).
2. **SES receipt rule** — point the SES rule's Lambda action at `email_router_lambda_arn`;
   accept the "Allow SES to invoke" prompt — [05](05-setup-ses-evolvity.md).
3. **Console-only Connect config** — §4 below (native email is not fully TF-able).
4. **SLA alert delivery is SES** — no subscription step. Just ensure `sla_from_address`
   is at the verified `ccaas.evolvity.com` domain (any local part works).

> Local state. The Lambda re-zips from `src/` on every apply (source hash), so a code
> change just needs `terraform apply`.

---

## 4. Console-only config checklist (Terraform can't reproduce these)

The AWS provider (6.x) has gaps around Connect's native email channel. After a rebuild,
redo these **in the console** — `terraform apply` won't revert them, but can't create them:

1. **Native email channel** — enable Email on the instance; create the `ordersuccess@`
   address; wire the **inbound email flow** (published) — [09](09-outbound-connect-email-plan.md).
2. **Queue Outbound email configuration** — per queue set Default email address =
   `ordersuccess@` (provider has no `outbound_email_config`). Outbound email flow optional.
3. **Manual assignment (cherry-pick, S3)** — set `Email-Case-Queue` → *Manual assignment*
   (Email) on `Email-Routing-Profile`, `Owner-epic-Profile`, `Owner-sateesh-Profile`.
4. **Security permission** — *Allow 'Assign to me' for any contact* (Contact actions) on
   the **Agent** security profile.
5. **Quick responses** — bulk-import [email-quick-responses.csv](email-quick-responses.csv)
   (Content Management → Quick responses); needs a re-index/re-save before agents see them.
6. **Screen-pop view** — the Show View block uses the managed **Detail view** (a Custom
   View is deferred — see gap in [08](08-implementation-status.md)).
7. **Message templates / Amazon Q** — creating a Q-in-Connect knowledge base currently
   **fails ("UnknownError")** — message templates + all S8 AI features are blocked on this.

---

## 5. Feature toggles & cost levers (all in `terraform.tfvars`)

The stack is **100% pay-as-you-go** — nothing provisioned (both DynamoDB tables
`PAY_PER_REQUEST`; no provisioned/reserved Lambda concurrency; no Kinesis). Toggles let
you disable optional pieces so nothing fires when idle.

| Variable | Default | Effect |
|---|---|---|
| `sla_alert_enabled` | `false` | Owner-timeout schedule rule **state** (DISABLED until a demo). |
| `sla_alert_email` | `""` | Supervisor recipient(s) of the SLA email (SES). Comma-separated for multiple; empty disables. |
| `sla_from_address` | `""` | SLA email From — a verified SES identity (any local part at `ccaas.evolvity.com`, e.g. `alerts@…`). Empty disables. |
| `sla_threshold_seconds` | `300` | SLA breach threshold (demo: `120`). |
| `sla_check_rate` | `rate(5 minutes)` | SLA poll cadence (demo: `rate(1 minute)`). |
| `sla_realert_minutes` | `60` | Re-alert cooldown — don't re-email the same queue within this window (stops per-tick spam). |
| `sla_context_hours` | `24` | How far back the alert pulls email context (sender/subject/time/case) from the routing log. |
| `outbound_log_enabled` | `true` | S4-B outbound-log rule state; `false` = no invokes when idle. |
| `flow_debug` | `false` | Verbose Lambda payload logging (PII) — troubleshooting only. |
| `auto_create_case` | `true` | New inquiry with no case/owner → create a SF Case. |
| `case_status_on_reply` | `Working` | On the agent's first reply, advance `Case.Status` from `New` → this. Empty disables. Never overrides Working/Escalated/Closed; closing stays manual. |
| `log_email_to_salesforce` | `true` | Log inbound/outbound emails to the SF Case. |
| `link_customer_to_contact` | `true` | Match/create SF Contact/Account for the 360. |

**Cost:** EventBridge (AWS-service events + scheduled triggers), `GetCurrentMetricData`,
and Lambda invokes are effectively **$0** at POC volume (free tiers); SES email is
~$0.10 per 1,000 messages (a handful of alerts = pennies). Real cost drivers are
**Amazon Connect** usage — not these.
Between demos, set `sla_alert_enabled=false` (and optionally `outbound_log_enabled=false`)
so both EventBridge rules sit DISABLED → zero invocations.

---

## 6. Day-2 operations

### Add / remove an owner (agent)
Edit the `agents` map in `terraform.tfvars` (username/password/name +
`salesforce_owner_id`) and `apply`. Each owner auto-gets a queue + routing profile +
contact flow + user; `owner_queue_map`/`owner_flow_map` are derived from the same map.
Full detail: [10-managing-agents](10-managing-agents.md). **Re-do the console-only
manual-assignment step (§4.3) for any new routing profile.**

### Quick responses / templates
Edit [email-quick-responses.csv](email-quick-responses.csv) → re-import (§4.5). Content
starts with `{{Attributes.greeting}}` for name personalization (the routing Lambda sets
`greeting`, the inbound flow maps `greeting = $.External.greeting`). Branded email template:
[message-template-branded-reply.html](message-template-branded-reply.html) (blocked on the
Q KB issue for now — §4.7).

### Owner-timeout SLA alert (gap #5)
When an email sits unhandled in an owner's queue past the threshold, a supervisor is
emailed. **No overflow queue by design** — the alert prompts action instead of reassigning.

- **Flow:** EventBridge schedule → Lambda `sla_check` mode → Connect `GetCurrentMetricData`
  (`OLDEST_CONTACT_AGE` + `CONTACTS_IN_QUEUE`, channel EMAIL) across all owner queues +
  fallback → **SES HTML email** on breach (from `sla_from_address` → `sla_alert_email`).
- **Consolidated:** one email covers **all** breaching queues (never one email per queue).
  Subject leads with severity — `SLA alert: N email(s) unhandled, oldest <dur>`.
- **Alert content (HTML):** a **summary table** (Queue / Owner-agent / Waiting / Oldest)
  then one block **per breaching queue** — friendly **queue name** (`DescribeQueue`) +
  **owner/agent** (`owner_name_map`; fallback = "Shared / unassigned"), with the queue's
  emails listed **under it** — each with its own **`waiting <dur>`** chip (now − received),
  sender, received time, and a **Salesforce Case pill** (blue link when `sfCaseId` is known,
  grey otherwise). Emails are grouped by owner→queue from the `email-routing-log` and
  **capped at the waiting count** so it reconciles; a `· … +N more not listed` line covers
  any gap. Ends with an **Open Amazon Connect** button (base access URL — role-neutral for
  the supervisor recipient). Durations use a rollup format (`10h 20m`, `1d 16h`). A
  **plain-text alternative** is sent alongside. Note: the metric gives the count/age, not
  the individual contacts, so the per-queue emails are the *most recent routed there*
  (exact in the no-agent demo; a close proxy in production).
- **No per-tick spam:** a **global re-alert cooldown** (`sla_realert_minutes`, default 60)
  records one marker row (`_ALL`) in the routing-log table and suppresses re-emailing while
  a standing breach persists — one consolidated email per window, not per queue.
- **Enable for a demo:** set `sla_alert_enabled=true`, `sla_threshold_seconds=120`,
  `sla_check_rate="rate(1 minute)"`, `sla_alert_email="…"`, then `apply`.
- **Validate fast:** invoke `email-case-router-lambda` with test event
  `{"task":"sla_check"}` → `{"status":"ok","queues":N,"breaches":M}`; `breaches>0` sends
  the alert email. **Live:** leave an email to `ordersuccess@` unhandled past the threshold.
- **Wind down:** `sla_alert_enabled=false` → `apply` (rule DISABLED, zero polling).

### Outbound → Salesforce logging (S4-B)
Automatic when `outbound_log_enabled=true`: an agent reply → EventBridge → Lambda
outbound-log mode → **Outgoing `EmailMessage`** on the Case. Review on the SF Case
**feed ("All Updates")** / **Emails** related list (Activity History may show only the
latest — not a gap). Disable with `outbound_log_enabled=false`.

---

## 7. Validate / smoke test

- **Lambda logic (offline):** the stub harness exercises flow-mode + outbound-log +
  dup-alert + greeting + `sla_check` — all asserts must pass (see the scratchpad harness;
  no AWS needed).
- **End-to-end scenarios:** [04-verification-plan](04-verification-plan.md) and
  [07-demo-walkthrough](07-demo-walkthrough.md).
- **Routing audit:** every decision is a row in the `…-email-routing-log` table
  (case, owner, outcome, contactId, timestamp).

---

## 8. Troubleshooting (known gotchas)

| Symptom | Cause / fix |
|---|---|
| Quick responses don't show for the agent | Post-import **index lag** — re-save each (add a space) to force re-index; re-login not required. |
| `{{Attributes.greeting}}` renders literally | The inbound **contact flow wasn't published** (or `greeting` attr not set). Publish the flow (it sets `greeting = $.External.greeting`). |
| Case # not detected | Subject needs the word **"Case"** + 5–10 digits (`Case\s*[#:]?\s*(\d{5,10})`). A bare number is intentionally not matched → falls to ownership/auto-create. |
| Outbound reply fails SPF/DMARC | SPF/DKIM pass on `ccaas.evolvity.com`; **DMARC** FAILs only because no record is published — publish `_dmarc.ccaas.evolvity.com` TXT (see [08 §limitations](08-implementation-status.md)). |
| Message templates / AI won't create | Amazon **Q-in-Connect KB creation fails ("UnknownError")** — blocks templates + S8. Deferred. |
| Historical metrics look empty | Default report range can **exclude the current day** — extend the range; "Contacts handled" counts only **accepted** contacts. |
| Extra chat/API contacts in reports | Step-by-step guides / the Show-view screen-pop create companion API-chat contacts — filter **Channel=Email**. |
| SLA alert didn't fire | Check `sla_alert_enabled=true`, `sla_from_address`/`sla_alert_email` set, the rule is ENABLED, and an email actually exceeded the threshold; invoke `{"task":"sla_check"}` and read the return (`no-recipient` = From/To unset). **Gotcha (fixed 2026-07-08):** `connect:GetCurrentMetricData` authorizes at the **queue** sub-resource, so the IAM grant must be `[instance_arn, "${instance_arn}/*"]` — an instance-only ARN gets `AccessDeniedException` on the queue and the invocation throws (no alert). SES send needs `sla_from_address` to be a **verified** identity. |
| Flow payload debugging | Set `flow_debug=true` (logs full events incl. PII) → inspect CloudWatch → turn off. |

---

## 9. Secrets

The Salesforce **client secret** lives only in Secrets Manager (never in tfvars/git). To
rotate: update the Connected App, then `aws secretsmanager put-secret-value` on
`salesforce_secret_name` (see [06](06-setup-salesforce-dev-org.md)). The Lambda reads it
per-invocation, so no redeploy is needed.

---

## 10. Teardown

`terraform destroy` removes the TF-managed pieces (Connect instance, Lambda, DynamoDB,
EventBridge, IAM, inbound bucket). **Manual cleanup:** SES receipt rule/domain,
native-email channel + EMAIL_MESSAGES bucket, quick responses, and the Salesforce
Connected App are console-created — remove them by hand. The KMS key is pre-existing —
do **not** delete it.

---

## 11. Resource inventory (2026-07-07, us-west-2 / 044336301301)

| Resource | Name / ARN |
|---|---|
| Connect instance alias | `salesforce-email-demo` (`https://salesforce-email-demo.my.connect.aws`) |
| Router Lambda | `email-case-router-lambda` |
| DynamoDB (ownership) | `salesforce-email-demo-mailbox-ownership` |
| DynamoDB (routing log) | `salesforce-email-demo-email-routing-log` |
| SLA alert delivery | **SES** — From `alerts@ccaas.evolvity.com` (verified domain) → `skrudrangi@gmail.com` |
| EventBridge (SLA) | `email-case-router-lambda-sla-check` |
| EventBridge (outbound) | `email-case-router-lambda-outbound-email-completed` |
| Shared mailboxes | `ordersuccess@ccaas.evolvity.com` (native), `taskdemo@ccaas.evolvity.com` (Task) |
| Owners (agents) | `agent.epic` (005dL00001nclyrQAA), `agent.sateesh` (005dL00001o4jcLQAQ) |
| KMS key | `arn:aws:kms:us-west-2:044336301301:key/71cf9f1f-81c0-4cc4-8534-6682359b842e` |

Names derive from `instance_alias` / `lambda_function_name` in `terraform.tfvars`; the
`terraform output`s surface the live ARNs.
