# Implementation Status

**Last updated:** 2026-07-06

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
| 3 | Hybrid routing (ACD + agent self-selection) | ✅ Built — ACD push (owner queues) + native Worklist cherry-pick (`Email-Case-Queue`) running together; governance via security permission. Duplicate-work *alerts* (S5) is the only remaining sub-item |
| 4 | Outbound email tracking & visibility | ✅ Built — native reporting (incoming/outgoing metrics + contact search) **and** outbound content logged to the SF Case as Outgoing `EmailMessage` (EventBridge → Lambda) for supervisor review |
| 5 | Customer/account-level visibility | ✅ Built — customer + account 360 (screen-pop + SF case) **and** proactive duplicate-work `⚠️` alerts (other open cases + owners) on accept |
| 6 | Complex routing using CRM data | 🟡 Partial — routing engine built (by Case Owner); extends to any CRM field via same Lambda ♻️ |
| 7 | Agent productivity & collaboration | 🟡 Partial — collaboration/consult + multi-session built; templates arrive with outbound; knowledge/drafts not yet |
| 8 | AI & future-state | 🔜 Future-state roadmap via Amazon Q in Connect (docs/09) |

---

## Scenario 1 — Salesforce Case-Based Email Routing

| Requirement | Status | Note |
|---|---|---|
| Email interactions tied to Salesforce cases | ✅ | On `ordersuccess@` a real **Connect email contact** is routed and the message is logged as an `EmailMessage` on the Case (full HTML body); on `taskdemo@` a Connect Task is created, tagged `caseId`. A **new inquiry** (no case #, no prior owner) auto-**creates** a Salesforce Case and routes to its owner (`outcome=created`). |
| Auto-identify Salesforce Case IDs in threads | ✅ | Regex on subject (`Case #NNNNN`) |
| Routing based on Salesforce Case Owner | ✅ | Live SOQL lookup → route to owner's agent |
| Sync of ownership changes SF ↔ platform | ✅ | Every reply resolves the **current** owner live from Salesforce — `Case #` via SOQL, no-`Case #` via live re-read of the case by Id. Connect stores no owner of its own, so nothing drifts; SF is the single source of truth. *(Pull/read-time per interaction — in-flight queued contacts aren't re-routed, and no push/two-way sync is needed.)* |
| Preservation of email thread continuity | ✅ | Every message is logged as an `EmailMessage` on the **one Case** (chronological history), the sender's `In-Reply-To`/`References` headers stay intact, the native email channel shows the full quoted thread in the agent workspace, and all replies route to the same case/owner. *(Connect treats each reply as a separate contact rather than one merged work item — a UX refinement tracked as gap #1, not a break in continuity.)* |
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
| Traditional ACD routing | ✅ | Queues + routing profiles auto-assign (push) — owner-targeted queues |
| Shared queue visibility | ✅ | The native **Worklist app** shows all agents the queued items in `Email-Case-Queue`; + supervisor real-time metrics |
| Agent self-selection of work items (cherry-pick) | ✅ | **Native manual assignment (Sept-2025)** — `Email-Case-Queue` set to *Manual assignment* on all three agents' routing profiles; agents open the **Worklist** and **"Assign to me"** (validated 2026-07-06). Push (owner queues) and pull (`Email-Case-Queue`) run **simultaneously**. |
| Supervisor controls governing cherry-pick | ✅ | Governance = the **security-profile permission** "Allow 'Assign to me' for any/my contact" (Contact actions group) — grant/deny who can self-select. *(Per-item supervisor "assign to agent X" is NOT native — see limitations.)* |
| Mixed routing strategies simultaneously | ✅ | Owner queues = auto/push; `Email-Case-Queue` = manual/pull — both active at once |
| *Success:* different departments, different models | ✅ | Push per owner + pull via the Worklist |
| *Success:* select work without duplicate effort | 🟡 | Worklist gives shared visibility (agents see the same list); proactive duplicate-work *alerts* are still the S5 gap |
| *Success:* supervisors keep governance | ✅ | Permission-based (who may self-assign) + supervisor user/dashboards |

♻️ Built on this round's queue/routing-profile plumbing — `Email-Case-Queue` (the fallback) doubles as the cherry-pick pool; no auto-routing on it now.

> **Console-only config (not in Terraform):** the routing-profile **Manual assignment**
> section and the **security-profile permission** are set in the console. Verified the
> AWS provider (`aws_connect_routing_profile`) only manages `media_concurrencies` +
> `queue_configs` — it has **no** manual-assignment field — so `terraform apply` won't
> revert it, but it also can't reproduce it. Re-do these in the console on a rebuild:
> (1) `Email-Case-Queue` → *Manual assignment* (Email) on `Email-Routing-Profile`,
> `Owner-epic-Profile`, `Owner-sateesh-Profile`; (2) *Allow 'Assign to me' for any
> contact* (Contact actions) on the **Agent** security profile.

**Cherry-pick ownership semantics (important):** the Worklist "Assign to me" (and a
supervisor self-assign+transfer) is a **contact-handling** action — it assigns the
*contact* to an agent in Connect but does **NOT** change the **Salesforce Case Owner**
or the **DynamoDB ownership** row. Salesforce stays the single source of truth for
ownership. So a picked-up *unassigned* email leaves no ownership trail — a later
no-`Case#` reply from that customer would auto-create (Run-As user), not route back to
the picker. To make the picker the durable owner, they do **Change Owner in Salesforce**
(manual today). Who handled it is captured in **Connect contact search**, not
`email-routing-log`.

## Scenario 4 — Outbound Email Tracking and Visibility

| Requirement | Status | Note |
|---|---|---|
| Agent-initiated outbound email | ✅ | Native email channel — agents reply and **initiate new** emails from `ordersuccess@` ("Initiate email conversation" perm + the queue **Outbound email configuration** From-address, console-only — see findings) |
| Tracking of outbound-only interactions | ✅ | Connect records outbound as a contact (Initiation method OUTBOUND / AGENT_REPLY) |
| Reporting on outbound communications | ✅ | **S4-A** — native historical metrics break out **"Contacts handled incoming" vs "outgoing" per email address**; Contact search filters **Channel=Email + Initiation method=OUTBOUND** (validated 2026-07-06) |
| Visibility into agent productivity | ✅ | Native agent metrics (handled/AHT) grouped by Agent + the incoming/outgoing split |
| Audit and review capabilities | ✅ | **S4-B** — the agent's outbound reply is logged as an **Outgoing `EmailMessage`** on the SF Case (full in + out thread for supervisor review), plus `email-routing-log` + Connect contact records (validated 2026-07-07) |
| *Success:* outbound reportable / leadership visibility / supervisors evaluate | ✅ | Metrics report + contact search (counts/handling) **and** the outbound content on the SF Case (S4-B) for content-level review |

**Scenario 4 = Built.** Outbound via the Connect native email channel (final-exercise steps 3 & 9, docs/09).

**S4-A findings (native outbound reporting, 2026-07-06):**
- **Queue Outbound email configuration is CONSOLE-only** (provider gap — `aws_connect_queue` has `outbound_caller_config` for voice but **no** `outbound_email_config`). Per queue: set Default email address = `ordersuccess@`; the **Outbound email flow is optional** (blank works). Add to the console-only rebuild checklist.
- **Metric semantics:** "Contacts handled" counts only agent-**accepted** contacts; the historical report's default range can **exclude the current day** — extend it.
- **Step-by-step guides create companion `Chat`/`API` contacts** (the SF-360 Show-view screen-pop renders as an API-initiated chat, ~1 per handled email). Filter **Channel=Email** to exclude them; prod note: adds chat-contact volume/possible cost.

**S4-B (outbound → Salesforce logging, 2026-07-07):**
- **EventBridge** rule (`aws.connect` → Connect Contact Event, `channel=EMAIL`, `eventType=COMPLETED`) → the router Lambda in **outbound-log mode** (`_handle_outbound_log`). Filters `initiationMethod ∈ {AGENT_REPLY, OUTBOUND}`; maps the reply to its Case via the inbound contact in `email-routing-log`; reads the sent body from the `EMAIL_MESSAGES` bucket (reused `connect_email.fetch_body`); posts an **Outgoing** `EmailMessage` (`Incoming=false`, Status Sent). No Kinesis. IAM adds `dynamodb:Query`.
- **SF display note:** EmailMessages show in the Case **feed ("All Updates")** and **Emails related list** (full in + out thread). The **Activity History** related list threads/groups them and may show only the latest — *not* a logging gap; review outbound on the feed/Emails list.
- **Case status on reply (2026-07-08):** the agent's first reply now **advances `Case.Status` `New → Working`** (`case_status_on_reply`, default `Working`; empty disables). Guarded — only lifts from `New`, so it never overrides a status an agent set (`Working`/`Escalated`/`Closed`). **Closing stays a manual agent decision** (replying ≠ resolving). Before this, logging EmailMessages never touched `Case.Status`, so cases sat at `New` no matter how many replies.

**Status ownership (integration boundary):** two different "statuses" with two owners — **Amazon Connect** owns the *contact/interaction* state (in-queue → accepted → completed; drives the SLA alert, auto-clears on pickup) and **Salesforce** owns the *Case business status* (`New`/`Working`/`Closed`). Connect does **not** push Case status to SF except the one write above (reply → Working). Completing the contact in Connect ends the interaction but does not close the Case.

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
| Duplicate-work **alerts** (more emails / another agent working / related cases / pending requests) | ✅ | **Built 2026-07-07** — the routing Lambda queries **other OPEN cases** for the customer's Contact/Account (`salesforce.related_open_cases`) and the **SF-360 screen-pop** shows `⚠️ N other open case(s): #NNNN (Owner, Status)` on accept. Owner column = "who else is working it". |
| *Success:* agents understand history | ✅ | via the 360 |
| *Success:* duplicate effort minimized | ✅ | Proactive `⚠️` alert on accept lists the customer's other open cases + owners, so agents don't double-work |
| *Success:* consistent CX across teams | ✅ | Same case/contact/account for everyone |

Largely delivered by the Contact/Account 360 (step 7). On native email, the agent
also gets a **Detail-view screen-pop** on accept with a clickable Salesforce Case link
+ owner (built Step 9, docs/09).

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
| Unified agent desktop | 🟡 | Connect agent workspace + a **Detail-view screen-pop** surfacing the SF Case link/owner on accept; tighter full-SF unification via the CTI adapter is an enhancement |
| Email templates and macros | ✅ | **Built 2026-07-07** — 4 email **Quick responses** (Content Management → Quick responses); agent inserts via **`/#`** + search or shortcut (e.g. `/#os`) in the reply editor. Provisioned by bulk CSV import (`docs/email-quick-responses.csv`, `*ALL*` routing profiles, Active). **Console-only** (no `aws_qconnect_*`/wisdom resource in the provider). Authoring needs **Content Management** permission. **Gotcha:** after bulk import, responses need a short **index** (or a re-save) before agents see them — re-login not required. Message templates (signature/branding) available in the same menu. **Personalized** — responses greet by name via `{{Attributes.greeting}}` (routing Lambda sets `greeting` = "Hi <SF Contact FirstName>," → email display name → "Hi,"); the inbound flow maps `greeting = $.External.greeting`. |
| Address book integration | 🔜 | Not built |
| Knowledge search | 🔜 | Amazon Q / knowledge base — not built (S8-adjacent) |
| Multi-session handling | ✅ | Agents handle multiple concurrent contacts (TASK + EMAIL concurrency) |
| Internal collaboration | ✅ | Quick connects — transfer/consult a colleague; **verified on the native email channel** (final-exercise step 8) |
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
| 1 | Thread continuity as one interaction (S1) | Each reply is a separate Connect contact (email contact on `ordersuccess@`, Task on `taskdemo@`), though all tie to one Case | Link replies via Connect related-contacts so a thread is one interaction |
| 2 | Case SLA / "overdue" tracking (**TODO — revisit**) | No SLA/response-time or "overdue" tracking; Salesforce "Overdue" applies only to due-dated Activities, not our emails | Salesforce **Entitlements & Milestones** or **Case Escalation Rules / Case Age** (Setup); or a scheduled check on `email-routing-log` |
| 3 | Duplicate-work alerts (S5) | ✅ **RESOLVED 2026-07-07** — Lambda checks related **open** cases → `⚠️` warning attribute surfaced in the SF-360 screen-pop | (done) |
| 4 | Agent self-selection / cherry-pick (S3) | ACD push only | Add a pull/manual-select queue + supervisor governance |
| 5 | Owner-queue unhandled email (**validated 2026-07-06**) — **ALERT BUILT 2026-07-07** | Reject/miss test confirmed: an unaccepted email returns to the owner's **single-agent** queue with **no fallback agent** — it waits for that owner (who is flipped to "Missed" and stops receiving new contacts until Available again). SF case logging/ownership/audit already happened in the inbound flow, so the 360 is intact regardless. | **DONE — owner-timeout SLA alert.** A scheduled EventBridge rule (`<lambda>-sla-check`) invokes the router in **`sla_check`** mode; the Lambda calls Connect **`GetCurrentMetricData`** (`OLDEST_CONTACT_AGE` + `CONTACTS_IN_QUEUE`, channel EMAIL) across all owner queues + the shared fallback and **emails a supervisor via SES (HTML table)** for any queue past `sla_threshold_seconds` (default 300s). The alert is **one consolidated email** covering all breaching queues (subject leads with severity — `SLA alert: N email(s) unhandled, oldest <dur>`): a **summary table** (Queue / Owner-agent / Waiting / Oldest) + per-queue blocks listing the waiting emails, each with its own **`waiting <dur>` chip**, sender, received time, and a **Salesforce Case pill** (blue link when known), grouped by owner→queue and **capped at the waiting count**; ends with an **Open Amazon Connect** button. A **global re-alert cooldown** (`sla_realert_minutes`, default 60) sends one email per window (not per queue). Durations roll up (`10h 20m`, `1d 16h`). **Deliberately NO overflow queue** — keeps strict owner-targeting; the alert prompts the owner/supervisor instead of reassigning. **Toggle:** `sla_alert_enabled` (default **false** → rule created but DISABLED) so it fires **only during the demo**; `sla_check_rate` sets cadence. **Delivery is SES** (`sla_from_address` on the verified `ccaas.evolvity.com` domain → `sla_alert_email`; no SNS subscription-confirmation dance). **Runbook:** `docs/11-runbook.md` §6 (resources, enable/disable, validate). **Optional variant (still TODO):** alongside the alert, **spill the unpicked owner email into `Email-Case-Queue`** after N min so it becomes cherry-pickable in the Worklist (manual-pull escalation). |
| 6 | Cherry-pick self-assign doesn't set ownership (S3) | Worklist "Assign to me" / supervisor self-assign+transfer assigns the *contact* in Connect but does **not** update the Salesforce Case Owner or DynamoDB ownership → the picker isn't the durable owner; a later no-`Case#` reply won't route back to them. | **TODO:** on self-assign, update the **SF Case Owner** (Change Owner) + write the **DynamoDB ownership** row (e.g. a flow/EventBridge hook on contact-assigned → Lambda). Manual workaround today: agent does Change Owner in Salesforce after pickup. |
| 7 | No native supervisor per-item assign (S3) | The Worklist is agent self-assign only; a supervisor cannot natively "assign this queued contact to agent X". | Workaround: supervisor **Assign to me → transfer** to the agent via quick connect; or a **custom API** tool (Connect API) for direct supervisor assignment. |

> Resolved: ownership-change on the no-case fallback (live re-read) and ownership
> transfer / supervisor reassignment (via Salesforce Change Owner, honored live).

---

## Known limitations / demo assumptions

Deliberate simplifications for this round (not defects):

| Area | Limitation | To make it production-realistic |
|---|---|---|
| Auto-created case ownership | A new auto-created Case is owned by the **REST API caller** (the Client Credentials **Run As** user), **not** round-robin / assignment rules (**not configured this round**). | Create Case Assignment Rules in Salesforce and send the `Sforce-Auto-Assign: true` header on Case create. |
| Native-email screen-pop | The Salesforce **CTI Adapter does not bridge Connect's native email channel** (voice/chat/task only), so there's **no auto-navigation** into Salesforce. **Resolved for the demo:** a Connect **Detail-view screen-pop** surfaces the Case as a clickable link + owner on accept (meets "opens and sees the 360"). | Optional: a custom Streams + Open CTI bridge for literal auto-navigation into the SF Case record. |
| Outbound deliverability | Round-trip verified externally (2026-07-06): reply delivered to inbox, **SPF PASS + DKIM PASS (aligned) on `ccaas.evolvity.com`**. **DMARC now PASS too** — `_dmarc.ccaas.evolvity.com` TXT `v=DMARC1; p=none; adkim=r; aspf=r; fo=1` published by Server Sea and **validated live 2026-07-08**. All four DNS records (MX / DKIM×3 / SPF / DMARC) green — see `docs/12-dns-serversea-requests.md`. | Optionally tighten `p=none`→`quarantine`/`reject` later once DMARC reports look clean. |
| Case # extraction from subject | Requires the word **"Case"** + a 5–10 digit number; tolerant of `#`, spaces, colon, brackets (regex `Case\s*[#:]?\s*(\d{5,10})`, validated 2026-07-06 — a space after `#` previously broke it). A **bare number** with no "Case" word is intentionally **not** matched (too ambiguous) → falls to ownership/auto-create. | The outbound reply template stamps `Case #NNNNN` so customer replies always match; loosen further only if real-world subjects need it. |
| Rendered email view | Renders the sender's **raw HTML unsanitized**. Fine for an internal demo. | Sanitize HTML before rendering. |
| Native-email attachments/inline images on the SF Case | The native-email → SF `EmailMessage` logs the **HTML body only**. Inline images (`cid:`) and file **attachments** don't appear on the Case (they render fine in the Connect agent workspace). **TODO.** | Fetch attachment objects from Connect's EMAIL_MESSAGES storage → upload to Salesforce as `ContentVersion`/`Attachment` and relate to the `EmailMessage`/Case. |
| Email link | The `Email`/rendered-view link is a **presigned URL that expires** (12h TTL). | Serve via an authenticated agent app instead of a presigned link. |
| Account activity roll-up | Emails show on the **Contact** timeline (via `EmailMessageRelation`) with no config; showing them on the **Account** timeline needs the org setting **"Roll up activities to a contact's primary account."** | Standard Salesforce config — enabled in this demo org. Account **Cases** related list shows without any setting. |
| Salesforce Case access | Task path: a `SalesforceCase` reference deep link. Native email: the **Detail-view screen-pop** Case link on accept. Both are click-through (meets "agent opens the interaction and sees"). | *Optional:* CTI Adapter (Task) / Streams+Open CTI bridge (email) for literal auto-navigation. |
| Screen-pop styling | The screen-pop uses the AWS-managed **Detail view** — **fixed fonts/colors** (the S5 alert sits in the AttributeBar for prominence). **TODO:** build a **Custom View** (no-code UI builder) for a polished look (larger font, red/bold warning banner, layout control). |

---

## Production scaling notes

Guidance for a real deployment (300–400+ agents). Not built for the demo — captured so
the demo's simplifications aren't mistaken for the prod design.

| Area | Demo (this build) | Production recommendation |
|---|---|---|
| **Agent-to-agent transfer / collaboration** | Per-agent **USER quick connects** (`Transfer-to-<agent>`), associated to queues. Fine for 2–3 agents. | **Does not scale** — per-agent QCs are O(N²) and give agents a 400-item list. Use **team/skill queue quick connects** (`Returns Team`, `Tier 2`, `Escalations`, `Supervisor`): ~5–10 entries, any available team member picks up, and a team queue has natural overflow. |
| **Reach the specific Case Owner** | N/A (named QCs) | One **dynamic `Transfer to Case Owner`** quick connect whose flow invokes the routing Lambda (`caseId → OwnerId → owner's queue`) — one entry, always correct, no list to maintain as staff change. Reuses the routing brain. |
| **Escalation** | N/A | Single `Escalate to Supervisor` queue quick connect. |
| **Ownership vs collaboration** | — | Team queues are only the *collaboration/transfer* layer; **individual ownership stays in Salesforce** (Case Owner), so owner-targeted *routing* (Scenario 1/2) is unaffected. |
| **Agents / queues / profiles** | Per-owner queue+profile+flow+user via a `for_each` `agents` map (docs/10) | The per-owner model still holds, but at 400 agents you'd typically group by **team/skill** for collaboration + reporting while keeping SF as the ownership source of truth. |

## Bonus features (beyond the client's ask)

| Feature | What it adds |
|---|---|
| In-Task email visibility | Decoded **`bodyPreview`** + an **`Email`** link to a browser-renderable HTML view (From/To/Date/Subject header + full quoted thread) — reads like a real email, no leaving Connect. |
| Salesforce Case link (deep link) | Task carries a **`SalesforceCase`** URL → one click opens the live Case 360. |
| Emails logged to the Case | Each inbound email → incoming **`EmailMessage`** on the Case + related to the Contact → shows in case/contact/account history. |
| Owner-targeted routing | Per-owner **queue + routing profile + contact flow + agent**; Lambda picks the owner's flow by `OwnerId`, shared-queue fallback. |
| End-to-end audit trail | Every routing decision in `email-routing-log` (case, owner, outcome, contactId, timestamp). |
| Full CMK encryption | S3, DynamoDB, Secrets Manager, Lambda env — all encrypted with the customer-managed KMS key. |
| Native-email SF case logging | Native email bodies fetched from Connect's EMAIL_MESSAGES storage → logged as **formatted HTML `EmailMessage`** on the Case. |
| Native-email screen-pop | Detail-view **screen-pop** on accept with a clickable Salesforce Case link + owner + **duplicate-work `⚠️` alert** (other open cases), driven by the routing Lambda's attributes. |
| Owner-timeout SLA alert | Scheduled `sla_check` → **consolidated SES HTML email** to a supervisor when an email waits past threshold (queue/owner/waiting/oldest table + per-email Case links + workspace link), global re-alert cooldown, all toggleable. Closes validated gap #5. |
| Case status on reply | The agent's first reply advances the SF **`Case.Status` `New → Working`** (guarded; never overrides later statuses) so the CRM reflects that it's being worked. |

---

## Final Demonstration Exercise — status

| # | Step | Status | Note |
|---|---|---|---|
| 1 | Customer sends an inquiry | ✅ | Inbound email received by SES |
| 2 | Salesforce case is created or identified | ✅ | Identified via `Case #`; a new inquiry auto-**creates** a Case and routes to its owner |
| 3 | Agent responds from a shared mailbox | ✅ | **Done 2026-07-06** — `ordersuccess@` on Connect native email; agent replies natively from the shared address. Hybrid (`taskdemo@`=Task path). See [09](09-outbound-connect-email-plan.md). |
| 4 | Customer replies | ✅ | Inbound reply received |
| 5 | Platform identifies the Salesforce Case ID | ✅ | Regex on subject |
| 6 | Email routes to the assigned owner | ✅ | Owner-targeted routing to the owner's agent |
| 7 | Agent opens the interaction and sees the customer 360 | ✅ | Native email: **Detail-view screen-pop** on accept (clickable Case link + owner) + email logged to the Case with full HTML body. Case linked to Contact/Account → ownership, open emails, history, open cases, related account activity |
| 8 | Agent collaborates with another employee | ✅ | USER quick connects (`Transfer-to-<agent>`) → native transfer/consult (associate to queue in console) |
| 9 | Agent sends a response | ✅ | **Done 2026-07-06** — native email reply delivered to external inbox (SPF+DKIM pass); logged to the SF Case with full HTML body |
| 10 | Interaction is tracked, reported, and auditable | ✅ | Native Connect dashboards + contact search + `email-routing-log` |
| 11 | Supervisors review routing/ownership/metrics | ✅ | Supervisor user (`demo.supervisor`, CallCenterManager) + dashboards; ownership changes in `email-routing-log` + SF case history |
