# Implementation Status

**Last updated:** 2026-07-05

Live status of the demo against the client's 8 demonstration scenarios + the final
exercise. Update as features land. Legend:

- ✅ **Built** — built and verified
- 🟡 **Partial** — core built; some sub-items remain
- 🔜 **Not built yet** — planned for a later round; the path is noted (this is a
  phased demo, *not* "out of scope")
- ♻️ **Reuses this round's plumbing** — little/no new build to add

## Scope summary (8 scenarios)

| # | Scenario | Status |
|---|---|---|
| 1 | Salesforce case-based email routing | ✅ Built — all requirements met |
| 2 | Shared mailbox with individual ownership | ✅ Built — all requirements met |
| 3 | Hybrid routing (ACD + agent self-selection) | 🟡 Partial — ACD built; agent self-selection/cherry-pick + governance not yet ♻️ |
| 4 | Outbound email tracking & visibility | 🔜 Arrives with the outbound build (docs/09) + native Connect outbound tracking |
| 5 | Customer/account-level visibility | 🟡 Partial — customer + account 360 built; duplicate-work *alerts* not yet |
| 6 | Complex routing using CRM data | 🟡 Partial — routing engine built (by Case Owner); extends to any CRM field via same Lambda ♻️ |
| 7 | Agent productivity & collaboration | 🟡 Partial — collaboration/consult + multi-session built; templates arrive with outbound; knowledge/drafts not yet |
| 8 | AI & future-state | 🔜 Future-state roadmap via Amazon Q in Connect (docs/09) |

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
| Ownership transfer workflows | ✅ | Reassign via **Salesforce Change Owner** (system of record); routing honors it live on the next reply (both paths). Connect task transfer remains a separate *collaboration/consult* action (doesn't change ownership, by design). |
| Supervisor reassignment capabilities | ✅ | A supervisor reassigns the Case owner in Salesforce → the next customer reply routes to the new owner's agent on both paths (live re-verify). |
| *Success:* seamless to customer | ✅ | Customer just emails the shared address |
| *Success:* ownership visible & auditable | ✅ | Task attributes + `email-routing-log` table |
| *Success:* continuity maintained | ✅ | Every reply routes to the thread's **current** owner throughout the journey (live re-read; follows reassignment; never dropped). Tracked per (mailbox, customer); multiple concurrent cases with a no-`Case#` reply use the most-recent (documented heuristic). |

## Scenario 3 — Hybrid Routing Model (ACD + Agent Selection)

| Requirement | Status | Note |
|---|---|---|
| Traditional ACD routing | ✅ | Queues + routing profiles auto-assign (push) — owner-targeted + shared fallback |
| Shared queue visibility | 🟡 | Supervisor/agents see queues via native real-time metrics; a dedicated agent "queue inventory" pull view isn't configured |
| Agent self-selection of work items (cherry-pick) | 🔜 | Today's model is ACD push; a manual-select/"pull" queue can be added so agents pick work — not built |
| Supervisor controls governing cherry-pick | 🔜 | Rides on the self-selection setup |
| Mixed routing strategies simultaneously | 🟡 | ACD built; a per-team mix of auto + pull is the remaining delta |
| *Success:* different departments, different models | 🟡 | ACD per team ✅; add a pull queue for cherry-pick teams |
| *Success:* select work without duplicate effort | 🔜 | Needs self-selection + the S5 duplicate-work alerts |
| *Success:* supervisors keep governance | 🟡 | Supervisor user + native controls ✅; cherry-pick governance not built |

♻️ Reuses this round's queue/routing-profile plumbing — the delta is a pull/manual-select queue.

## Scenario 4 — Outbound Email Tracking and Visibility

| Requirement | Status | Note |
|---|---|---|
| Agent-initiated outbound email | 🔜 | Part of the outbound build — Connect native email channel (docs/09) |
| Tracking of outbound-only interactions | 🔜 | Connect tracks outbound contacts once the channel is enabled; + our audit log |
| Reporting on outbound communications | 🔜 | Native Connect historical metrics once outbound exists |
| Visibility into agent productivity | 🟡 | Native Connect agent metrics exist; outbound-specific once built |
| Audit and review capabilities | 🟡 | `email-routing-log` covers inbound; extend to outbound when built |
| *Success:* outbound reportable / leadership visibility / supervisors evaluate | 🔜 | Delivered by the outbound build + native dashboards |

Gated on final-exercise steps 3 & 9 (docs/09).

## Scenario 5 — Customer and Account-Level Visibility

| Requirement | Status | Note |
|---|---|---|
| Customer view: open emails | ✅ | `EmailMessage`s on the contact/case; contact Activity |
| Customer view: historical emails | ✅ | Case + contact history |
| Customer view: open Salesforce cases | ✅ | Contact → Cases related list |
| Customer view: interaction timeline | ✅ | Contact Activity timeline |
| Customer view: previous communications | ✅ | Same |
| Account view: activity from multiple contacts | 🟡 | Account roll-up shows contacts' activity (org setting on); works when contacts share the account |
| Account view: open cases across the account | ✅ | Account → Cases related list |
| Account view: open interactions across the account | 🟡 | Via account cases/activity |
| Account view: assigned ownership | ✅ | Case Owner |
| Duplicate-work **alerts** (more emails / another agent working / related cases / pending requests) | 🔜 | The 360 is *visible* (agent can see related cases/emails), but no *proactive alert* — not built |
| *Success:* agents understand history | ✅ | via the 360 |
| *Success:* duplicate effort minimized | 🟡 | Visible via the 360; active alerting not built |
| *Success:* consistent CX across teams | ✅ | Same case/contact/account for everyone |

Largely delivered already by the Contact/Account 360 built for the final exercise (step 7).

## Scenario 6 — Complex Routing Using CRM Data

| Requirement | Status | Note |
|---|---|---|
| Route by Salesforce Case Owner | ✅ | Core routing (live SOQL → owner's agent) |
| Route by Account Ownership | 🟡 | Account is linked; routing by account owner reuses the same Lambda pattern — not built |
| Route by Customer Info / Product / Order / Case Type / Business Rules | 🔜 | The routing Lambda can query any Salesforce field and branch; currently keys on Case Owner — extend via the same pattern |
| *Success:* multiple variables simultaneously | 🟡 | Lambda supports it; currently owner-based |
| *Success:* admin-maintainable routing | 🟡 | Today via code/tfvars; a DynamoDB "routing rules" table would make it admin-editable |
| *Success:* minimal custom development | 🟡 | Engine + mapping in place; per-rule config is the delta |

♻️ Reuses this round's routing Lambda + owner→queue mapping.

## Scenario 7 — Agent Productivity and Collaboration

| Requirement | Status | Note |
|---|---|---|
| Unified agent desktop | 🟡 | Connect agent workspace; tighter Salesforce unification via the CTI adapter is an enhancement |
| Email templates and macros | 🔜 | Connect email channel provides templates/quick responses — arrives with the outbound build |
| Address book integration | 🔜 | Not built |
| Knowledge search | 🔜 | Amazon Q / knowledge base — not built (S8-adjacent) |
| Multi-session handling | ✅ | Agents handle multiple concurrent contacts (TASK concurrency) |
| Internal collaboration | ✅ | Quick connects — transfer/consult a colleague (final-exercise step 8) |
| Shared drafts | 🔜 | Not built |
| Expert consultation workflows | 🟡 | Transfer/consult via quick connect ✅; a formal consult workflow is more |
| *Success:* reduced effort / faster / consistency | 🟡 | Collaboration + multi-session now; templates with outbound |

## Scenario 8 — AI and Future-State Capabilities

*(The client states AI is "not an immediate buying criterion but an important strategic consideration" — so this is a **future-state roadmap**, delivered natively via **Amazon Q in Connect** on the same platform; not built this round.)*

| Requirement | Status | Note |
|---|---|---|
| AI-generated email drafts | 🔜 | Amazon Q in Connect (docs/09) |
| Suggested responses | 🔜 | Amazon Q in Connect |
| Agent assist | 🔜 | Amazon Q in Connect |
| Knowledge retrieval | 🔜 | Amazon Q + knowledge base |
| Automated categorization | 🔜 | Bedrock/Comprehend or Connect rules |
| Automated prioritization | 🔜 | Routing rules + AI signals |
| Customer sentiment analysis | 🔜 | Contact Lens / Comprehend |

---

## Open gaps (prioritized)

| # | Gap | Detail | Suggested fix |
|---|---|---|---|
| 1 | Thread continuity as one interaction (S1) | A Task per reply today | Link replies via Connect related-contacts so a thread is one interaction |
| 2 | Case SLA / "overdue" tracking (**TODO — revisit**) | No SLA/response-time or "overdue" tracking; Salesforce "Overdue" applies only to due-dated Activities, not our emails | Salesforce **Entitlements & Milestones** or **Case Escalation Rules / Case Age** (Setup); or a scheduled check on `email-routing-log` |
| 3 | Duplicate-work alerts (S5) | The 360 shows related cases/emails, but no proactive "someone's already on this" alert | Flow/Lambda check on related open cases/interactions → surface a warning attribute |
| 4 | Agent self-selection / cherry-pick (S3) | ACD push only | Add a pull/manual-select queue + supervisor governance |

> Resolved: ownership-change on the no-case fallback (live re-read) and ownership
> transfer / supervisor reassignment (via Salesforce Change Owner, honored live).

---

## Known limitations / demo assumptions

Deliberate simplifications for this round (not defects):

| Area | Limitation | To make it production-realistic |
|---|---|---|
| Auto-created case ownership | A new auto-created Case is owned by the **REST API caller** (the Client Credentials **Run As** user), **not** round-robin / assignment rules (**not configured this round**). | Create Case Assignment Rules in Salesforce and send the `Sforce-Auto-Assign: true` header on Case create. |
| Outbound sending | SES production access granted; native-email reply **plumbing proven** on test address `support@` (2026-07-05). The owner-routed `ordersuccess@` build isn't done yet. | Build the outbound path (steps 3 & 9) — Connect native email channel, hybrid split with `taskdemo@` (docs/09). |
| Native-email screen-pop | The Salesforce **CTI Adapter does not bridge Connect's native email channel** (voice/chat/task only), so there's **no auto-navigation** to the Case for an email contact. | Agent gets the Case via a workspace **link/view** (meets "opens and sees the 360"). Literal auto-pop = optional custom Streams + Open CTI bridge. |
| Outbound deliverability | Round-trip verified externally (2026-07-06): reply delivered to inbox, **SPF PASS + DKIM PASS (aligned) on `ccaas.evolvity.com`**. SPF TXT (`v=spf1 include:amazonses.com ~all`) filed with Server Sea. **DMARC deferred (TODO):** currently FAIL only because no DMARC record is published — publish `_dmarc.ccaas.evolvity.com` TXT `v=DMARC1; p=none; adkim=r; aspf=r; fo=1` (scoped to the subdomain; DKIM already aligns so it flips to PASS). | Publish the DMARC record; optionally tighten `p=none`→`quarantine`/`reject` later. |
| Rendered email view | Renders the sender's **raw HTML unsanitized**. Fine for an internal demo. | Sanitize HTML before rendering. |
| Native-email attachments/inline images on the SF Case | The native-email → SF `EmailMessage` logs the **HTML body only**. Inline images (`cid:`) and file **attachments** don't appear on the Case (they render fine in the Connect agent workspace). **TODO.** | Fetch attachment objects from Connect's EMAIL_MESSAGES storage → upload to Salesforce as `ContentVersion`/`Attachment` and relate to the `EmailMessage`/Case. |
| Email link | The `Email`/rendered-view link is a **presigned URL that expires** (12h TTL). | Serve via an authenticated agent app instead of a presigned link. |
| Account activity roll-up | Emails show on the **Contact** timeline (via `EmailMessageRelation`) with no config; showing them on the **Account** timeline needs the org setting **"Roll up activities to a contact's primary account."** | Standard Salesforce config — enabled in this demo org. Account **Cases** related list shows without any setting. |
| Salesforce Case access | The `SalesforceCase` reference is a **click-through deep link** (meets "agent opens the interaction and sees" — auto screen-pop is not required). | *Optional:* Amazon Connect **CTI Adapter for Salesforce** to auto-navigate on Task accept. |

---

## Bonus features (beyond the client's ask)

| Feature | What it adds |
|---|---|
| In-Task email visibility | Decoded **`bodyPreview`** + an **`Email`** link to a browser-renderable HTML view (From/To/Date/Subject header + full quoted thread) — reads like a real email, no leaving Connect. |
| Salesforce Case link (deep link) | Task carries a **`SalesforceCase`** URL → one click opens the live Case 360. |
| Emails logged to the Case | Each inbound email → incoming **`EmailMessage`** on the Case + related to the Contact → shows in case/contact/account history. |
| Owner-targeted routing | Per-owner **queue + routing profile + contact flow + agent**; Lambda picks the owner's flow by `OwnerId`, shared-queue fallback. |
| End-to-end audit trail | Every routing decision in `email-routing-log` (case, owner, outcome, contactId, timestamp). |
| Full CMK encryption | S3, DynamoDB, Secrets Manager, Lambda env — all encrypted with the customer-managed KMS key. |

---

## Final Demonstration Exercise — status

| # | Step | Status | Note |
|---|---|---|---|
| 1 | Customer sends an inquiry | ✅ | Inbound email received by SES |
| 2 | Salesforce case is created or identified | ✅ | Identified via `Case #`; a new inquiry auto-**creates** a Case and routes to its owner |
| 3 | Agent responds from a shared mailbox | 🔜 | Outbound via Connect native email channel — [09](09-outbound-connect-email-plan.md). **Plumbing proven** 2026-07-05 on test address `support@` (inbound→agent reply→delivered); still to do: wire the routing brain into an inbound *email* flow + cut `ordersuccess@` over. Approach locked: **hybrid** (`ordersuccess@`=native email, `taskdemo@`=Task path), SF Case via workspace **link/view** (no CTI screen-pop for native email). |
| 4 | Customer replies | ✅ | Inbound reply received |
| 5 | Platform identifies the Salesforce Case ID | ✅ | Regex on subject |
| 6 | Email routes to the assigned owner | ✅ | Owner-targeted routing to the owner's agent |
| 7 | Agent opens the interaction and sees the customer 360 | ✅ | `SalesforceCase` + `Email`/`bodyPreview`; Case linked to Contact/Account; emails logged + related → ownership, open emails, history, open cases, related account activity |
| 8 | Agent collaborates with another employee | ✅ | USER quick connects (`Transfer-to-<agent>`) → native transfer/consult (associate to queue in console) |
| 9 | Agent sends a response | 🔜 | Same as step 3 — Connect native email channel (docs/09); native reply-send plumbing proven on `support@` 2026-07-05 |
| 10 | Interaction is tracked, reported, and auditable | ✅ | Native Connect dashboards + contact search + `email-routing-log` |
| 11 | Supervisors review routing/ownership/metrics | ✅ | Supervisor user (`demo.supervisor`, CallCenterManager) + dashboards; ownership changes in `email-routing-log` + SF case history |
