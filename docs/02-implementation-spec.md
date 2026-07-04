# Implementation Spec — standalone Terraform repo

This is a **brand-new repo** built with **Terraform**, not an add-on to any
existing project. It deploys fully independently: its own Amazon Connect
instance, queue, routing profile, and task flow, plus the
SES/Salesforce/Lambda/DynamoDB email-routing layer on top. Nothing here depends
on any other repo or pre-existing AWS resource.

## Repo conventions to follow

- **Terraform** (>= 1.6), AWS provider (>= 5.x). **Local state** for this POC
  (a `terraform.tfstate` on disk — no remote backend). If this is ever promoted
  beyond a POC, switch to an S3 backend at that point; not needed now.
- **Small single-purpose modules** under `modules/`, one concern per module
  (Connect, email-storage, salesforce-secret, email-router). The
  root `main.tf` wires them together, passing every value a module needs
  **explicitly** as inputs (`module.x.output` → `module.y` variable) — no hidden
  globals. Module ordering is expressed through these input/output references
  (Terraform builds the dependency graph automatically; add explicit
  `depends_on` only where a data dependency isn't visible to the graph).
- All tunables live in `variables.tf` with sensible defaults; a
  `terraform.tfvars.example` documents what the user sets. No secrets in
  `.tfvars` that gets committed — real Salesforce creds go into Secrets Manager
  post-apply (see doc 03).
- The Lambda is **Python 3.12**, stdlib-only where possible (`boto3` for AWS,
  `urllib.request` for outbound HTTP to Salesforce, `re` for parsing). Source
  lives as a real file at `modules/email-router/src/index.py` and is zipped by
  the `archive_file` data source — no layers/packaging pipeline needed for this
  POC's size.
- DynamoDB tables: `billing_mode = "PAY_PER_REQUEST"`, point-in-time recovery
  off.
- **Cost-minimal:** Task channel only. **No** Kinesis data streaming, **no**
  contact/call recording, **no** Contact Lens. The Connect instance leaves all
  of these disabled.
- **SES is NOT managed by Terraform.** All SES resources (domain identity, DKIM,
  receipt rule set, receipt rule, active rule set, and the SES→Lambda invoke
  permission) are created **manually in the AWS Console** — see
  [05-setup-ses-evolvity.md](05-setup-ses-evolvity.md). Terraform builds only
  the things SES *points at* (the S3 inbound bucket + its SES-PutObject policy,
  and the Lambda). The SES receipt rule's Lambda action, when created in the
  console, adds the Lambda invoke permission automatically, so Terraform does
  not define an `aws_lambda_permission` for SES either.
- IAM: one role for the Lambda, one scoped statement per resource it touches —
  no wildcard `Resource = "*"` except where the AWS API genuinely requires it
  (e.g. `connect:StartTaskContact` is scoped to the instance ARN with a `/*`
  suffix, since tasks don't exist yet at grant time).
- Connect contact flows are raw JSON (via `jsonencode(...)` or a heredoc),
  referencing interpolated queue IDs.
- Every resource gets a consistent tag via the provider's `default_tags`, e.g.
  `{ Project = "ccaas-email-poc", ConnectInstance = var.instance_alias }`.
- `scripts/deploy.sh` wraps `terraform init/plan/apply` and prints outputs;
  `scripts/validate.sh` runs `terraform fmt -check` + `terraform validate`;
  `scripts/teardown.sh` runs `terraform destroy` (the retained inbound-email
  bucket is intentionally preserved — see module notes).

> **Operating rule:** the implementing agent writes Terraform and scripts but
> does **not** run `terraform apply`/`destroy` or any AWS CLI command. The user
> runs those (or grants permission for a specific command). See the global rules.

## Repo layout

```
<repo-root>/
├── main.tf                 # provider + module wiring
├── variables.tf            # all inputs
├── outputs.tf              # console URL, DKIM records, ARNs, table names
├── terraform.tfvars.example
├── modules/
│   ├── connect/            # instance, hours, queue, routing profile, task flow
│   │   ├── main.tf  variables.tf  outputs.tf
│   ├── email-storage/      # S3 inbound bucket (+policy), 2 DynamoDB tables
│   │   ├── main.tf  variables.tf  outputs.tf
│   ├── salesforce-secret/  # Secrets Manager secret (placeholder value)
│   │   ├── main.tf  variables.tf  outputs.tf
│   └── email-router/       # IAM role + Lambda (packaged from src/index.py)
│       ├── main.tf  variables.tf  outputs.tf
│       └── src/index.py
└── scripts/
# NOTE: no ses module — all SES setup is manual (console); see doc 05
    ├── deploy.sh
    ├── validate.sh
    └── teardown.sh
```

## Module list

| Module | AWS resources | Depends on (via inputs) |
|---|---|---|
| `connect` | `aws_connect_instance`, `aws_connect_hours_of_operation`, `aws_connect_queue`, `aws_connect_routing_profile`, `aws_connect_contact_flow` (TASK) | none |
| `email-storage` | `aws_s3_bucket` + `aws_s3_bucket_policy` (SES PutObject) + 2× `aws_dynamodb_table` | none |
| `salesforce-secret` | `aws_secretsmanager_secret` + `aws_secretsmanager_secret_version` (placeholder) | none |
| `email-router` | `aws_iam_role` (+ policy), `aws_lambda_function`, `archive_file` | connect, email-storage, salesforce-secret |

SES has **no module** — it is set up by hand in the console (doc 05).

**Ordering** is implicit from module input/output wiring: `connect`,
`email-storage`, `salesforce-secret` have no dependencies and build first;
`email-router` consumes their outputs. Terraform resolves the graph — no manual
sequencing needed.

There is no separate template-upload bucket or root orchestration wrapper to
manage. SES (identity, receipt rule, activation) is done manually after apply —
see [05-setup-ses-evolvity.md](05-setup-ses-evolvity.md).

---

## Module `connect`

Creates the Connect instance and everything routing-related. Cost-minimal: no
recording, no streaming, no Contact Lens.

### Instance
```hcl
resource "aws_connect_instance" "this" {
  identity_management_type = "CONNECT_MANAGED"
  instance_alias           = var.instance_alias

  inbound_calls_enabled    = true
  outbound_calls_enabled   = true
  contact_flow_logs_enabled = true

  # explicitly OFF for cost:
  contact_lens_enabled           = false
  auto_resolve_best_voices_enabled = false
  early_media_enabled            = false
  multi_party_conference_enabled = false
}
```
(`aws_connect_instance` exposes `id` and `arn`. Recording and Kinesis data
streaming are configured by separate resources — `aws_connect_instance_storage_config`
— which we deliberately **do not create**, so nothing is recorded or streamed.)

### Hours of operation — 24×7 UTC
```hcl
resource "aws_connect_hours_of_operation" "always_open" {
  instance_id = aws_connect_instance.this.id
  name        = "Always-Open"
  time_zone   = "UTC"

  dynamic "config" {
    for_each = ["MONDAY","TUESDAY","WEDNESDAY","THURSDAY","FRIDAY","SATURDAY","SUNDAY"]
    content {
      day        = config.value
      start_time { hours = 0  minutes = 0 }
      end_time   { hours = 23 minutes = 59 }
    }
  }
}
```

### Queue — Task channel only
```hcl
resource "aws_connect_queue" "email" {
  instance_id           = aws_connect_instance.this.id
  name                  = "Email-Case-Queue"
  description           = "Shared queue for Salesforce-case email Tasks — agents see ownerName/caseId attributes on each task"
  hours_of_operation_id = aws_connect_hours_of_operation.always_open.hours_of_operation_id
  max_contacts          = 25
}
```

### Routing profile — TASK concurrency 5
```hcl
resource "aws_connect_routing_profile" "email" {
  instance_id               = aws_connect_instance.this.id
  name                      = "Email-Routing-Profile"
  description               = "Routing profile for agents handling Salesforce-case email Tasks"
  default_outbound_queue_id = aws_connect_queue.email.queue_id

  media_concurrencies {
    channel     = "TASK"
    concurrency = 5
  }

  queue_configs {
    channel  = "TASK"
    delay    = 0
    priority = 1
    queue_id = aws_connect_queue.email.queue_id
  }
}
```
> After apply, manually create at least one Connect agent user and assign it
> this routing profile so there's someone to pick up Tasks during the demo (doc
> 03, step 4).

### Task contact flow
Deliberately thin: set the target queue and transfer the Task into it; error
branch disconnects.
```hcl
resource "aws_connect_contact_flow" "email_task" {
  instance_id = aws_connect_instance.this.id
  name        = "Email-Case-Routing"
  type        = "CONTACT_FLOW"          # Connect API type for a task flow; verify against provider docs
  description = "Routes Salesforce-case email Tasks into the Email-Case-Queue"

  content = jsonencode({
    Version     = "2019-10-30"
    StartAction = "t01"
    Actions = [
      {
        Identifier  = "t01"
        Type        = "UpdateContactTargetQueue"
        Parameters  = { QueueId = aws_connect_queue.email.queue_id }
        Transitions = { NextAction = "t02", Errors = [{ NextAction = "t_end", ErrorType = "NoMatchingError" }], Conditions = [] }
      },
      {
        Identifier  = "t02"
        Type        = "TransferContactToQueue"
        Parameters  = {}
        # Successful queue transfer ends the flow (no rendered "Success" output),
        # so point NextAction at the same single Disconnect as the errors — a
        # separate success-Disconnect renders as an orphan block in the console.
        Transitions = { NextAction = "t_end", Errors = [{ NextAction = "t_end", ErrorType = "NoMatchingError" }, { NextAction = "t_end", ErrorType = "QueueAtCapacity" }], Conditions = [] }
      },
      { Identifier = "t_end", Type = "DisconnectParticipant", Parameters = {}, Transitions = {} }
    ]
  })
}
```
> Connect's flow-language JSON schema shifts occasionally, and the provider's
> accepted `type` value for a task flow should be confirmed. Before trusting the
> hand-written blob: draw an equivalent flow in the Connect console, export its
> JSON, and diff. `aws_connect_contact_flow` also supports `filename` if you'd
> rather keep the flow JSON as a separate file.

**Module outputs:** `instance_id`, `instance_arn`, `queue_id`, `queue_arn`,
`routing_profile_id`, `contact_flow_id`, `contact_flow_arn`.

---

## Module `email-storage`

### S3 inbound-email bucket + SES PutObject policy
```hcl
resource "aws_s3_bucket" "inbound" {
  bucket = "${var.instance_alias}-inbound-email-${data.aws_caller_identity.current.account_id}"

  lifecycle { prevent_destroy = true }   # raw email survives teardown for audit
}

resource "aws_s3_bucket_policy" "inbound" {
  bucket = aws_s3_bucket.inbound.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowSESPuts"
      Effect    = "Allow"
      Principal = { Service = "ses.amazonaws.com" }
      Action    = "s3:PutObject"
      Resource  = "${aws_s3_bucket.inbound.arn}/*"
      Condition = { StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id } }
    }]
  })
}
```
> `prevent_destroy = true` makes `terraform destroy` refuse to delete this
> bucket, preserving the raw-email audit trail. To fully tear down later, empty
> the bucket and remove the `prevent_destroy` block (or `terraform state rm`).

### DynamoDB — `MailboxOwnership` (current state, upserted)
```hcl
resource "aws_dynamodb_table" "mailbox_ownership" {
  name         = "${var.instance_alias}-mailbox-ownership"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "mailbox"        # e.g. ordersuccess@ccaas.evolvity.com
  range_key    = "customerEmail"  # the external customer's address

  attribute { name = "mailbox"       type = "S" }
  attribute { name = "customerEmail" type = "S" }
}
```
Non-key attributes written by the Lambda (schemaless, no definitions needed):
`ownerId`, `ownerName`, `caseId`, `lastUpdated`.

### DynamoDB — `EmailRoutingLog` (append-only audit trail)
```hcl
resource "aws_dynamodb_table" "email_routing_log" {
  name         = "${var.instance_alias}-email-routing-log"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "emailId"    # SES messageId
  range_key    = "timestamp"  # ISO8601

  attribute { name = "emailId"   type = "S" }
  attribute { name = "timestamp" type = "S" }
}
```
Non-key attributes written: `mailbox`, `fromAddress`, `subject`, `caseId`,
`resolvedOwnerId`, `resolvedOwnerName`, `isSharedMailbox`, `contactId`,
`routingOutcome` (`resolved` / `fallback` / `unassigned`).

Both tables are POC data with no `prevent_destroy` — `terraform destroy` removes
them.

**Module outputs:** `bucket_name`, `bucket_arn`, `ownership_table_name`,
`ownership_table_arn`, `routing_log_table_name`, `routing_log_table_arn`.

---

## Module `salesforce-secret`

```hcl
resource "aws_secretsmanager_secret" "salesforce" {
  name        = "${var.instance_alias}-salesforce-credentials"
  description = "Salesforce Connected App credentials for the email router Lambda — populate via CLI after apply, never store real values in code"
}

resource "aws_secretsmanager_secret_version" "salesforce" {
  secret_id     = aws_secretsmanager_secret.salesforce.id
  secret_string = jsonencode({
    client_id     = "REPLACE_ME"
    client_secret = "REPLACE_ME"
    login_url     = var.salesforce_login_url
  })

  # the real value is set out-of-band via `aws secretsmanager put-secret-value`;
  # don't let Terraform revert it on every apply:
  lifecycle { ignore_changes = [secret_string] }
}
```
Placeholder only, so the secret has valid initial state. Real values are set
post-apply via `aws secretsmanager put-secret-value` (doc 03). Never commit real
credentials. `ignore_changes` keeps Terraform from clobbering the real value the
user sets.

**Module outputs:** `secret_arn`, `secret_name`.

---

## Module `email-router`

### Package the Lambda
```hcl
data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/src/index.py"
  output_path = "${path.module}/build/index.zip"
}
```

### IAM role — one scoped statement per resource
```hcl
resource "aws_iam_role" "lambda" {
  name = "${var.lambda_function_name}-execution-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "access" {
  name = "EmailRoutingAccess"
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "ReadRawEmail",          Effect = "Allow", Action = "s3:GetObject",              Resource = "${var.inbound_bucket_arn}/*" },
      { Sid = "OwnershipTableRW",      Effect = "Allow", Action = ["dynamodb:GetItem","dynamodb:PutItem","dynamodb:UpdateItem","dynamodb:Query"], Resource = var.ownership_table_arn },
      { Sid = "RoutingLogWrite",       Effect = "Allow", Action = ["dynamodb:PutItem"],        Resource = var.routing_log_table_arn },
      { Sid = "SalesforceSecretRead",  Effect = "Allow", Action = "secretsmanager:GetSecretValue", Resource = var.salesforce_secret_arn },
      { Sid = "StartConnectTask",      Effect = "Allow", Action = "connect:StartTaskContact",  Resource = "${var.connect_instance_arn}/*" }
    ]
  })
}
```

### Lambda function
```hcl
resource "aws_lambda_function" "router" {
  function_name    = var.lambda_function_name
  runtime          = "python3.12"
  handler          = "index.handler"
  role             = aws_iam_role.lambda.arn
  timeout          = 30
  memory_size      = 256
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256

  environment {
    variables = {
      INBOUND_BUCKET      = var.inbound_bucket_name
      OWNERSHIP_TABLE     = var.ownership_table_name
      ROUTING_LOG_TABLE   = var.routing_log_table_name
      SF_SECRET_ARN       = var.salesforce_secret_arn
      CONNECT_INSTANCE_ID = var.connect_instance_id
      TASK_FLOW_ARN       = var.contact_flow_arn
      SHARED_MAILBOXES    = var.shared_mailboxes      # comma-separated
      CASE_ID_REGEX       = var.case_id_regex
    }
  }
}
```

### Handler — `modules/email-router/src/index.py` (implement fully)
This is the spec; write it out completely in the source file.
```python
import boto3, json, logging, os, re, time, urllib.request, urllib.parse
from datetime import datetime, timezone

logger = logging.getLogger(); logger.setLevel(logging.INFO)
ddb = boto3.resource("dynamodb")
secrets = boto3.client("secretsmanager")
connect = boto3.client("connect")

OWNERSHIP_TABLE = ddb.Table(os.environ["OWNERSHIP_TABLE"])
LOG_TABLE       = ddb.Table(os.environ["ROUTING_LOG_TABLE"])
CASE_RE         = re.compile(os.environ["CASE_ID_REGEX"], re.IGNORECASE)
SHARED_MAILBOXES = set(a.strip().lower() for a in os.environ["SHARED_MAILBOXES"].split(",") if a.strip())

_sf_token_cache = {}  # {"access_token":..., "instance_url":..., "expires_at": epoch}

def handler(event, context):
    for record in event["Records"]:
        mail       = record["ses"]["mail"]
        message_id = mail["messageId"]
        subject    = mail["commonHeaders"].get("subject", "")
        from_addr  = mail["commonHeaders"].get("from", [""])[0]
        to_addrs   = mail["commonHeaders"].get("to", [])
        mailbox    = next((a.lower() for a in to_addrs if a.lower() in SHARED_MAILBOXES),
                          (to_addrs[0].lower() if to_addrs else ""))

        m = CASE_RE.search(subject)
        case_number = m.group(1) if m else None

        if case_number:
            owner_id, owner_name = _lookup_salesforce_case_owner(case_number)
            outcome = "resolved" if owner_id else "unassigned"
            if owner_id:
                _upsert_ownership(mailbox, from_addr, owner_id, owner_name, case_number)
        else:
            owner_id, owner_name = _lookup_ownership_fallback(mailbox, from_addr)
            outcome = "fallback" if owner_id else "unassigned"

        contact_id = _start_connect_task(subject, mailbox, from_addr, case_number,
                                         owner_id, owner_name, mailbox in SHARED_MAILBOXES)
        _write_audit_log(message_id, mailbox, from_addr, subject, case_number,
                         owner_id, owner_name, mailbox in SHARED_MAILBOXES, contact_id, outcome)
    return {"status": "ok"}

def _get_salesforce_token():
    now = time.time()
    if _sf_token_cache.get("expires_at", 0) > now + 30:
        return _sf_token_cache["access_token"], _sf_token_cache["instance_url"]
    creds = json.loads(secrets.get_secret_value(SecretId=os.environ["SF_SECRET_ARN"])["SecretString"])
    data = urllib.parse.urlencode({
        "grant_type": "client_credentials",
        "client_id": creds["client_id"], "client_secret": creds["client_secret"],
    }).encode()
    req = urllib.request.Request(creds["login_url"].rstrip("/") + "/services/oauth2/token", data=data)
    with urllib.request.urlopen(req, timeout=10) as r:
        tok = json.loads(r.read())
    _sf_token_cache.update(access_token=tok["access_token"], instance_url=tok["instance_url"],
                           expires_at=now + 3300)  # ~55 min
    return tok["access_token"], tok["instance_url"]

def _lookup_salesforce_case_owner(case_number):
    try:
        token, instance_url = _get_salesforce_token()
        soql = f"SELECT Id, CaseNumber, OwnerId, Owner.Name FROM Case WHERE CaseNumber = '{case_number}'"
        url = f"{instance_url}/services/data/v60.0/query?q=" + urllib.parse.quote(soql)
        req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
        with urllib.request.urlopen(req, timeout=10) as r:
            recs = json.loads(r.read()).get("records", [])
        if not recs:
            return None, None
        rec = recs[0]
        return rec["OwnerId"], (rec.get("Owner") or {}).get("Name")
    except Exception:
        logger.exception("Salesforce lookup failed for case %s", case_number)
        return None, None

def _upsert_ownership(mailbox, customer_email, owner_id, owner_name, case_number):
    OWNERSHIP_TABLE.put_item(Item={
        "mailbox": mailbox, "customerEmail": customer_email.lower(),
        "ownerId": owner_id, "ownerName": owner_name, "caseId": case_number,
        "lastUpdated": _now_iso(),
    })

def _lookup_ownership_fallback(mailbox, customer_email):
    item = OWNERSHIP_TABLE.get_item(Key={"mailbox": mailbox, "customerEmail": customer_email.lower()}).get("Item")
    return (item["ownerId"], item["ownerName"]) if item else (None, None)

def _start_connect_task(subject, mailbox, from_addr, case_number, owner_id, owner_name, is_shared):
    resp = connect.start_task_contact(
        InstanceId=os.environ["CONNECT_INSTANCE_ID"],
        ContactFlowId=os.environ["TASK_FLOW_ARN"],
        Name=f"Email: {subject[:50]}",
        Description=f"From {from_addr} to {mailbox}",
        Attributes={
            "caseId": case_number or "", "ownerId": owner_id or "UNASSIGNED",
            "ownerName": owner_name or "Unassigned", "mailbox": mailbox,
            "fromAddress": from_addr, "isSharedMailbox": "true" if is_shared else "false",
        },
    )
    return resp["ContactId"]

def _write_audit_log(email_id, mailbox, from_addr, subject, case_number,
                     owner_id, owner_name, is_shared, contact_id, outcome):
    LOG_TABLE.put_item(Item={
        "emailId": email_id, "timestamp": _now_iso(), "mailbox": mailbox,
        "fromAddress": from_addr, "subject": subject, "caseId": case_number or "",
        "resolvedOwnerId": owner_id or "UNASSIGNED", "resolvedOwnerName": owner_name or "Unassigned",
        "isSharedMailbox": is_shared, "contactId": contact_id, "routingOutcome": outcome,
    })

def _now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
```

Notes for whoever implements this:
- The SES→Lambda event (`event["Records"][0]["ses"]["mail"]`) already includes
  `commonHeaders` (subject/from/to parsed) — fetching/parsing raw MIME from S3
  is only needed for the email **body** (a future "show preview to agent"
  feature), out of scope here.
- Salesforce API version `v60.0` — confirm what's current in the target dev org
  and pin it.
- The module-level `_sf_token_cache` reuses the OAuth token across warm
  invocations to avoid a round-trip per email.
- `ContactFlowId` accepts the flow ARN passed via `TASK_FLOW_ARN`.

**Module outputs:** `lambda_arn`, `lambda_name`, `role_arn`.

---

## SES — manual, no Terraform

There is intentionally **no `ses-routing` module**. Every SES resource is created
by hand in the AWS Console, fully documented in
[05-setup-ses-evolvity.md](05-setup-ses-evolvity.md):

- **Phase A (before the build):** create the `ccaas.evolvity.com` domain identity
  with Easy DKIM, add the 3 DKIM CNAME records + the MX record at the DNS host,
  wait for verification.
- **Phase B (after `terraform apply`):** create the receipt rule set + rule
  pointing its S3 action at the Terraform-created `inbound_bucket` (prefix
  `inbound/`) and its Lambda action at the router Lambda (invocation type
  `Event`); when the console asks to allow SES to invoke the Lambda, accept it
  (this adds the resource-based permission automatically); then set the rule set
  active.

What Terraform **does** provide for SES to use: the S3 inbound bucket and its
SES-PutObject bucket policy (module `email-storage`), and the router Lambda
(module `email-router`). Terraform defines **no** `aws_ses_*` resources and
**no** `aws_lambda_permission` for SES.

---

## Root `main.tf`, `variables.tf`, `outputs.tf`

### `variables.tf`
```hcl
variable "region"           { type = string  default = "us-west-2" }
variable "instance_alias"   { type = string  default = "ccaas-email-poc" }   # ^[a-z0-9-]{1,45}$
variable "ses_domain"       { type = string  default = "ccaas.evolvity.com" }
variable "shared_mailboxes" { type = string  default = "ordersuccess@ccaas.evolvity.com" }  # comma-separated
variable "salesforce_login_url" { type = string default = "https://login.salesforce.com" }
variable "case_id_regex"    { type = string  default = "Case\\s*#?(\\d{5,10})" }
variable "lambda_function_name" { type = string default = "email-case-router-lambda" }
```

### `main.tf` (wiring sketch)
```hcl
terraform {
  required_version = ">= 1.6"
  required_providers { aws = { source = "hashicorp/aws", version = ">= 5.0" } }
}

provider "aws" {
  region = var.region
  default_tags { tags = { Project = "ccaas-email-poc", ConnectInstance = var.instance_alias } }
}

data "aws_caller_identity" "current" {}

module "connect"           { source = "./modules/connect"           instance_alias = var.instance_alias }
module "email_storage"     { source = "./modules/email-storage"     instance_alias = var.instance_alias }
module "salesforce_secret" { source = "./modules/salesforce-secret" instance_alias = var.instance_alias  salesforce_login_url = var.salesforce_login_url }

module "email_router" {
  source                 = "./modules/email-router"
  lambda_function_name   = var.lambda_function_name
  instance_alias         = var.instance_alias
  inbound_bucket_name    = module.email_storage.bucket_name
  inbound_bucket_arn     = module.email_storage.bucket_arn
  ownership_table_name   = module.email_storage.ownership_table_name
  ownership_table_arn    = module.email_storage.ownership_table_arn
  routing_log_table_name = module.email_storage.routing_log_table_name
  routing_log_table_arn  = module.email_storage.routing_log_table_arn
  salesforce_secret_arn  = module.salesforce_secret.secret_arn
  connect_instance_id    = module.connect.instance_id
  connect_instance_arn   = module.connect.instance_arn
  contact_flow_arn       = module.connect.contact_flow_arn
  shared_mailboxes       = var.shared_mailboxes
  case_id_regex          = var.case_id_regex
}

# No SES module — SES is set up manually in the console (doc 05).
```
(Each module passes `data.aws_caller_identity` where it needs the account id, or
receives it as an input — pick one convention and keep it consistent.)

### `outputs.tf` (root)
Surface everything the user needs, especially the DNS records:
```hcl
output "connect_console_url" { value = "https://${var.instance_alias}.my.connect.aws" }
output "connect_instance_arn"{ value = module.connect.instance_arn }
output "email_queue_arn"     { value = module.connect.queue_arn }
output "contact_flow_arn"    { value = module.connect.contact_flow_arn }
output "inbound_bucket"      { value = module.email_storage.bucket_name }
output "ownership_table"     { value = module.email_storage.ownership_table_name }
output "routing_log_table"   { value = module.email_storage.routing_log_table_name }
output "salesforce_secret_name" { value = module.salesforce_secret.secret_name }
output "email_router_lambda_arn" { value = module.email_router.lambda_arn }

# SES is manual (doc 05); the DKIM records come from the SES console, not
# Terraform. The only fixed piece worth surfacing as a reminder is the MX value:
output "ses_mx_reminder" {
  value = "Add MX for ${var.ses_domain}: 10 inbound-smtp.${var.region}.amazonaws.com (see doc 05)"
}
```

## `scripts/`

- **`deploy.sh`** — pre-flight `aws sts get-caller-identity` check → `terraform
  init` → `terraform apply` → print outputs (incl. `inbound_bucket` and
  `email_router_lambda_arn`, which the user needs for the manual SES Phase B in
  doc 05). A short CONFIG section at the top (region, instance alias, ses_domain,
  shared_mailboxes) writes a `terraform.tfvars` if absent. **The script does not
  run itself as part of implementation — the user runs it.** SES setup is not
  part of this script; it's the manual console flow in doc 05.
- **`validate.sh`** — `terraform fmt -recursive -check` + `terraform validate`.
  (Add `tflint` if available.) Safe to run without AWS creds after
  `terraform init`.
- **`teardown.sh`** — `terraform destroy`. The inbound-email bucket has
  `prevent_destroy = true`, so destroy stops there by design; the script prints
  the manual steps to remove it if the user really wants to (empty bucket, drop
  the lifecycle block, destroy again).

---
See [03-prerequisites-and-setup.md](03-prerequisites-and-setup.md) for external
(non-Terraform) setup, [05-setup-ses-evolvity.md](05-setup-ses-evolvity.md) and
[06-setup-salesforce-dev-org.md](06-setup-salesforce-dev-org.md) for the SES and
Salesforce walkthroughs, and [04-verification-plan.md](04-verification-plan.md)
for the end-to-end test checklist.
