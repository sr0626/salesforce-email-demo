# CCaaS Demo POC — Context & Scope

## Source document
This POC is derived from `the client's Contact Center Replacement Summary.docx`
(discovery notes for the client's Five9 → CCaaS replacement evaluation).

## Why this POC exists
The client's evaluation is **email-centric**, not voice-centric. Their customer service
org relies on Salesforce Service Cloud + Five9, and email is the primary area
under evaluation. Suppliers (including a candidate Amazon Connect solution) are
expected to demo specific business scenarios, not generic contact-center
features.

Key facts from the discovery doc:
- **330** named agents, 13 supervisors, 5 admins, inbound & outbound center.
- **1.3M emails/year**, 780K calls/year. Current stack: **Five9** (CCaaS) +
  **Mitel** (PBX/UC).
- Integrations required: Salesforce Service Cloud, OrderHub, AmplifAI, Mitel PBX,
  Absorb LMS, UKG (optional), Qualtrics, Echoes sentiment, SAML SSO, Azure.
- Pain points driving replacement: Five9's poor email management, poor outbound
  visibility, complex/fragile Salesforce routing, reporting/audit gaps.
- AI is explicitly **low current priority** — a future consideration, not a
  buying criterion today.

## The 8 supplier demonstration scenarios (from the doc)
1. **Salesforce case-based email routing** — outbound emails include a Case
   Number in the subject; replies must auto-route back to the Case Owner with no
   manual reassignment.
2. **Shared mailbox with individual ownership** — 100+ agents share addresses
   like `ordersuccess@company.com`, but ownership per thread must stay visible/
   auditable and replies must route to the original owner.
3. **Hybrid routing (ACD + agent self-selection)** — some teams need automatic
   assignment, others need queue visibility + cherry-picking, simultaneously.
4. **Outbound email tracking and visibility** — outbound must be tracked/
   reportable like inbound (currently a Five9 gap).
5. **Customer/account-level visibility** — agents need full history (open
   emails, cases, related account activity) before responding; duplicate-work
   prevention.
6. **Complex routing using CRM data** — routing by Case Owner, Account
   Ownership, product/order/case-type business rules, admin-maintainable.
7. **Agent productivity/collaboration** — unified desktop, templates, knowledge
   search, shared drafts.
8. **AI and future-state capabilities** — draft suggestions, agent assist,
   sentiment — explicitly **not** a near-term buying criterion.

Final ask: a single end-to-end walkthrough (inquiry → case → shared-mailbox
reply → auto-route to owner → agent sees full context → resolution, tracked and
auditable) with **minimal customization**.

## POC scope decision
Building all 8 scenarios is not worth it for a first POC. This POC targets the
two scenarios the client weighted highest and that are structurally the hardest to
fake — if these work, the rest is largely reuse:

- **Scenario 1** — Salesforce case-based email routing (build, this round)
- **Scenario 2** — Shared mailbox with individual ownership (build, this round)
- **Scenario 3 / 6** — Hybrid & CRM-based routing — **no new build**; both reuse
  the same queue + contact-attribute plumbing this POC creates.
- **Scenario 4, 5, 7** — out of scope for this round (outbound tracking,
  account-level visibility UI, agent productivity tooling).
- **Scenario 8 (AI)** — explicitly skipped; the client itself flagged this as low
  priority.

## This is a new, standalone repo
This POC is built as its **own new repo** — not layered onto any existing
project. It's a self-contained **Terraform** configuration (organized into
small single-purpose modules, orchestrated by a root `main.tf`) that deploys
everything it needs from scratch: Amazon Connect instance, queue, routing
profile, and task flow, plus the SES/Salesforce/Lambda/DynamoDB email-routing
layer on top. No dependency on any other repo or pre-existing AWS resource. See
[02-implementation-spec.md](02-implementation-spec.md) for the full module
list and conventions.

## Architecture decisions already locked in (do not re-litigate without reason)
These were explicitly chosen over simpler alternatives, in order to make the
demo credible rather than a toy:

1. **Inbound email via a real SES domain** (not a simulated S3 drop). Requires
   the user to own a domain/subdomain and edit its DNS.
2. **Case/owner data from a real Salesforce Developer Edition org** via REST API
   (Client Credentials OAuth), not a DynamoDB mock standing in for Salesforce.
3. **Routed emails become Amazon Connect Tasks in the existing shared queue**,
   tagged with an `ownerName`/`ownerId` attribute for visibility — not true
   direct-to-agent routing (that's a documented future enhancement, not this
   round).
