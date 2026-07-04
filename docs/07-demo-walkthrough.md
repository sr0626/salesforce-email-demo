# Demo Walkthrough — how it works end-to-end + live demo script

## The one-sentence pitch
A customer emails a shared mailbox; the system automatically identifies the
owning agent — via a live Salesforce Case lookup, or by remembering who owned
the customer's prior thread — and delivers an Amazon Connect Task **straight to
that owner's agent**, carrying the case, owner, and a preview + link to the
email, with no human triage.

## The flow (what happens to one email)
1. **Customer sends email** → `ordersuccess@ccaas.evolvity.com`.
2. **DNS/MX** for `ccaas.evolvity.com` points at Amazon SES
   (`inbound-smtp.us-west-2.amazonaws.com`), so the mail is delivered to SES
   (domain is DKIM-verified).
3. **SES receipt rule** (`route-to-email-router`, in the active rule set) matches
   the recipient and runs two actions:
   - **Deliver to S3** → raw email saved to
     `s3://salesforce-email-demo-inbound-email-<acct>/inbound/` (encrypted with
     the CMK).
   - **Invoke Lambda** (`email-case-router-lambda`, async) → SES passes an event
     with parsed headers (subject, from, to).
4. **Lambda decides the owner:**
   - Parse the subject for `Case #NNNNN`.
   - **Case # found (Scenario 1):** get a Salesforce token (Client Credentials,
     creds from Secrets Manager) → SOQL `SELECT OwnerId, Owner.Name FROM Case
     WHERE CaseNumber=...` → resolve owner. Save owner for this
     (mailbox, customer) in DynamoDB `mailbox-ownership`. Outcome = `resolved`.
   - **No Case # (Scenario 2):** look up DynamoDB `mailbox-ownership` for
     (mailbox, customer) → the last-known owner from a prior case. Outcome =
     `fallback` (or `unassigned` if never seen).
5. **Lambda enriches:** reads the raw MIME from S3, decodes a **body preview**,
   and generates a **presigned URL** to the full raw email.
6. **Create Connect Task** via `StartTaskContact`, routed through the **owner's
   dedicated contact flow** (picked from `OWNER_FLOW_MAP` by `OwnerId`), tagged
   with attributes `caseId`, `ownerId`, `ownerName`, `mailbox`, `fromAddress`,
   `isSharedMailbox`, `bodyPreview`, plus a **URL reference** to the raw email.
7. **Audit** row written to DynamoDB `email-routing-log`.
8. **The owner's agent** receives the Task: the owner's flow targets that owner's
   queue, served only by that owner's agent (e.g. `agent.epic` /
   `agent.sateesh`). Unmapped/unassigned owners fall back to `demo.agent` on the
   shared `Email-Case-Queue`.

## What each scenario proves
- **Scenario 1 — case-based routing:** an email referencing a Salesforce case is
  routed to the **live Case Owner's agent**, no manual triage or reassignment.
- **Scenario 2 — shared-mailbox ownership continuity:** a follow-up with no case
  reference still routes to the **same owner's agent**, so ownership stays
  consistent across a thread in a shared mailbox.

## Scope note (so you don't overclaim)
- Routing is **owner-targeted** — each Task lands with the resolving owner's
  agent (via a per-owner queue/flow), with a shared-queue fallback.
- The agent sees a **body preview** inline and a **link to the raw email** (the
  full quoted thread). The link downloads the raw `.eml`; rich in-workspace HTML
  rendering and a full **account-360 view (related cases/history)** are
  Scenario 5 territory — not built this round.

---

## Live demo script

### Before the demo
- Log in as **two agents** in the Agent workspace (CCP, `.../ccp-v2`) — use two
  browsers or one incognito — and set both **Available**:
  - **`agent.epic`** (maps to Salesforce owner *OrgFarm EPIC*)
  - **`agent.sateesh`** (maps to owner *Sateesh Rudrangi*)
- Have Salesforce open showing the Cases: `00001028` owned by *OrgFarm EPIC*,
  `00001027` owned by *Sateesh Rudrangi*.
- Optional "under the hood" tabs: CloudWatch Logs for
  `/aws/lambda/email-case-router-lambda`, the two DynamoDB tables, the S3 bucket.
- Send test emails from an external account (e.g. Gmail).

### Scene 1 — Case-based routing to the owner (Scenario 1)
1. Send to `ordersuccess@ccaas.evolvity.com`, subject:
   `RE: Case #00001028 - return question`.
2. Narrate: SES → Lambda parses the case → **live Salesforce lookup** → owner
   *OrgFarm EPIC*.
3. Show the Task **arrive at `agent.epic`** (not the other agent). Open it: the
   `caseId`, `ownerName`, **body preview**, and the **"Raw email (full thread)"**
   link are all on the Task.

### Scene 2 — Different owner, different agent (Scenario 1, differentiation)
1. Send subject `RE: Case #00001027 - shipping delay` (owned by *Sateesh*).
2. Show the Task **arrive at `agent.sateesh`** — proving it routes to the *right*
   owner, not a shared pile.

### Scene 3 — Ownership continuity (Scenario 2)
1. From the **same** sender as Scene 1, send a follow-up with **no case number**:
   `Quick follow-up on my order`.
2. Narrate: no case reference — the system **remembers** the owner from the prior
   case → routes to **`agent.epic`** again (`outcome=fallback`).
3. Contrast: a legacy shared mailbox needs manual triage; here it's auto-routed
   to the original owner.

### Evidence to show at each step (pick per audience)
| Step | Where |
|---|---|
| Email captured | S3 `inbound/` object |
| Router ran + decision | CloudWatch Lambda log (`routed ... outcome=...`) |
| Owner + body + link on Task | Agent workspace Task info panel |
| Audit trail | DynamoDB `salesforce-email-demo-email-routing-log` |
| Remembered owner | DynamoDB `salesforce-email-demo-mailbox-ownership` |
| Right agent got it | The correct agent's CCP (epic vs sateesh) |

### Talking points (value)
- Fully **serverless**, cost-minimal (Task channel only; no recording/streaming/
  Contact Lens).
- **Live** Salesforce integration (not mocked) via Client Credentials.
- **Owner-targeted** delivery + **ownership continuity** via lightweight DynamoDB
  state.
- **Infrastructure as code** (Terraform); re-skinnable for any prospect — add an
  owner→agent entry in the `agents` map; only email/prompt copy is client-
  specific, all system names are generic.

### Reset between runs
- To re-show Scenario 2 as "first time" (unassigned), delete the customer's row
  from the `mailbox-ownership` table. Otherwise a prior case makes the fallback
  succeed (which is the point of Scenario 2).

### Gotchas during a live demo
- Each agent **must be Available** in CCP or the Task waits in that owner's queue.
- Subject must contain the word **`Case`** (e.g. `Case #00001028`) to trigger the
  Salesforce lookup; otherwise it takes the ownership-fallback path.
- Send from an **external** address (mail to the subdomain only routes via SES).
- SES **sandbox** limits *sending* only; receiving (this demo) is unaffected.
