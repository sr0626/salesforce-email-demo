# Verification Plan

Run through this after deploying (see
[03-prerequisites-and-setup.md](03-prerequisites-and-setup.md) for the setup
steps this depends on).

## 1. Apply health
- Confirm `terraform apply` completes with no errors and `terraform plan` is
  clean afterward (no drift).
- Confirm the Connect instance, `Email-Case-Queue`, and `Email-Routing-Profile`
  exist in the console, and that the agent user created in doc 03 step 4 is
  assigned to that routing profile.
- Confirm the SES rule set you created manually (doc 05, Phase B) is active:
  ```bash
  aws ses describe-active-receipt-rule-set --region us-west-2
  ```

## 2. Domain verification
```bash
aws ses get-identity-verification-attributes --identities ccaas.evolvity.com --region us-west-2
```
Expect `VerificationStatus: Success` and `DkimVerificationStatus: Success`.

## 3. Salesforce Case-based routing (Scenario 1)

Send a real email from your own address to the shared mailbox address
(`ordersuccess@ccaas.evolvity.com`) with a subject containing a real Case
Number from your Salesforce dev org, e.g.:

> Subject: `RE: Case #00001001 - order question`

Then confirm, in order:
1. Raw MIME lands in the S3 bucket (`aws s3 ls s3://<bucket>/inbound/`).
2. CloudWatch Logs for the router Lambda show a successful Salesforce OAuth +
   SOQL lookup (no errors, `owner_id`/`owner_name` populated).
3. A new row appears in `EmailRoutingLog` DynamoDB table with
   `routingOutcome: resolved` and the correct `resolvedOwnerName`.
4. `MailboxOwnership` table has a new/updated item for
   `(mailbox, your-test-address)`.
5. A new Task is visible in Amazon Connect with the `ownerName` /
   `ownerId` / `caseId` attributes set — check via
   `aws connect describe-contact --instance-id <id> --contact-id <id>` or the
   agent workspace UI (Contact Search).

**Success bar (matches the client's stated criteria):** no manual reassignment
needed, routing used real Salesforce data, and ownership is immediately
reflected (change the Case Owner in Salesforce, resend, confirm the new owner
shows up on the next Task).

## 4. Shared mailbox ownership continuity (Scenario 2)

Send a **second** email from the *same* test address to the *same* shared
mailbox (`ordersuccess@ccaas.evolvity.com`), but this time **without** a case
number in the subject (simulating a
reply that doesn't echo it, or a follow-up typed fresh):

> Subject: `Following up on my order`

Confirm:
1. Router Lambda logs show it took the fallback path (`MailboxOwnership`
   lookup by `(mailbox, fromAddress)`), not a fresh Salesforce query.
2. `EmailRoutingLog` shows `routingOutcome: fallback` with the **same**
   `resolvedOwnerName` as the first email.
3. The new Connect Task carries the same owner attribute.

**Success bar:** ownership persists across the thread even when the case
number isn't repeated — internal ownership stays visible/auditable, matching
the client's "shared mailbox appears seamless to customers, ownership remains
visible internally" bar.

## 5. Unassigned / first-contact case

Send an email from a brand-new address, no case number, never seen before.
Confirm it still creates a Task (doesn't error out), tagged
`ownerId: UNASSIGNED` / `ownerName: Unassigned`, and logs
`routingOutcome: unassigned`. This is the documented POC gap (no
claim-on-pickup mechanism yet) — verify it fails *gracefully*, not silently
or with an unhandled exception.

## 6. Standalone deploy check
Confirm the whole repo deploys cleanly into a fresh AWS account/region with no
dependency on any other repo or pre-existing resource — root `main.tf` is the
only entry point (`terraform init && terraform apply`), and
`./scripts/teardown.sh` (`terraform destroy`) cleanly removes everything except
the inbound-email S3 bucket, which is protected by `prevent_destroy = true`.
