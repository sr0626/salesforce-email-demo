# Outbound reply via Amazon Connect native email channel — plan (steps 3 & 9)

**Status:** PLAN ONLY — not built yet. Decision rationale below.

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

## Open questions to resolve at build time
- Terraform coverage for Connect email addresses + email flows (vs. console).
- How to invoke the routing Lambda from the email flow and read its result to set
  the queue (dynamic "Set working queue").
- Whether to keep any S3 archival of raw email for audit.
