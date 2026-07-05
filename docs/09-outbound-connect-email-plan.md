# Outbound reply via Amazon Connect native email channel — plan (steps 3 & 9)

**Status:** PLAN — **build-ready** (open questions resolved 2026-07-05; see the
"Build checklist" near the end). Not built yet. Decision rationale below.

## Why Connect (not Salesforce) for the reply
Final-exercise steps **3 ("agent responds from a shared mailbox")** and **9
("agent sends a response")** don't name Salesforce — they're platform-agnostic and
sit inside the "demonstrate *your platform* end-to-end" exercise (the primary
evaluation criterion). Scenario 1's "outbound initiated from Salesforce" describes
the *thread origin* (the proactive email that stamps the `Case #`), not the agent's
reply. So the reply belongs on the platform being evaluated → **Amazon Connect**.
Bonus: it's the path to AI-assisted drafting via **Amazon Q in Connect** (the
Scenario 8 future-state).

## Target architecture (Connect email channel)
Amazon Connect has a native **email channel**: SES receives the mail and invokes
**`StartEmailContact`**; the email becomes an email *contact* the agent reads and
**replies to natively** in the agent workspace (rich-text editor, templates,
signatures, quick responses, full thread view). Connect sends the reply via SES.

```
Customer email → SES (ccaas.evolvity.com, already verified)
   → SES invokes StartEmailContact (Connect-managed receipt rule)
   → Inbound EMAIL contact flow:
        • Check contact attributes (Email Subject)  ← Case # visible natively
        • Invoke Lambda (our Salesforce logic) → returns owner/targetQueue
        • Set working queue (owner-targeted) → route to owner's agent
   → Agent reads + replies in the workspace  (steps 3 & 9)
   → Connect sends via SES from ordersuccess@ccaas.evolvity.com
```

## What we KEEP (adapt)
- **Salesforce routing Lambda** — owner lookup, case create, Contact/Account
  linkage, email logging — but **invoked from the email flow** (returns the
  routing decision / does its SF side-effects) instead of calling
  `StartTaskContact`.
- **DynamoDB** ownership fallback + audit log.
- **Owner-targeted routing** — per-owner queues/agents (or set queue dynamically
  from the Lambda's `targetQueueId`).
- The **agents** and security profiles.

## What we RETIRE / simplify
- Our **SES receipt rule → Lambda → `StartTaskContact`** inbound path (replaced by
  Connect's email ingestion via `StartEmailContact`).
- **S3 rendered-HTML view + `bodyPreview`** — Connect shows the email natively, so
  the custom email view is no longer needed (S3 raw store optional for audit).
- Email = a real **email contact**, not a Task.

## Setup steps (to build later)
1. **Enable email** on the Connect instance → auto address + up to 5 custom
   addresses under an **SES-verified domain** (we have `ccaas.evolvity.com`). Note:
   the `AmazonConnectEnabledRuleSet-DO-NOT-DELETE` we saw earlier is Connect's
   email receipt rule set.
2. **Create email address** `ordersuccess@ccaas.evolvity.com` in Connect.
3. **Queue outbound config** — default From = `ordersuccess@…`; pick/author an
   **Outbound email flow**.
4. **Routing profiles** — enable the **email** channel; set max contacts per agent
   (outbound-initiated = 2× that).
5. **Inbound email flow** — Check contact attributes (Email Subject) + **Invoke
   Lambda** (our owner lookup) + Set working queue → route.
6. **Message templates** (signature/disclaimer/quick responses).
7. **Security profile** — grant agents **"CCP – Initiate email conversations."**
8. **Outbound subject** must carry `Case #NNNNN` (template) so replies keep
   threading/routing.

## Prerequisites
- SES domain verified ✅ (`ccaas.evolvity.com`)
- SES production access ✅ (granted)
- **SPF TODO**: add `v=spf1 include:amazonses.com ~all` on `ccaas` for
  deliverability.

## Effort / risks
- **Significant re-architecture** of the email path (biggest change so far).
- Email channel is a **2024+ feature** — verify exact console/Terraform support
  (provider coverage for email addresses/flows may lag; some steps may be manual).
- One active SES receipt rule set per region — Connect email manages its own; our
  custom rule must be reconciled/removed for `ordersuccess@`.
- Confirm **Amazon Q in Connect** email-drafting availability before promising the
  AI angle.

## Open questions — RESOLVED (2026-07-05, ready to build)

### 1. Terraform vs console/CloudFormation coverage
Hybrid — like SES, some pieces are not in Terraform:

| Piece | IaC support | How we'll do it |
|---|---|---|
| Enable email on the instance | Not a documented `aws_connect_instance` arg | **Console/API** |
| **Email address** (`ordersuccess@…`) | **No Terraform resource**; CloudFormation **`AWS::Connect::EmailAddress`** exists; API `CreateEmailAddress` | **Console** (or a tiny CFN stack / SDK) — not Terraform |
| Inbound/outbound **email flows** | `aws_connect_contact_flow` takes arbitrary flow JSON | Author in **console → export JSON → Terraform** (same approach we used for the task flow; email-specific blocks like *Send message* / *Check contact attributes* need verified JSON) |
| **Queue** email config (default From, outbound flow) | Partial — verify `aws_connect_queue` email fields in the current provider | Terraform if supported, else console |
| **Routing profile** email channel + max contacts | Likely Terraform (media concurrency) | Terraform (verify EMAIL channel enum) |
| Security perm **"Initiate email conversations"** | `aws_connect_security_profile` permissions, or built-in | **Console** (add to a profile) |

Net: **console/CFN for instance-email + email address + the "initiate email" permission; Terraform for flows/queues/routing where the provider supports it.** Document the manual pieces like doc 05 does for SES.

### 2. Lambda-in-flow routing (confirmed pattern)
Inbound **email contact flow**: **Check contact attributes** (Email Subject) → **Invoke AWS Lambda function** (our routing Lambda in "flow mode": returns `ownerId`/`targetQueueArn`, and still does the SF side-effects — owner lookup/reassign re-verify, contact/account 360, EmailMessage logging) → **Set working queue** *dynamically* from the returned attribute → route to the owner's queue/agent. So our routing logic is **reused**, just returning a decision instead of calling `StartTaskContact`.

### 3. S3 archival / rendered view — decision
**Drop** the S3 rendered-HTML view + `bodyPreview` — Connect shows the email natively. Keep the **Salesforce `EmailMessage`** logging as the system-of-record trail (and optionally keep raw S3 archival for audit; not required).

### 4. SES wiring
Connect email uses the **`AmazonConnectEnabledRuleSet-DO-NOT-DELETE`** receipt rule set (SES → `StartEmailContact`). Our current custom rule (`route-to-email-router` → our Lambda) for `ordersuccess@` must be **removed/replaced** so Connect ingests. Domain `ccaas.evolvity.com` is already SES-verified → usable for the Connect email address.

### 5. Amazon Q in Connect (AI compose, future)
Plugs into the same agent workspace (generative response recommendations). **Verify email-drafting availability** before promising; not part of the initial build.

---

## Build checklist (ready to execute when we resume)
1. **Console:** enable email on the instance; create address `ordersuccess@ccaas.evolvity.com` (verified domain); **retire our custom SES receipt rule** for that recipient.
2. **Lambda:** add a "flow mode" entry that returns the routing decision (reuse owner lookup / reassign re-verify / SF 360 / email logging). Keep DynamoDB.
3. **Inbound email flow:** Check attributes (Subject) → Invoke Lambda → Set working queue (dynamic) → route. (Author in console, export JSON to Terraform.)
4. **Queue/routing profile:** outbound email config (default From, outbound flow) + enable EMAIL channel + max contacts.
5. **Console:** grant agents **"Initiate email conversations."**
6. **Templates** (signature / quick responses).
7. **SPF** TXT on `ccaas`: `v=spf1 include:amazonses.com ~all`.
8. **Test** the round trip: inbound → agent reads → replies → customer receives → reply loops back to owner.

## What we keep from the task-based build (snapshot: branch `backup/task-based-architecture`)
Salesforce Lambda logic (owner lookup/create/360/logging/reassign re-verify),
DynamoDB tables, owner→queue/agent mapping, agents, supervisor, quick connects.

## Residual risks
- Exact provider coverage for queue email-config / email flow JSON (verify at build).
- Amazon Q email-drafting availability.
