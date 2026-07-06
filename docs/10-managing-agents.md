# Managing agents (add / remove an owner-agent)

Owner-agents are driven by **one source of truth**: the `agents` map in
`code/terraform.tfvars`. You never edit the Connect module — add or remove a map
entry and `terraform apply`. Everything downstream is derived automatically.

## What one `agents` entry creates

For each entry (via `for_each` in `modules/connect`), Terraform builds a full
owner-targeted lane:

| Resource | Name pattern | Purpose |
|---|---|---|
| `aws_connect_queue.owner[key]` | `Owner-<key>-Queue` | The owner's queue (Task **and** native email) |
| `aws_connect_routing_profile.owner[key]` | `Owner-<key>-Profile` | Serves only that queue; TASK + EMAIL channels |
| `aws_connect_contact_flow.owner[key]` | `Owner-<key>-Routing` | Task-path flow → owner's queue |
| `aws_connect_user.owner[key]` | `<username>` | The Connect agent login |
| `aws_connect_quick_connect.owner[key]` | `Transfer-to-<key>` | Agent-to-agent transfer/consult (collaboration) |

And it feeds two maps to the router Lambda **automatically** (no extra wiring):
- `owner_flow_map`  — Salesforce `OwnerId` → owner flow ARN (Task path).
- `owner_queue_map` — Salesforce `OwnerId` → owner queue ARN (native-email flow mode).

So routing for **both** channels updates the moment you apply. Unmapped owners
fall back to the shared `Email-Case-Queue` (`fallback_queue_arn`).

> The **shared** `demo.agent` and the `demo.supervisor` are separate (root vars
> `agent_username` / `supervisor_username`), **not** part of the `agents` map.

---

## Add an agent

1. **Get the Salesforce OwnerId (18-char)** for the person who owns the cases this
   agent should receive. In Salesforce: open a Case they own → the User record URL,
   or run
   `SELECT Id, Name FROM User WHERE Name = 'First Last'` in the Developer Console.
   The `Id` must be the **18-character** form (the Lambda matches on it exactly).
2. **Add an entry** to `agents` in `terraform.tfvars` (key = a short logical name):
   ```hcl
   agents = {
     epic = { … }                      # existing
     nina = {
       username            = "agent.nina"
       password            = "Str0ngTemp!"   # temp; agent resets at first login
       first_name          = "Nina"
       last_name           = "Rao"
       salesforce_owner_id = "005dL00001AbCdEQAX"   # 18-char OwnerId
     }
   }
   ```
3. **Apply:**
   ```bash
   cd code && terraform plan   # expect ~5 to add (queue, profile, flow, user, quick connect)
   terraform apply
   ```
4. **Post-apply (console, one-time):**
   - The agent logs into the CCP/agent workspace and sets status **Available**
     (routing only delivers to an Available agent on the EMAIL/TASK channel).
   - **Collaboration:** associate the new `Transfer-to-nina` quick connect to the
     queues that should be able to transfer to her (Console → Queues → Quick
     connects). **This is a console step, not Terraform** — setting `quick_connect_ids`
     inline on the queue creates a dependency cycle
     (`queue → quick_connect → user → routing_profile → queue`), and the provider has
     no standalone association resource to break it. Works the same for native email
     as for Task/voice/chat.

That's it — no Lambda redeploy, no flow edits. `owner_flow_map` / `owner_queue_map`
pick up the new owner on the same apply.

---

## Remove an agent

1. **Reassign their Salesforce cases first.** In Salesforce, Change Owner on the
   cases this person owns to a still-active owner. This matters because routing
   resolves the **current** owner live — after reassignment, replies route to the new
   owner; if you skip it, emails for those cases fall back to the shared queue.
2. **Drain in-flight work.** Make sure the agent has no active contacts and their
   `Owner-<key>-Queue` is empty (Contact search / real-time metrics). Removing the
   queue while contacts sit in it orphans them.
3. **Delete the entry** from the `agents` map in `terraform.tfvars`.
4. **Apply:**
   ```bash
   cd code && terraform plan   # expect ~5 to destroy for that key
   terraform apply
   ```
   No `prevent_destroy` on owner resources, so this removes the queue, profile, flow,
   user, and quick connect cleanly. `owner_flow_map` / `owner_queue_map` drop that
   owner automatically → any stray email for them uses the shared fallback queue.
5. **Cleanup notes:**
   - **DynamoDB ownership rows** for that owner aren't auto-deleted, but they're
     harmless: the Lambda re-reads the case's current owner live, so a stale row just
     resolves to the (reassigned) owner or the fallback. Optionally delete rows in
     `salesforce-email-demo-mailbox-ownership` for tidiness.
   - Removing the **last** agent (`agents = {}`) leaves `owner_*_map` empty → all
     routing goes to the shared `Email-Case-Queue` / shared flow.

---

## Gotchas

- **OwnerId format:** always the 18-char Id. A 15-char Id won't match and the owner
  falls back to the shared queue.
- **`username` must be unique** in the Connect instance; reusing a removed agent's
  username later is fine once the old user is destroyed.
- **Passwords** live in `terraform.tfvars`, which is gitignored — keep it out of
  version control.
- **tfvars is the only file you touch.** If you find yourself editing
  `modules/connect`, stop — the `for_each` already handles N agents.
