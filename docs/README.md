# CCaaS Demo POC — Email Routing on Amazon Connect

Implementation-ready spec for a **new, standalone Terraform** repo that demos
Salesforce case-based email routing on Amazon Connect. Written so a fresh Claude
session (VS Code) can implement it directly from these docs without prior
conversation context — create a new repo and build against this spec; it has no
dependency on any other project.

**Read in this order:**
1. [00-context.md](00-context.md) — why this exists, the demo scenarios, what's
   in/out of scope for this round, locked-in architecture decisions.
2. [01-architecture.md](01-architecture.md) — data flow diagram, component list,
   rationale for each design choice.
3. [02-implementation-spec.md](02-implementation-spec.md) — the actual build
   spec: Terraform repo layout, 4 modules, exact resource shapes, IAM policies,
   the full Lambda handler, root `main.tf`/`outputs.tf`/`deploy.sh` design. This
   is the doc to work from when writing code. (SES has no module — it's set up
   manually per doc 05.)
4. [03-prerequisites-and-setup.md](03-prerequisites-and-setup.md) — the external
   setup checklist (tooling, SES domain/DNS, Salesforce, secret population,
   Connect agent user) to do before/alongside `terraform apply`.
5. [05-setup-ses-evolvity.md](05-setup-ses-evolvity.md) — step-by-step SES
   receiving setup using the `ccaas.evolvity.com` subdomain.
6. [06-setup-salesforce-dev-org.md](06-setup-salesforce-dev-org.md) —
   step-by-step free Salesforce Developer org + Connected App setup.
7. [04-verification-plan.md](04-verification-plan.md) — end-to-end test
   checklist proving Scenario 1 (Salesforce case routing) and Scenario 2
   (shared mailbox ownership continuity) actually work.

**Scope of this round:** Scenario 1 + Scenario 2 only (from the 8 demo
scenarios). Scenarios 3/6 need no new build (reuse this round's queue/attribute
plumbing). Scenarios 4/5/7/8 are explicitly out of scope — see
[00-context.md](00-context.md) for why.

**Stack:** Terraform (>= 1.6), AWS provider (>= 5.x), **local state**. Cost-
minimal: Task channel only, **no** Kinesis data streaming / call recording /
Contact Lens. Inbound email via a real SES-verified subdomain
(`ccaas.evolvity.com`) — **SES is configured manually in the console, not by
Terraform** (see doc 05). Case→Owner data from a real Salesforce Developer org.

**Status:** planning complete, no code written yet. This is a fresh repo — it
creates its own Amazon Connect instance, queue, routing profile, and task flow
from scratch (not layered onto any existing Connect deployment), plus the
SES/Salesforce/Lambda/DynamoDB email-routing pieces.
