# Architecture

## Data flow

```
Inbound email → SES Receipt Rule (verified domain)
                  ├─ Action 1: store raw MIME → S3 (new bucket)
                  └─ Action 2: invoke Lambda (email router)
                                  │
                                  ├─ parse Subject for Case Number (regex)
                                  ├─ if found → Salesforce SOQL query (Case → OwnerId/Owner.Name)
                                  │             → upsert MailboxOwnership DynamoDB table
                                  ├─ else      → look up MailboxOwnership table by (mailbox, fromAddress)
                                  ├─ write EmailRoutingLog DynamoDB row (audit trail)
                                  └─ Connect StartTaskContact → Email Task Flow → EmailQueue
                                       (Attributes: caseId, ownerId, ownerName, mailbox, isSharedMailbox)
```

## Components

| Component | Role |
|---|---|
| Amazon Connect Instance | Created fresh by this repo (Connect-managed users) |
| Amazon Connect `EmailQueue` / `RoutingProfile` | Created fresh, Task-channel only (concurrency 5) |
| SES domain identity | Verified domain that can receive mail for the shared mailbox address(es) |
| SES Receipt Rule | Routes inbound mail to two actions: archive to S3, invoke Lambda |
| S3 inbound-email bucket | Raw MIME archive (audit trail, replay-ability) |
| Email router Lambda | All the business logic — see [02-implementation-spec.md](02-implementation-spec.md) |
| Secrets Manager secret | Salesforce Connected App credentials (client id/secret/login URL) |
| DynamoDB `MailboxOwnership` | Current-state table: `(mailbox, customerEmail)` → owner |
| DynamoDB `EmailRoutingLog` | Append-only audit trail of every routing decision |
| Salesforce (real dev org) | System of record for Case → Owner |
| Amazon Connect Task Flow | Receives the Task, transfers into `EmailQueue` |

## Why this shape

- **SES → S3 + Lambda (both actions on one rule)** is the standard AWS pattern
  for inbound email processing — no extra S3 event-notification wiring needed,
  and it gives a raw-MIME audit copy for free.
- **Live Salesforce query on every case-numbered email** (rather than a sync
  job) trivially satisfies PCNA's Scenario 1 success criterion "ownership
  changes are reflected immediately" — there is no cache to go stale.
- **`MailboxOwnership` as a fallback lookup** (not the primary source of truth)
  handles reply threads that don't echo the case number in the subject, which
  is the practical edge case behind Scenario 2's "ownership continuity" bar.
- **Shared queue + contact attribute** instead of true direct-to-agent routing
  keeps the POC's Terraform/Lambda footprint small while still visibly proving
  "ownership stays visible and auditable" — the literal Scenario 2 success
  criterion. Direct-to-agent (per-agent Quick Connects) is a valid v2 upgrade,
  not required to prove the concept.
- **No Salesforce mock** — a demo audience evaluating a real CCaaS replacement
  will not be convinced by a DynamoDB table pretending to be Salesforce; a free
  Salesforce Developer Edition org costs nothing and makes the demo real.
