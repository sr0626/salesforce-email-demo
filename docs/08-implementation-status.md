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
| 1 | Salesforce case-based email routing | ✅ built (2 partials — see below) |
| 2 | Shared mailbox with individual ownership | ✅ built (2 gaps — see below) |
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
| Sync of ownership changes SF ↔ platform | 🟡 Partial | Live lookup per email → a *new* reply always reflects the current owner ("reflected immediately"). No re-routing of already-queued Tasks; no continuous/two-way sync. |
| Preservation of email thread continuity | 🟡 Partial | Rendered email shows the full quoted chain; but each reply is a **new Task** (replies not threaded into one interaction). |
| *Success:* no manual reassignment | ✅ | |
| *Success:* routing leverages Salesforce data | ✅ | Live Client-Credentials SOQL |
| *Success:* ownership changes reflected immediately | ✅ | On the per-email lookup path |
| *Success:* customer stays with the specialist | ✅ | Routes to the owner's agent |

## Scenario 2 — Shared Mailbox with Individual Ownership

| Requirement | Status | Note |
|---|---|---|
| Multiple agents on a common address | ✅ | Shared `ordersuccess@ccaas.evolvity.com` |
| Visibility into assigned owner | ✅ | `ownerName` on Task + audit table |
| Routing of replies to original owner | ✅ | DynamoDB fallback → remembered owner's agent |
| Ownership transfer workflows | ❌ Gap | No built workflow to hand a thread to a new owner and persist it. (Native Connect task transfer is demoable but doesn't update the ownership record / Salesforce.) |
| Supervisor reassignment capabilities | ❌ Gap | No supervisor "reassign owner" flow. (Reassigning the **Case in Salesforce** is honored on the next case-numbered reply via live lookup; the no-case fallback would stay stale.) |
| *Success:* seamless to customer | ✅ | Customer just emails the shared address |
| *Success:* ownership visible & auditable | ✅ | Task attributes + `email-routing-log` table |
| *Success:* continuity maintained | ✅ | Fallback continuity (transfer/reassign caveats above) |

---

## Open gaps (prioritized)

| # | Gap | Detail | Suggested fix |
|---|---|---|---|
| 1 | Fallback can go stale on ownership change | Case-numbered emails reflect the live SF owner; the *no-case* fallback trusts the remembered DynamoDB owner | On fallback, re-verify the current owner from Salesforce (look up the customer's open case) instead of trusting DynamoDB alone — small change, makes "reflected immediately" true on both paths |
| 2 | Ownership transfer / supervisor reassignment (S2) | No workflow to hand a thread to a new owner or supervisor-reassign | Lean on native Connect transfer/monitor for the demo; add a lightweight "reassign owner" that updates the ownership record (+ optionally Salesforce) |
| 3 | Thread continuity as one interaction (S1) | A Task per reply today | Link replies via Connect related-contacts so a thread is one interaction |

---

## Known limitations / demo assumptions

Deliberate simplifications for the POC (not defects):

| Area | Limitation | To make it production-realistic |
|---|---|---|
| Auto-created case ownership | A new auto-created Case is owned by the **REST API caller** (the Client Credentials **Run As** user, `sateesh…@agentforce.com`), **not** round-robin / assignment rules. Salesforce **Case Assignment Rules are out of scope** for this demo. | Create Case Assignment Rules in Salesforce and send the `Sforce-Auto-Assign: true` header on Case create. |
| Outbound sending | SES is in the **sandbox** (receiving works; *sending* is restricted). No agent reply-send is built. | Request SES production access; build the outbound/reply path (steps 3 & 9). |
| Rendered email view | Renders the sender's **raw HTML unsanitized** (could include remote images/scripts). Fine for an internal demo. | Sanitize HTML before rendering. |
| Email link | The `Email`/rendered-view link is a **presigned URL that expires** (12h TTL). | Serve via an authenticated agent app instead of a presigned link. |

---

## Bonus features (beyond the client's ask)

| Feature | What it adds |
|---|---|
| In-Task email visibility | Decoded **`bodyPreview`** attribute + an **`Email`** link to a browser-renderable HTML view — rendered with a **From/To/Date/Subject header block above the full quoted thread**, so it reads like a real email. The agent reads it without leaving Connect. An early taste of Scenario 5. |
| Owner-targeted routing | Per-owner **queue + routing profile + contact flow + agent**; the Lambda picks the owner's flow by `OwnerId` (beyond simple attribute tagging), with a shared-queue fallback. |
| End-to-end audit trail | Every routing decision written to the `email-routing-log` DynamoDB table (case, resolved owner, outcome, contactId, timestamp) — supports the "auditable" criterion and supervisor review. |
| Full CMK encryption | S3, DynamoDB, Secrets Manager, and Lambda env vars all encrypted with the existing customer-managed KMS key. |

---

## Final Demonstration Exercise — status

| # | Step | Status | Note |
|---|---|---|---|
| 1 | Customer sends an inquiry | ✅ | Inbound email received by SES |
| 2 | Salesforce case is created or identified | ✅ | Identified via `Case #` in subject; a new inquiry (no case #, no history) now **auto-creates a Salesforce Case** and routes to its owner |
| 3 | Agent responds from a shared mailbox | ⬜ | Outbound reply not built; the POC begins at the inbound reply |
| 4 | Customer replies | ✅ | Inbound reply received |
| 5 | Platform identifies the Salesforce Case ID | ✅ | Regex on subject |
| 6 | Email routes to the assigned owner | ✅ | Owner-targeted routing to the owner's agent |
| 7 | Agent opens the interaction and sees: customer history / open emails / open cases / related account activity / assigned ownership | 🟡 | Assigned ownership ✅ and email body/thread ✅ (bonus); customer history / open cases / related account activity ❌ (Scenario 5, not built) |
| 8 | Agent collaborates with another employee | ⬜ | Native Connect transfer only; not built |
| 9 | Agent sends a response | ❌ | Outbound reply from the platform not built (Scenario 4/7) |
| 10 | Interaction is tracked, reported, and auditable | 🟡 | Audit log built (tracked/auditable); no reporting UI |
| 11 | Supervisors can review routing decisions, ownership changes, and performance metrics | 🟡 | Data in DynamoDB; no supervisor dashboard |
