# Implementation Status — live source of truth

**Last updated:** 2026-07-04

This is the **living status** of the POC against the client's demonstration
scenarios. Update it as features land. Legend:

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
| Email interactions tied to Salesforce cases | ✅ | Connect Task created per email, tagged `caseId` |
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

1. **Fallback can go stale on ownership change.** Case-numbered emails always
   reflect the live Salesforce owner; the *no-case* fallback trusts the
   remembered DynamoDB owner. **Fix:** on fallback, re-verify the current owner
   from Salesforce (look up the customer's open case) rather than trusting
   DynamoDB alone. *(Small; makes "reflected immediately" true on both paths.)*
2. **Ownership transfer / supervisor reassignment (S2)** — not built as
   workflows. Lean on native Connect transfer/monitor for the demo, and/or add a
   lightweight "reassign owner" that updates the ownership record (+ optionally
   Salesforce).
3. **Thread continuity as one interaction (S1)** — a Task per reply today; could
   link replies via Connect related-contacts so a thread is one interaction.

---

## Bonus features (beyond the client's ask)

Built to strengthen the demo even though they weren't required for Scenarios 1/2:

- **In-Task email visibility** — each Task carries a decoded **`bodyPreview`**
  and an **`Email`** link to a **browser-renderable HTML view** of the message
  (the Lambda writes a rendered `.html` to S3 and presigns it, SigV4/KMS-safe).
  Gives the agent the email + full quoted thread without leaving Connect — an
  early taste of Scenario 5 (account/context visibility).
- **Owner-targeted routing** — not just tagging the owner as an attribute:
  per-owner **queue + routing profile + contact flow + agent**, and the Lambda
  picks the owner's flow by `OwnerId` (shared-queue fallback for unmapped
  owners).
- **End-to-end audit trail** — every routing decision is written to the
  `email-routing-log` DynamoDB table (case, resolved owner, outcome, contactId,
  timestamp). Supports the "auditable" success criterion and future supervisor
  review (Scenario 6 / final exercise).
- **Full encryption with a customer-managed KMS key** — S3, DynamoDB, Secrets
  Manager, and Lambda env vars all encrypted with the existing CMK.
- **Infrastructure as code, heavily parameterized** — Terraform modules with
  ~30 variables; generic/company-neutral naming so the demo **re-skins for any
  prospect** by editing values, not code.
- **Cost-minimal** — Task channel only; no call/contact recording, no Kinesis
  streaming, no Contact Lens.

---

## Final Demonstration Exercise — status

| Step | Status |
|---|---|
| Customer sends inquiry → shared mailbox | ✅ |
| Salesforce case created/identified | ✅ (identified via subject; creation is done in Salesforce) |
| Reply routes to the assigned owner | ✅ (owner-targeted) |
| Agent sees the email + thread | ✅ (bonus: body preview + rendered link) |
| Agent sees customer history / open cases / account activity | ⬜ Scenario 5 — not built |
| Agent collaborates with another employee | ⬜ Scenario 7 — native Connect transfer only |
| Interaction tracked / reported / auditable | 🟡 audit log built; no supervisor dashboard |
| Supervisor reviews routing/ownership/metrics | 🟡 data exists in DynamoDB; no UI |
