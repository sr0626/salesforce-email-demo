# SES Setup Guide — fully manual (AWS Console), using evolvity.com

Goal: let Amazon SES **receive** mail for this POC so an email to the shared
mailbox `ordersuccess@ccaas.evolvity.com` triggers the router Lambda.

**All SES setup is done by hand in the AWS Console — no Terraform manages any
SES resource.** Terraform only builds the S3 bucket, DynamoDB tables, Secrets
Manager secret, the Lambda, and Connect. You wire SES to them manually here.

## The key decision: use a SUBDOMAIN, not evolvity.com itself

`evolvity.com` already hosts real email at Server Sea. To receive mail, SES
requires an **MX record pointing at AWS** (`inbound-smtp.<region>.amazonaws.com`).
If you point the MX for `evolvity.com` at AWS, **all existing evolvity.com email
breaks**. So we carve out a dedicated subdomain used only by this POC:

> **`ccaas.evolvity.com`**

Its MX points at AWS; the root `evolvity.com` MX is left untouched, so your
normal mailboxes keep working. The demo's shared mailbox address is therefore:

> **`ordersuccess@ccaas.evolvity.com`**

## Region
Use **`us-west-2`** (Oregon). SES email *receiving* is only supported in a
subset of regions; `us-west-2`, `us-east-1`, `eu-west-1` are the safe classic
choices. Do every console step below with the region selector set to
**us-west-2**.

> **SES sandbox note:** the sandbox only restricts *sending*. **Receiving works
> immediately** once the domain identity is verified and a receipt rule set is
> active — no production-access request needed.

## Where the DNS records go — Cloudflare (NOT Server Sea)
`evolvity.com`'s nameservers are delegated to **Cloudflare**
(`chris.ns.cloudflare.com` / `paloma.ns.cloudflare.com`, confirmed via
`dig NS evolvity.com +short`). Server Sea is only the registrar — records added
in the Server Sea "DNS Records" panel are **ignored**. Add every record below in
the **Cloudflare dashboard**: log in → select the **evolvity.com** zone →
**DNS → Records → Add record**.

Cloudflare specifics:
- **Set every record to "DNS only" (grey cloud, proxy OFF).** A proxied
  (orange-cloud) DKIM CNAME breaks DKIM verification. MX is never proxied.
- For **Name**, type the short label (`ccaas`, `<token>._domainkey.ccaas`);
  Cloudflare auto-appends `.evolvity.com`.
- The existing root MX is `10 mail.evolvity.com` (Server Sea email). **Leave it
  alone** — you only add `ccaas` records, so root email keeps working.

---

# PHASE A — Domain identity + verification (do this NOW)

This is the slow part (DNS propagation), so start it first and let it bake while
you set up Salesforce and we build the Terraform.

## A1. Create the SES domain identity (Console)
1. AWS Console → **Amazon SES** (region **us-west-2**).
2. Left nav → **Identities** → **Create identity**.
3. Choose **Domain**.
4. Domain: `ccaas.evolvity.com`
5. Leave **Assign a default configuration set** unchecked.
6. **Advanced DKIM settings**: keep **Easy DKIM**, key length **RSA_2048_BIT**,
   and leave **DKIM signatures** enabled.
7. Leave **Custom MAIL FROM** off (not needed for receiving).
8. **Create identity.**

SES now shows the identity as *Verification pending* and displays **3 CNAME
records** under the DKIM section.

## A2. Add the DNS records at your evolvity.com DNS host

**a) 3× DKIM CNAME records** — copy the exact Name/Value pairs SES shows on the
identity page (they look like the table below; the tokens are unique to you):

| Type  | Host / Name                       | Value / Points to             |
|-------|-----------------------------------|-------------------------------|
| CNAME | `<token1>._domainkey.ccaas`       | `<token1>.dkim.amazonses.com` |
| CNAME | `<token2>._domainkey.ccaas`       | `<token2>.dkim.amazonses.com` |
| CNAME | `<token3>._domainkey.ccaas`       | `<token3>.dkim.amazonses.com` |

**b) 1× MX record** (routes inbound mail for the subdomain to SES):

| Type | Host / Name | Value / Points to                       | Priority |
|------|-------------|-----------------------------------------|----------|
| MX   | `ccaas`     | `inbound-smtp.us-west-2.amazonaws.com`  | 10       |

> **The SES console does NOT show you this MX record** — it's a fixed value you
> type yourself (only DKIM CNAMEs are shown, because their tokens are unique to
> you). The MX host is always `inbound-smtp.<region>.amazonaws.com`.

> Adding the 3 DKIM CNAMEs both **verifies** the domain identity and enables
> DKIM — with Easy DKIM there is no separate `_amazonses` TXT record to add.
> Do **not** add or change any record for the bare `evolvity.com`.

**c) Optional — DMARC TXT.** During identity creation SES may offer a DMARC
record (`_dmarc.ccaas` → `v=DMARC1; p=none;`). It is **not required for
receiving** — `p=none` is monitor-only. Skip it for this POC, or add it if you
like; scoped to `_dmarc.ccaas`, it does not affect the root `evolvity.com`.

## A3. Wait for propagation & confirm
From your Mac (basic check via your default resolver):
```bash
dig CNAME <token1>._domainkey.ccaas.evolvity.com +short   # → <token1>.dkim.amazonses.com
dig MX    ccaas.evolvity.com +short                       # → 10 inbound-smtp.us-west-2.amazonaws.com
```

### A3.1 Validate the records landed in the AUTHORITATIVE (Cloudflare) zone
Because evolvity.com is delegated to Cloudflare (see "Where the DNS records go"),
records only count if they resolve from the **authoritative Cloudflare
nameservers** — not the stale cPanel/`hostingcare.net` zone. When Server Sea
adds records on your behalf, **verify the right zone** with these targeted
queries:

```bash
# 1) Ask the AUTHORITATIVE Cloudflare NS directly — MUST return the values:
dig +short CNAME <token1>._domainkey.ccaas.evolvity.com @chris.ns.cloudflare.com
dig +short MX    ccaas.evolvity.com                      @chris.ns.cloudflare.com

# 2) Ask public resolvers (they follow the delegation to Cloudflare) — MUST also return:
dig +short CNAME <token1>._domainkey.ccaas.evolvity.com @1.1.1.1
dig +short CNAME <token1>._domainkey.ccaas.evolvity.com @8.8.8.8

# 3) Sanity: root evolvity.com MX must be UNCHANGED (existing Server Sea email):
dig +short MX evolvity.com                               # → 10 mail.evolvity.com
```

> **Gotcha (seen on this project):** Server Sea's first attempt added the records
> to the stale cPanel/WHM local zone instead of Cloudflare. Symptom: the records
> resolve when you query `@ns6172.hostingcare.net` but return **empty** from
> `@chris.ns.cloudflare.com` and from public resolvers. If you see that, reply on
> the ticket asking them to add the records to the **Cloudflare zone** (the
> authoritative one), not the local cPanel zone.

### A3.2 Ready-to-run check (real tokens for this project)
Paste this whole block into your terminal:

```bash
echo "=== 1) AUTHORITATIVE Cloudflare NS (these MUST return values) ==="
for t in bj4fg2dczesbsaksidgps2ghnzk7fvxx d7nhzqijteqeaj5woo7faiqts5x6g6gz jp2eblkalqecov3y6tyctjzgq6tsibk7; do
  printf "  %s -> %s\n" "$t" "$(dig +short CNAME ${t}._domainkey.ccaas.evolvity.com @chris.ns.cloudflare.com)"
done
printf "  MX ccaas -> %s\n" "$(dig +short MX ccaas.evolvity.com @chris.ns.cloudflare.com)"

echo "=== 2) PUBLIC resolvers (should match once propagated) ==="
printf "  1.1.1.1 -> %s\n" "$(dig +short CNAME bj4fg2dczesbsaksidgps2ghnzk7fvxx._domainkey.ccaas.evolvity.com @1.1.1.1)"
printf "  8.8.8.8 -> %s\n" "$(dig +short CNAME bj4fg2dczesbsaksidgps2ghnzk7fvxx._domainkey.ccaas.evolvity.com @8.8.8.8)"

echo "=== 3) STALE cPanel zone (wrong zone - for comparison only) ==="
printf "  hostingcare -> %s\n" "$(dig +short CNAME bj4fg2dczesbsaksidgps2ghnzk7fvxx._domainkey.ccaas.evolvity.com @ns6172.hostingcare.net)"

echo "=== 4) SANITY: root MX must stay 10 mail.evolvity.com ==="
printf "  root MX -> %s\n" "$(dig +short MX evolvity.com)"
```

**Reading it:** fixed when **section 1** returns the `...dkim.amazonses.com`
values + `10 inbound-smtp.us-west-2.amazonaws.com`. Section 3 returning values
while section 1 is empty = still in the wrong zone. Section 4 must always show
`10 mail.evolvity.com`.

In the SES console the identity's **Status** flips to **Verified** and DKIM to
**Successful** once the CNAMEs are seen from the authoritative zone (minutes to a
few hours). You can also check via CLI:
```bash
aws ses get-identity-verification-attributes --identities ccaas.evolvity.com --region us-west-2
```

**Phase A is complete when the identity is Verified.** You can move on to
Salesforce and the Terraform build now; do Phase B after the Terraform apply
creates the S3 bucket and Lambda.

---

# PHASE B — Receipt rule (do this AFTER `terraform apply`)

The receipt rule points at the **S3 bucket** and **Lambda** that Terraform
creates, so it can only be built once those exist. After `terraform apply`, note
these two outputs: `inbound_bucket` (bucket name) and `email_router_lambda_arn`.

## B1. Choose the rule set (Console)
SES allows only **one active receipt rule set per region**. Check
SES → **Email receiving** → **Rule sets** first:

- **If an active rule set already exists** (e.g. Amazon Connect's email channel
  auto-creates `AmazonConnectEnabledRuleSet-DO-NOT-DELETE`), **do NOT create a
  new one and set it active** — that would deactivate the existing one. Instead
  **open the active rule set and add the rule below into it** (B2). Our specific
  recipient (`ordersuccess@ccaas.evolvity.com`) won't overlap other rules.
  > Caveat: a Connect-managed rule set may be re-synced by Connect and drop
  > custom rules. If routing stops, re-add this rule.
- **If there is no active rule set:** create one — **Create rule set**, name
  `ccaas-email-poc-ruleset` (any name) — then add the rule (B2) and **Set as
  active** (B3).

## B2. Create the rule
Open the rule set (the active one from B1) → **Create rule**.
1. **Rule settings / Security options:**
   - Name: `route-to-email-router`, status **Enabled**.
   - **Transport Layer Security (TLS): `Optional`** — accept mail regardless of
     whether the sender uses TLS. (`Require` also works if you only test from
     TLS-capable senders like Gmail/Outlook, but `Optional` avoids surprise
     rejections in a demo.)
   - **Spam and virus scanning: `Enabled`** — SES only *tags* the message with
     verdict headers; it does not block delivery. Harmless and useful.
2. **Recipient conditions** — add: `ordersuccess@ccaas.evolvity.com`.
3. **Actions** — add these two, **in this order**:
   - **Deliver to Amazon S3 bucket**
     - Bucket: the `inbound_bucket` from Terraform outputs
     - Object key prefix: `inbound/`
     - **Encryption / KMS key: leave BLANK.** The bucket already has default
       SSE-KMS with the CMK, so objects are encrypted at rest automatically and
       the key policy (below) lets SES write them. Specifying a key here would
       make SES *client-side* encrypt instead — redundant; blank is simplest.
     - (Terraform already attached the bucket policy allowing SES to write, so
       you don't need SES to create one — if prompted, you can skip/allow;
       existing policy stays.)
     - **KMS (only because the bucket uses a customer-managed key):** the bucket
       is encrypted with the CMK
       `arn:aws:kms:us-west-2:044336301301:key/71cf9f1f-...`. For SES to write
       encrypted objects, **that KMS key's policy must allow the SES service
       principal** to use it. If SES delivery fails with an
       `AccessDenied`/KMS error, add this statement to the **key policy** (KMS
       console → the key → Key policy → edit):
       ```json
       {
         "Sid": "AllowSESToEncryptInbound",
         "Effect": "Allow",
         "Principal": { "Service": "ses.amazonaws.com" },
         "Action": ["kms:GenerateDataKey", "kms:Encrypt"],
         "Resource": "*",
         "Condition": { "StringEquals": { "aws:SourceAccount": "044336301301" } }
       }
       ```
       (If you'd rather avoid editing the key policy, set `kms_key_arn = ""` for
       just the inbound bucket — but the project standard is to use the CMK.)
   - **Invoke AWS Lambda function**
     - Function: the router Lambda (`email-case-router-lambda`)
     - Invocation type: **Event** (asynchronous)
     - When prompted **"Allow SES to invoke this function?" → Yes.** This adds
       the Lambda resource-based permission for you (no manual/CLI step needed).
4. **Save / Create rule.**

## B3. Make the rule set active
A region can have only one **active** receipt rule set, and rules only fire when
their set is active.
1. SES → **Email receiving** → **Rule sets**.
2. Select `ccaas-email-poc-ruleset` → **Set as active**.

Confirm:
```bash
aws ses describe-active-receipt-rule-set --region us-west-2
```

## B4. Send a test
Email `ordersuccess@ccaas.evolvity.com` from any address. Within a few seconds:
- raw MIME appears under `s3://<inbound_bucket>/inbound/`
- the router Lambda's CloudWatch logs show an invocation

See [04-verification-plan.md](04-verification-plan.md) for the full end-to-end
checks.

---

## Quick reference
- Subdomain: **`ccaas.evolvity.com`**
- Shared mailbox: **`ordersuccess@ccaas.evolvity.com`**
- Region: **us-west-2**
- MX value: `10 inbound-smtp.us-west-2.amazonaws.com`
- Set these as Terraform variables too:
  `ses_domain = "ccaas.evolvity.com"`,
  `shared_mailboxes = "ordersuccess@ccaas.evolvity.com"` (the Lambda uses them,
  even though Terraform doesn't create any SES resource).
