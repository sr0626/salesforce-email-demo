# Implementation Status

**Last updated:** 2026-07-04

Live status of the POC against the client's demonstration scenarios. Update as
features land. Legend:

- ✅ **Covered** — built and verified
- 🟡 **Partial** — core works; a sub-requirement is incomplete
- ❌ **Gap** — not built
- ⬜ **Out of scope** — deliberately not in this round

## Scope summary (8 scenarios)

| # | Scenario | Status |
|---|---|---|
| 1 | Salesforce case-based email routing | ✅ built (all requirements met) |
| 2 | Shared mailbox with individual ownership | ✅ built (all requirements met) |
| 3 | Hybrid routing (ACD + agent self-selection) | ⬜ reuse of this plumbing; no new build |
| 4 | Outbound email tracking & visibility | ⬜ out of scope |
| 5 | Customer/account-level visibility | ⬜ out of scope (partial taste via email view — see bonus) |
| 6 | Complex routing using CRM data | ⬜ reuse; no new build |
| 7 | Agent productivity/collaboration | ⬜ out of scope |
| 8 | AI / future-state | ⬜ skipped (client deprioritized) |

---

## Scenario 1 — Salesforce Case-Based Email Routing

| Requirement | Status | Note |
|---|---|---|
| Email interactions tied to Salesforce cases | ✅ | Connect Task created per email, tagged `caseId`. A **new inquiry** (no case #, no prior owner) auto-**creates** a Salesforce Case and routes to its owner (`outcome=created`). |
| Auto-identify Salesforce Case IDs in threads | ✅ | Regex on subject (`Case #NNNNN`) |
| Routing based on Salesforce Case Owner | ✅ | Live SOQL lookup → route to owner's agent |
| Sync of ownership changes SF ↔ platform | ✅ | Every reply resolves the **current** owner live from Salesforce — `Case #` via SOQL, no-`Case #` via live re-read of the case by Id. Connect stores no owner of its own, so nothing drifts; SF is the single source of truth. *(Pull/read-time per interaction — in-flight queued contacts aren't re-routed, and no push/two-way sync is needed.)* |
| Preservation of email thread continuity | ✅ | Every message is logged as an `EmailMessage` on the **one Case** (chronological history), the sender's `In-Reply-To`/`References` headers stay intact, the quoted chain shows in the rendered view, and all replies route to the same case/owner. *(Connect treats each reply as a separate contact rather than one merged work item — a UX refinement tracked as gap #1, not a break in continuity.)* |
| *Success:* no manual reassignment | ✅ | |
| *Success:* routing leverages Salesforce data | ✅ | Live Client-Credentials SOQL |
| *Success:* ownership changes reflected immediately | ✅ | On both reply paths (case# live SOQL + no-case live re-read) |
| *Success:* customer stays with the specialist | ✅ | Routes to the owner's agent |

## Scenario 2 — Shared Mailbox with Individual Ownership

| Requirement | Status | Note |
|---|---|---|
| Multiple agents on a common address | ✅ | Shared `ordersuccess@ccaas.evolvity.com` |
| Visibility into assigned owner | ✅ | `ownerName` on Task + audit table |
| Routing of replies to original owner | ✅ | No-case reply → remembered owner; the case's **current** owner is re-read live so reassignment is honored, and the Task shows the caseId |
| Ownership transfer workflows | ✅ | Reassign via **Salesforce Change Owner** (system of record); routing honors it live on the **next reply** — case-numbered via live lookup, **and no-case replies now re-read the case's current owner** (not the cached one). Connect task transfer remains a separate *collaboration/consult* action (doesn't change ownership, by design). |
| Supervisor reassignment capabilities | ✅ | A supervisor reassigns the Case owner in Salesforce → the next customer reply routes to the new owner's agent on both paths (live re-verify). |
| *Success:* seamless to customer | ✅ | Customer just emails the shared address |
| *Success:* ownership visible & auditable | ✅ | Task attributes + `email-routing-log` table |
| *Success:* continuity maintained | ✅ | Every reply routes to the thread's **current** owner throughout the journey (live re-read; follows reassignment; never dropped). Tracked per (mailbox, customer) — last-known case/owner; multiple concurrent cases per customer with a no-`Case#` reply use the most-recent (documented heuristic). |

---

## Open gaps (prioritized)

| # | Gap | Detail | Suggested fix |
|---|---|---|---|
| 1 | Thread continuity as one interaction (S1) | A Task per reply today | Link replies via Connect related-contacts so a thread is one interaction |
| 2 | Case SLA / "overdue" tracking (**TODO — revisit**) | No SLA/response-time or "overdue" tracking on cases; Salesforce "Overdue" applies only to due-dated Activities, not our emails | Salesforce **Entitlements & Milestones** or **Case Escalation Rules / Case Age** (Setup); or a scheduled check on `email-routing-log` |

> Resolved: *ownership-change on the no-case fallback* (now re-reads the case's
> current owner live) and *ownership transfer / supervisor reassignment* (done via
> Salesforce Change Owner, honored live on both paths).

---

## Known limitations / demo assumptions

Deliberate simplifications for the POC (not defects):

| Area | Limitation | To make it production-realistic |
|---|---|---|
| Auto-created case ownership | A new auto-created Case is owned by the **REST API caller** (the Client Credentials **Run As** user, `sateesh…@agentforce.com`), **not** round-robin / assignment rules. Salesforce **Case Assignment Rules are out of scope** for this demo. | Create Case Assignment Rules in Salesforce and send the `Sforce-Auto-Assign: true` header on Case create. |
| Outbound sending | SES is in the **sandbox** (receiving works; *sending* is restricted). No agent reply-send is built. | Request SES production access (in progress); build the outbound/reply path (steps 3 & 9). |
| Outbound deliverability | **TODO:** no SPF record for the `ccaas` subdomain yet. | When building outbound, add SPF TXT on `ccaas`: `v=spf1 include:amazonses.com ~all` (via Cloudflare/Server Sea) so replies don't hit spam. |
| Rendered email view | Renders the sender's **raw HTML unsanitized** (could include remote images/scripts). Fine for an internal demo. | Sanitize HTML before rendering. |
| Email link | The `Email`/rendered-view link is a **presigned URL that expires** (12h TTL). | Serve via an authenticated agent app instead of a presigned link. |
| Account activity roll-up | Emails show on the **Contact** timeline (via `EmailMessageRelation`) with no config, but showing them on the **Account** timeline requires the Salesforce org setting **"Roll up activities to a contact's primary account"** (Setup → Activity Settings). `EmailMessageRelation` can't relate to an Account, so there's no code-only alternative (short of duplicating each email as an Account-`WhatId` Task). | Standard Salesforce config — enable the roll-up setting (done in this demo org). The Account's **Cases** related list shows without any setting. |
| Salesforce Case access | The `SalesforceCase` reference is a **click-through deep link** (agent opens the case in one click). The requirement only asks that the agent "opens the interaction and sees" the context, so this meets it — auto screen-pop is **not required**, just a nicety. | *Optional enhancement:* Amazon Connect **CTI Adapter for Salesforce** (embed CCP in Salesforce) to auto-navigate to the case on Task accept via the `caseId` attribute. |

---

## Bonus features (beyond the client's ask)

| Feature | What it adds |
|---|---|
| In-Task email visibility | Decoded **`bodyPreview`** attribute + an **`Email`** link to a browser-renderable HTML view — rendered with a **From/To/Date/Subject header block above the full quoted thread**, so it reads like a real email. The agent reads it without leaving Connect. An early taste of Scenario 5. |
| Salesforce Case link (deep link) | Task carries a **`SalesforceCase`** URL → one click opens the live Case in Salesforce (its full 360). Satisfies final-exercise step 7 by reusing Salesforce's native account/case view. (Click-through link, not an auto screen-pop — see limitations.) |
| Emails logged to the Case | Each inbound email is written to its Salesforce Case as an incoming **`EmailMessage`**, so the full email thread appears in Salesforce case **history** (toggle `log_email_to_salesforce`). |
| Owner-targeted routing | Per-owner **queue + routing profile + contact flow + agent**; the Lambda picks the owner's flow by `OwnerId` (beyond simple attribute tagging), with a shared-queue fallback. |
| End-to-end audit trail | Every routing decision written to the `email-routing-log` DynamoDB table (case, resolved owner, outcome, contactId, timestamp) — supports the "auditable" criterion and supervisor review. |
| Full CMK encryption | S3, DynamoDB, Secrets Manager, and Lambda env vars all encrypted with the existing customer-managed KMS key. |

---

## Final Demonstration Exercise — status

| # | Step | Status | Note |
|---|---|---|---|
| 1 | Customer sends an inquiry | ✅ | Inbound email received by SES |
| 2 | Salesforce case is created or identified | ✅ | Identified via `Case #` in subject; a new inquiry (no case #, no history) now **auto-creates a Salesforce Case** and routes to its owner |
| 3 | Agent responds from a shared mailbox | 📋 planned | Outbound reply via Amazon Connect native email channel — design in [09-outbound-connect-email-plan.md](09-outbound-connect-email-plan.md); build pending |
| 4 | Customer replies | ✅ | Inbound reply received |
| 5 | Platform identifies the Salesforce Case ID | ✅ | Regex on subject |
| 6 | Email routes to the assigned owner | ✅ | Owner-targeted routing to the owner's agent |
| 7 | Agent opens the interaction and sees: customer history / open emails / open cases / related account activity / assigned ownership | ✅ | Via the **`SalesforceCase`** deep link + `Email`/`bodyPreview`. Cases link to a **Contact/Account** (sender email, find-or-create); each email is logged as an `EmailMessage` on the Case **and** related to the Contact (`EmailMessageRelation`). Salesforce then shows the full 360: **ownership** (Case), **open emails + case history** (Case Activity), **customer history + open cases** (Contact), and **related account activity** (Account, with the org roll-up setting on — see limitations). |
| 8 | Agent collaborates with another employee | ✅ | Per-agent **USER Quick Connects** provisioned (`Transfer-to-<agent>`); agent transfers/consults a colleague via native Connect transfer. (One-time console step: associate the quick connects to the queue to list them in the transfer menu.) |
| 9 | Agent sends a response | 📋 planned | Same as step 3 — Connect native email channel ([09-outbound-connect-email-plan.md](09-outbound-connect-email-plan.md)); build pending |
| 10 | Interaction is tracked, reported, and auditable | ✅ | Connect **native real-time + historical dashboards** and **contact search** (routing decisions + attributes), plus the `email-routing-log` DynamoDB audit trail |
| 11 | Supervisors can review routing decisions, ownership changes, and performance metrics | ✅ | **Supervisor user** (`demo.supervisor`, CallCenterManager) views the dashboards/contact search; ownership changes are in `email-routing-log` + the Salesforce case history |
