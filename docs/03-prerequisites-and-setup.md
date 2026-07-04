# Prerequisites & External Setup

These are steps the user (not the implementing agent) must complete outside the
Terraform code. Do the DNS + Salesforce parts **before** — or in parallel with,
since DNS propagation is slow — running `terraform apply`.

Two of these have dedicated step-by-step guides; this doc is the checklist that
ties them together:
- SES / domain → [05-setup-ses-evolvity.md](05-setup-ses-evolvity.md)
- Salesforce dev org → [06-setup-salesforce-dev-org.md](06-setup-salesforce-dev-org.md)

## 0. Tooling on your Mac
- **Terraform** >= 1.6 (`brew install terraform`)
- **AWS CLI** v2 configured with credentials for the target account
  (`aws configure`), default region `us-west-2`
- That's it — the Lambda is packaged by Terraform's `archive_file`, so no Python
  build step is required.

## 1. Domain for SES inbound email (subdomain of evolvity.com) — MANUAL
**SES is set up entirely by hand in the AWS Console — Terraform manages no SES
resource.** Full walkthrough in [05-setup-ses-evolvity.md](05-setup-ses-evolvity.md).
In short:
- We use the subdomain **`ccaas.evolvity.com`** so existing `evolvity.com` email
  at Server Sea is never touched.
- **Phase A (now):** in the SES console create the `ccaas.evolvity.com` domain
  identity (Easy DKIM), then add at your DNS host:
  - **3× CNAME** DKIM records (values shown on the SES identity page)
  - **1× MX** record: `ccaas.evolvity.com → 10 inbound-smtp.us-west-2.amazonaws.com`
  and wait for the identity to show **Verified**.
- **Phase B (after `terraform apply`):** in the SES console create the receipt
  rule set + rule, pointing at the Terraform-created `inbound_bucket` (S3 action)
  and router Lambda (Lambda action), then set the rule set active.
- Region must support SES receiving — `us-west-2` (the default) does.
- **SES sandbox note:** the sandbox only restricts *sending*. Receiving works
  immediately once the domain is verified and the rule set is active.

## 2. Salesforce Developer Edition org
Full walkthrough in [06-setup-salesforce-dev-org.md](06-setup-salesforce-dev-org.md).
It's free and cloud-based (nothing to install). In short: sign up → create a
Connected App with the **Client Credentials** flow (scope `api`, Run-As a user
who can read Cases) → note the **Consumer Key/Secret** → create a few sample
**Case** records and note their Case Numbers for the test emails.

## 3. Populate the Secrets Manager secret (after apply)
Terraform creates the secret with placeholder values (and ignores later changes
to its value). After you have the real Connected App credentials:
```bash
aws secretsmanager put-secret-value \
  --secret-id "<instance_alias>-salesforce-credentials" \
  --secret-string '{"client_id":"<consumer_key>","client_secret":"<consumer_secret>","login_url":"https://login.salesforce.com"}' \
  --region us-west-2
```
(Default `instance_alias` is `ccaas-email-poc`.)

## 4. Create a Connect agent user (after apply)
Terraform creates a brand-new Connect instance with no users. To see a routed
Task land somewhere:
1. Open the Connect console (`connect_console_url` output,
   `https://<instance_alias>.my.connect.aws`).
2. Users → Add new user. Assign it the `Email-Routing-Profile` routing profile
   and a security profile with Task permissions (e.g. the default Agent
   profile).
3. Log in as that agent (or use the CCP) and set status to Available so it can
   receive Tasks from `Email-Case-Queue`.

## 5. Deploy
Set your values in `terraform.tfvars` (copy from `terraform.tfvars.example`) —
at minimum confirm `ses_domain = "ccaas.evolvity.com"` and
`shared_mailboxes = "ordersuccess@ccaas.evolvity.com"` — then:
```bash
./scripts/deploy.sh          # wraps terraform init + apply, prints outputs
```
or run Terraform directly:
```bash
terraform init
terraform apply
```
Then do the manual SES **Phase B** (step 1 / doc 05) using the `inbound_bucket`
and `email_router_lambda_arn` outputs, and the Secrets Manager population
(step 3).

> Reminder: per the project's global rules, the implementing agent does not run
> `terraform apply` or AWS CLI commands — you run these.
