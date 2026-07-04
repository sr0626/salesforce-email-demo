# Demo Walkthrough — how it works end-to-end + live demo script

## The one-sentence pitch
A customer emails a shared mailbox; the system automatically identifies the
owning agent — via a live Salesforce Case lookup, or by remembering who owned
the customer's prior thread — and creates an Amazon Connect Task tagged with
that owner, with no human triage.

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
5. **Create Connect Task** via `StartTaskContact` on the instance, running the
   Task contact flow, tagged with attributes: `caseId`, `ownerId`, `ownerName`,
   `mailbox`, `fromAddress`, `isSharedMailbox`.
6. **Audit** row written to DynamoDB `email-routing-log`.
7. **Agent** (`demo.agent`, Email-Routing-Profile) who is **Available** in the
   Agent workspace (CCP) receives the Task in the `Email-Case-Queue`.

## What each scenario proves
- **Scenario 1 — case-based routing:** an email referencing a Salesforce case is
  auto-tagged with the live Case Owner. No manual lookup/triage.
- **Scenario 2 — shared-mailbox ownership continuity:** a follow-up with no case
  reference still resolves to the same owner, so ownership stays consistent
  across a thread in a shared mailbox.

## Honest scope note (so you don't overclaim)
The current contact flow routes every Task into one shared `Email-Case-Queue`
and **carries the resolved owner as a contact attribute** (`ownerId`/
`ownerName`). It does **not yet auto-assign** each Task to that specific owner's
agent. Driving distribution off the `ownerId` attribute (per-owner queues or
agent routing) is a straightforward extension — the owner data is already
attached. For the demo, the value shown is: correct owner **resolution +
attribution + Task creation**, fully automated.

---

## Live demo script

### Before the demo
- Log in as **`demo.agent`** in the Agent workspace (CCP, `.../ccp-v2`) → set
  status **Available**.
- Have Salesforce open showing the Cases (e.g. `00001028` owned by *OrgFarm
  EPIC*).
- Optional "under the hood" tabs: CloudWatch Logs for
  `/aws/lambda/email-case-router-lambda`, the two DynamoDB tables, the S3 bucket.
- Send test emails from an external account (e.g. Gmail).

### Scene 1 — Case-based routing (Scenario 1)
1. Send email to `ordersuccess@ccaas.evolvity.com`, subject:
   `RE: Case #00001028 - return question`.
2. Narrate: SES receives → Lambda parses the case → **live Salesforce lookup** →
   owner = *OrgFarm EPIC*.
3. Show the **Task arrive in CCP** (Name `Email: RE: Case #00001028 ...`).
4. (Optional plumbing proof) Lambda log line:
   `case=00001028 owner=OrgFarm EPIC outcome=resolved`; audit row in
   `email-routing-log`.

### Scene 2 — Ownership continuity (Scenario 2)
1. From the **same** customer address, send a follow-up with **no case number**:
   `Quick follow-up on my order`.
2. Narrate: no case reference — but the system **remembers** who owns this
   customer's thread from the earlier case.
3. Show the Task arrive, and the log line:
   `case=None owner=OrgFarm EPIC outcome=fallback`.
4. Contrast: in a legacy shared mailbox this would need manual triage; here it is
   auto-routed to the right owner.

### Evidence to show at each step (pick per audience)
| Step | Where |
|---|---|
| Email captured | S3 `inbound/` object |
| Router ran + decision | CloudWatch Lambda log (`routed ... outcome=...`) |
| Audit trail | DynamoDB `salesforce-email-demo-email-routing-log` |
| Remembered owner | DynamoDB `salesforce-email-demo-mailbox-ownership` |
| Task for the agent | Connect Agent workspace (CCP) |

### Talking points (value)
- Fully **serverless**, cost-minimal (Task channel only; no recording/streaming/
  Contact Lens).
- **Live** Salesforce integration (not mocked) via Client Credentials.
- **Ownership continuity** via lightweight DynamoDB state.
- **Infrastructure as code** (Terraform); re-skinnable for any prospect — only
  the email/prompt copy is client-specific, all system names are generic.

### Reset between runs
- To re-show Scenario 2 as "first time" (unassigned), delete the customer's row
  from the `mailbox-ownership` table. Otherwise a prior case makes the fallback
  succeed (which is the point of Scenario 2).

### Gotchas during a live demo
- The agent **must be Available** in CCP or the Task just waits in queue.
- Send from an **external** address (mail to the subdomain only routes via SES).
- SES **sandbox** limits *sending* only; receiving (this demo) is unaffected.
