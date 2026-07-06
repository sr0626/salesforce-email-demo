# Outbound reply via Amazon Connect native email channel — plan (steps 3 & 9)

**Status: BUILT + VERIFIED (2026-07-06).** `ordersuccess@` is live on the Connect
native email channel: inbound routes to the Salesforce Case Owner's queue → agent
reads/replies natively → reply delivered to an external inbox (**SPF+DKIM pass**);
the email logs to the SF Case with its **full HTML body**; agent-to-agent **quick-connect
transfer** works; and the agent gets a **Detail-view screen-pop with a clickable Case
link** on accept. Final-exercise **steps 3 & 9 complete.** The Task path remains on
`taskdemo@` (hybrid). Build history + gotchas below; deferred follow-ups: DMARC record,
attachments/inline images on the SF copy. Decisions locked 2026-07-05.

## Decisions locked (2026-07-05)
- **Hybrid, not full retire.** Keep the proven **task-based** path live on a
  **separate address** and stand up **native email on `ordersuccess@`**. Lower risk,
  easy rollback, and lets the demo show both. (Full cutover was considered and
  deferred.)
  - `ordersuccess@ccaas.evolvity.com` → **Connect native email** (real email contact;
    agent replies natively → steps 3 & 9). *This is the reqs-faithful demo.*
  - `taskdemo@ccaas.evolvity.com` → **existing Task path** (our custom SES rule → S3 +
    Lambda → `StartTaskContact`), unchanged.
- **SF Case reaches the agent via a workspace view/link — NOT a CTI screen-pop.**
  Verified 2026-07-05: the Amazon Connect **Salesforce CTI Adapter does not bridge the
  native email channel** (it covers voice/chat/task only — its "email" is Salesforce
  Omni-Channel presence, not a Connect email contact). So there is **no turnkey
  auto-navigation** into the Case for a native-email contact. That's acceptable: the
  Final Exercise requires the agent to *"open the interaction and **see**"* the 360 —
  satisfied by a contact-attribute-driven **agent-workspace view/guide** showing the
  Case deep link + owner + related cases (one click to the live Case). User confirmed
  a workspace link is good enough for this demo; literal auto-pop is a later
  enhancement (custom Streams + Open CTI bridge) if ever needed.
- **Why native email for the reply (not Salesforce):** Scenario 1's *"initiated from
  Salesforce"* governs the **thread origin** (the proactive first email that stamps the
  `Case #`), **not** the agent's reply to a customer response — which is what we're
  building. The reply belongs on the platform being evaluated (Connect), and native
  email is the only option that records **outbound as a first-class Connect
  interaction** (Scenario 4).

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

## What we ADD (for `ordersuccess@`) / simplify
- **Agent-workspace view** surfacing the SF Case deep link + owner + related cases
  from the Lambda-set contact attributes (the "opens and sees the 360" mechanism,
  since there's no native-email CTI screen-pop — see Decisions above).
- **S3 rendered-HTML view + `bodyPreview` not needed on the native-email path** —
  Connect shows the email natively. (These stay in use on the `taskdemo@` Task path.)
- For `ordersuccess@`, email = a real **email contact**, not a Task.

## What we DO NOT retire (hybrid)
- The **SES receipt rule → Lambda → `StartTaskContact`** path is **kept**, just
  **re-scoped** from `ordersuccess@` to **`taskdemo@ccaas.evolvity.com`**. Native
  email (`StartEmailContact`) handles `ordersuccess@`; the two never collide because
  SES receipt rules match by **recipient** (see SES wiring below).

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
- **Hybrid keeps the blast radius small** — the Task path stays intact on `taskdemo@`;
  we add native email on `ordersuccess@` alongside it (rollback = just point
  `ordersuccess@` back at the custom rule).
- Email channel is a **2024+ feature** — verify exact console/Terraform support
  (provider coverage for email addresses/flows may lag; some steps may be manual).
- One active SES receipt rule set per region — Connect email manages its own; our
  custom rule is **re-scoped** (`ordersuccess@` → `taskdemo@`), not removed. Watch for
  Connect re-sync dropping custom rules (re-add if the Task path stops).
- **No native-email CTI screen-pop** — the SF Case is a workspace link/view, not an
  auto-navigation (accepted; see Decisions).
- Confirm **Amazon Q in Connect** email-drafting availability before promising the
  AI angle.

## Open questions — RESOLVED (2026-07-05, ready to build)

### 1. Terraform vs console/CloudFormation coverage
Hybrid — like SES, some pieces are not in Terraform:

| Piece | IaC support | How we'll do it |
|---|---|---|
| Enable email on the instance (Manage email → Add Domain) | Domain add via console; domain itself is the SES-verified identity | **Console** (one-time) |
| **Email data storage** (S3 for message bodies/attachments) | **Terraform** `aws_connect_instance_storage_config` (resource_type `EMAIL_MESSAGES`) | **Terraform** ✅ |
| **Email address** (`ordersuccess@…`) | **Terraform** `aws_connect_email_address` (confirm provider version) — or CFN `AWS::Connect::EmailAddress` | **Terraform** (verify version); CFN/console fallback |
| Inbound/outbound **email flows** | `aws_connect_contact_flow` takes arbitrary flow JSON | Author in **console → export JSON → Terraform** (same approach we used for the task flow; email-specific blocks like *Send message* / *Check contact attributes* need verified JSON) |
| **Queue** email config (default From, outbound flow) | Partial — verify `aws_connect_queue` email fields in the current provider | Terraform if supported, else console |
| **Routing profile** email channel + max contacts | Likely Terraform (media concurrency) | Terraform (verify EMAIL channel enum) |
| Security perm **"Initiate email conversations"** | `aws_connect_security_profile` permissions, or built-in | **Console** (add to a profile) |

Net: **console/CFN for instance-email + email address + the "initiate email" permission; Terraform for flows/queues/routing where the provider supports it.** Document the manual pieces like doc 05 does for SES.

### 2. Lambda-in-flow routing (confirmed pattern)
Inbound **email contact flow**: **Check contact attributes** (Email Subject) → **Invoke AWS Lambda function** (our routing Lambda in "flow mode": returns `ownerId`/`targetQueueArn`, and still does the SF side-effects — owner lookup/reassign re-verify, contact/account 360, EmailMessage logging) → **Set working queue** *dynamically* from the returned attribute → route to the owner's queue/agent. So our routing logic is **reused**, just returning a decision instead of calling `StartTaskContact`.

### 3. S3 archival / rendered view — decision
**Drop** the S3 rendered-HTML view + `bodyPreview` — Connect shows the email natively. Keep the **Salesforce `EmailMessage`** logging as the system-of-record trail (and optionally keep raw S3 archival for audit; not required).

### 4. SES wiring (hybrid — both paths in one active rule set)
Only **one active SES receipt rule set per region**; Connect owns
**`AmazonConnectEnabledRuleSet-DO-NOT-DELETE`**. Receipt rules match by **recipient**,
so both paths coexist inside that one set:
- `ordersuccess@ccaas.evolvity.com` → Connect's rule → `StartEmailContact` (native email).
- `taskdemo@ccaas.evolvity.com` → our custom rule (`route-to-email-router` → S3 + Lambda → Task).

**Critical:** our custom rule is currently scoped to `ordersuccess@` — **re-scope its
recipient condition to `taskdemo@`** so it no longer matches `ordersuccess@` (otherwise
a double-match makes routing order-dependent). Domain `ccaas.evolvity.com` is SES-verified
and receives **any** local-part → `taskdemo@` needs no new DNS/verification. Known gotcha:
a Connect email re-sync can drop custom rules from this set — re-add if the task path
stops (see the SES receipt-rule note in project memory).

### 4b. Email-messages S3 bucket + CORS (done)
Connect's native-email **EMAIL_MESSAGES** data storage uses the console-created bucket
**`salesforce-email-demo-email-storage`** (separate from the TF-managed SES inbound
bucket `…-inbound-email-…`). The agent workspace fetches email bodies from it in-browser,
so it **requires a CORS policy** — without it the workspace shows *"Failed to get email
message … CORS policy on your S3 bucket is invalid."* **Fixed 2026-07-05:** CORS added
allowing origin `https://salesforce-email-demo.my.connect.aws` (scheme+host only, no
trailing slash). Codified (staged) as `aws_s3_bucket_cors_configuration.email_messages`
in `code/connect-email.tf`; import the console bucket on cutover.

### 5. Amazon Q in Connect (AI compose, future)
Plugs into the same agent workspace (generative response recommendations). **Verify email-drafting availability** before promising; not part of the initial build.

---

## Build checklist (ready to execute when we resume)
1. **SES address split (hybrid):** re-scope our custom receipt rule from `ordersuccess@`
   → **`taskdemo@ccaas.evolvity.com`** (keeps the Task demo working). Add
   `ordersuccess@ccaas.evolvity.com` to the Connect email channel so its rule ingests
   via `StartEmailContact`. Confirm no rule double-matches `ordersuccess@`.
2. **Console:** enable email on the instance; create address `ordersuccess@ccaas.evolvity.com`
   (verified domain). EMAIL_MESSAGES storage → bucket `salesforce-email-demo-email-storage`
   (CORS already applied ✅).
3. **Lambda:** add a "flow mode" entry that returns the routing decision (reuse owner
   lookup / reassign re-verify / SF 360 / email logging). Keep DynamoDB.
4. **Inbound email flow:** Check attributes (Subject) → Invoke Lambda → Set working queue
   (dynamic) → route. (Author in console, export JSON to Terraform.)
5. **Agent-workspace view:** surface the Lambda-set contact attributes (SF Case deep
   link + owner + related cases) as the agent's "sees the 360" panel (no CTI screen-pop —
   see Decisions). Author as a Connect view/guide.
6. **Queue/routing profile:** outbound email config (default From = `ordersuccess@…`,
   outbound flow) + enable EMAIL channel + max contacts.
7. **Console:** grant agents **"Initiate email conversations."**
8. **Templates** (signature / quick responses).
9. **SPF** TXT on `ccaas`: `v=spf1 include:amazonses.com ~all`.
10. **Test** the round trip on `ordersuccess@`: inbound → routed to owner's agent →
    agent reads + sees SF Case in workspace → replies → customer receives → reply loops
    back to the current owner. Confirm `taskdemo@` still creates Tasks.

## Cutover runbook (execute in order)

**Code — DONE (2026-07-05, staged in the working tree, not yet applied):**
- Lambda **flow mode** added: `handler` now dispatches SES event → Task path,
  Connect flow event → returns the routing decision. Shared `_resolve_routing` core;
  new `connect_flow.build_response`. Endpoints normalized with `parseaddr` so the
  ownership key matches the SES path. Smoke-tested (stubbed): Case# → owner queue,
  unmapped owner → fallback queue, SES mode intact. `terraform validate` clean.
- New Lambda env: `OWNER_QUEUE_MAP` (ownerId→queueArn), `FALLBACK_QUEUE_ARN`. Root
  vars `owner_queue_map` / `fallback_queue_arn` (default empty) → set in tfvars once
  the native-email queues exist.

**Console / AWS / DNS — YOUR steps (Claude won't run these):**
1. **SES address split.** Edit our custom receipt rule: change recipient
   `ordersuccess@` → **`taskdemo@ccaas.evolvity.com`**. Confirm no rule still matches
   `ordersuccess@` except Connect's. In **tfvars** set
   `shared_mailboxes = "ordersuccess@ccaas.evolvity.com,taskdemo@ccaas.evolvity.com"`
   so both are treated as shared, then `apply`.
2. **Connect Manage email.** Domain `ccaas.evolvity.com` already added → create
   address **`ordersuccess@ccaas.evolvity.com`**; bind it to the inbound email flow
   (step 4). EMAIL_MESSAGES storage bucket CORS already applied ✅.
3. **Apply Terraform** — ships the flow-mode Lambda (in-place update) **and** creates
   `aws_connect_lambda_function_association.email_router`, which associates the Lambda
   with the Connect instance so flows may invoke it (codified, not a console click).
4. **Inbound email flow** (flow designer, email-capable):
   `Entry → Set contact attributes (capture the email Subject into attribute
   'emailSubject') → Invoke AWS Lambda (email-case-router-lambda; pass Parameter
   emailSubject = the captured subject) → Set contact attributes from $.External
   (ownerName, caseId, salesforceCaseUrl) → Set working queue = $.External.targetQueueArn
   (if empty, branch to a default queue) → Transfer to queue`. Export JSON →
   `flows/email-inbound.json` → wire `aws_connect_contact_flow.email_inbound`.
   *(The Lambda also reads CustomerEndpoint/SystemEndpoint automatically, so passing
   fromAddress/mailbox as Parameters is optional.)*
5. **Agent-workspace view** showing `$.External.salesforceCaseUrl` as a Case link +
   `ownerName`/`caseId` (the "opens and sees the 360" panel).
6. **Queue + routing profile:** owner queues get outbound email config (default From =
   `ordersuccess@…`, outbound flow); enable the **EMAIL** channel on the owners'
   routing profiles. Put the queue ARNs in tfvars `owner_queue_map` /
   `fallback_queue_arn` → `apply`.
7. **Security profile:** grant agents **"Initiate email conversations."**
8. **SPF** TXT on `ccaas`: `v=spf1 include:amazonses.com ~all`.
9. **Test** `ordersuccess@` round trip + confirm `taskdemo@` still creates Tasks.

## Step 9 — SF Case screen-pop in the agent workspace (Detail view)

**Goal:** when the agent opens the email, they see the 360 — a **clickable Salesforce
Case link** + owner + case #, from the contact attributes the inbound flow already
sets (`salesforceCaseUrl`, `ownerName`, `caseId`). Mechanism = an AWS-managed
**Detail view** shown via a **Show view** block (Connect's native "screen pop").
Ref: https://docs.aws.amazon.com/connect/latest/adminguide/display-contact-attributes-sg.html

**Status: DONE (2026-07-06).** On email accept, the agent workspace screen-pops the
Detail view with the **clickable Salesforce Case link** + owner, from the contact
attributes the inbound flow set, and **the panel persists** while the agent works the
email. Requirement ("agent opens the interaction and sees the 360") met.

**Key gotcha (resolved):** the "You have successfully completed the work flow" screen
was the Show View block's **`Timeout` branch** firing — the default timeout is short.
**Fix = raise the Show View block timeout (set to 5 minutes)**; the panel then stays up
for the whole handle time. No Loop block needed (a direct self-loop is rejected by the
designer anyway). Bump the timeout higher if agents need longer than 5 min on one email.

**Layout note:** the workspace is fixed — CCP/email on the left, guide/view in the main
area; not repositionable (theming + 3P apps only).

### Mechanism (confirmed from AWS docs)
- The **Show view** block renders an AWS-managed **Detail** view in the agent
  workspace. It's supported on the **email** channel, and lives in an **Inbound
  flow** type. (Views are under **UI Management → Views**; "Detail" is AWS Managed.)
- Because email is async, the agent screen-pop is triggered by a **"Set event"**
  block in the main inbound flow that launches a **separate guide flow** (containing
  the Show view block) when the agent connects to the contact.
- Agents need security-profile permission **"Agent Applications - Custom views -
  All"** to *see* guides; authors need **"Channels and flows - Views"**.
- The guide flow reads the contact attributes the inbound flow already set
  (`caseId`, `ownerName`, `salesforceCaseUrl`) — same contact, so `$.Attributes.*`
  is available.

### Build parts
1. **Guide flow** — new Inbound flow (e.g. `Email-Agent-Guide`): `Start → Show view
   (Detail, Set JSON below) → Disconnect`. Publish.
2. **Set event** — in `Email-Inbound-Routing`, a `Set event` block registers the
   guide flow to run on agent-connect (before/independent of the queue transfer).
3. **Permission** — add **Agent Applications - Custom views - All** to the agents'
   security profile.

### Show view → Detail, Set JSON (the clickable Case link)
```json
{
  "Heading": "Salesforce 360",
  "AttributeBar": [
    { "Label": "Case",  "Value": "$.Attributes.caseId",   "LinkType": "external", "Url": "$.Attributes.salesforceCaseUrl" },
    { "Label": "Owner", "Value": "$.Attributes.ownerName" }
  ]
}
```

### Confirmed console steps
_(filled in as each block is verified)_
1. Flows → Create flow types confirmed (no dedicated "guide" type; use Inbound flow). Show view block lives under **Integrate**.
2. **Guide flow `Email-Agent-Guide` built + published:** `Start → Show View (View: Detail, AttributeBar Set-JSON = Case external link + Owner) → Disconnect`. The Show View block has 5 output branches (ActionSelected, Back, No Match, Error, Timeout) — wire **all five → Disconnect**.
3. **Trigger via `Set event flow` block in `Email-Inbound-Routing`:** event hook = **"Default flow for Agent UI"**, flow = `Email-Agent-Guide` (Set manually). Placed inline near Start. This makes the agent workspace run the guide (→ screen-pop) when the agent accepts the email. Re-publish the inbound flow.
4. **Permission:** add **Agent Applications - Custom views - All** to the agents' security profile.
5. **Detail view requires a `Sections` component** (not just AttributeBar) — set a `Sections` Set-JSON (e.g. a one-line `TemplateString`) or the view errors out on render.
6. **Raise the Show View block `Timeout` to 5 min** so the panel persists (default is short → it was auto-completing).

## What we keep from the task-based build (snapshot: branch `backup/task-based-architecture`)
Salesforce Lambda logic (owner lookup/create/360/logging/reassign re-verify),
DynamoDB tables, owner→queue/agent mapping, agents, supervisor, quick connects.

## Residual risks
- Exact provider coverage for queue email-config / email flow JSON (verify at build).
- Amazon Q email-drafting availability.
