"""Email case router Lambda.

Triggered by an SES receipt-rule Lambda action for mail delivered to the shared
mailbox(es). For each message:

  1. Parse the subject for a Salesforce Case Number.
  2. If found  -> look up the Case Owner live in Salesforce (Client Credentials
                  OAuth) and upsert the ownership record.
     If absent -> fall back to the last-known owner for (mailbox, customer) in
                  DynamoDB (shared-mailbox ownership continuity).
  3. Start an Amazon Connect Task carrying caseId/owner attributes.
  4. Write an append-only audit-log row.

SES's event already includes parsed commonHeaders (subject/from/to), so we don't
need to fetch raw MIME from S3 for routing. Reading the S3 object would only be
needed for the email body (a future "show preview to agent" feature).
"""

import boto3
import json
import logging
import os
import re
import time
import urllib.request
import urllib.parse
from datetime import datetime, timezone
from email.utils import parseaddr, getaddresses

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ddb = boto3.resource("dynamodb")
secrets = boto3.client("secretsmanager")
connect = boto3.client("connect")

OWNERSHIP_TABLE = ddb.Table(os.environ["OWNERSHIP_TABLE"])
LOG_TABLE = ddb.Table(os.environ["ROUTING_LOG_TABLE"])
CASE_RE = re.compile(os.environ["CASE_ID_REGEX"], re.IGNORECASE)
SHARED_MAILBOXES = set(
    a.strip().lower() for a in os.environ["SHARED_MAILBOXES"].split(",") if a.strip()
)
SF_API_VERSION = os.environ.get("SF_API_VERSION", "v60.0")
# {salesforceOwnerId: contactFlowArn} — routes each Task to that owner's agent.
OWNER_FLOW_MAP = json.loads(os.environ.get("OWNER_FLOW_MAP", "{}"))

# reused across warm invocations to avoid an OAuth round-trip per email
_sf_token_cache = {}  # {"access_token":..., "instance_url":..., "expires_at": epoch}


def handler(event, context):
    for record in event["Records"]:
        mail = record["ses"]["mail"]
        message_id = mail["messageId"]
        subject = mail["commonHeaders"].get("subject", "")
        # Normalize to the bare local@domain — headers may arrive as
        # "Display Name <addr>", which must not pollute keys or defeat the
        # shared-mailbox match.
        from_addr = parseaddr(mail["commonHeaders"].get("from", [""])[0])[1].lower()
        to_emails = [
            addr.lower()
            for _, addr in getaddresses(mail["commonHeaders"].get("to", []))
            if addr
        ]
        mailbox = next(
            (a for a in to_emails if a in SHARED_MAILBOXES),
            (to_emails[0] if to_emails else ""),
        )

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

        is_shared = mailbox in SHARED_MAILBOXES
        contact_id = _start_connect_task(
            subject, mailbox, from_addr, case_number, owner_id, owner_name, is_shared
        )
        _write_audit_log(
            message_id, mailbox, from_addr, subject, case_number,
            owner_id, owner_name, is_shared, contact_id, outcome,
        )
        logger.info(
            "routed messageId=%s case=%s owner=%s outcome=%s contact=%s",
            message_id, case_number, owner_name, outcome, contact_id,
        )
    return {"status": "ok"}


def _get_salesforce_token():
    now = time.time()
    if _sf_token_cache.get("expires_at", 0) > now + 30:
        return _sf_token_cache["access_token"], _sf_token_cache["instance_url"]
    creds = json.loads(
        secrets.get_secret_value(SecretId=os.environ["SF_SECRET_ARN"])["SecretString"]
    )
    data = urllib.parse.urlencode(
        {
            "grant_type": "client_credentials",
            "client_id": creds["client_id"],
            "client_secret": creds["client_secret"],
        }
    ).encode()
    req = urllib.request.Request(
        creds["login_url"].rstrip("/") + "/services/oauth2/token", data=data
    )
    with urllib.request.urlopen(req, timeout=10) as r:
        tok = json.loads(r.read())
    _sf_token_cache.update(
        access_token=tok["access_token"],
        instance_url=tok["instance_url"],
        expires_at=now + 3300,  # ~55 min
    )
    return tok["access_token"], tok["instance_url"]


def _lookup_salesforce_case_owner(case_number):
    try:
        token, instance_url = _get_salesforce_token()
        soql = (
            "SELECT Id, CaseNumber, OwnerId, Owner.Name FROM Case "
            f"WHERE CaseNumber = '{case_number}'"
        )
        url = (
            f"{instance_url}/services/data/{SF_API_VERSION}/query?q="
            + urllib.parse.quote(soql)
        )
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
    OWNERSHIP_TABLE.put_item(
        Item={
            "mailbox": mailbox,
            "customerEmail": customer_email.lower(),
            "ownerId": owner_id,
            "ownerName": owner_name,
            "caseId": case_number,
            "lastUpdated": _now_iso(),
        }
    )


def _lookup_ownership_fallback(mailbox, customer_email):
    item = OWNERSHIP_TABLE.get_item(
        Key={"mailbox": mailbox, "customerEmail": customer_email.lower()}
    ).get("Item")
    return (item["ownerId"], item["ownerName"]) if item else (None, None)


def _start_connect_task(
    subject, mailbox, from_addr, case_number, owner_id, owner_name, is_shared
):
    # Route to the owner's dedicated flow (-> owner's queue/agent); if the owner
    # isn't mapped (or is unassigned), fall back to the shared flow/queue.
    flow_arn = OWNER_FLOW_MAP.get(owner_id or "", os.environ["TASK_FLOW_ARN"])
    resp = connect.start_task_contact(
        InstanceId=os.environ["CONNECT_INSTANCE_ID"],
        ContactFlowId=flow_arn,
        Name=f"Email: {subject[:50]}",
        Description=f"From {from_addr} to {mailbox}",
        Attributes={
            "caseId": case_number or "",
            "ownerId": owner_id or "UNASSIGNED",
            "ownerName": owner_name or "Unassigned",
            "mailbox": mailbox,
            "fromAddress": from_addr,
            "isSharedMailbox": "true" if is_shared else "false",
        },
    )
    return resp["ContactId"]


def _write_audit_log(
    email_id, mailbox, from_addr, subject, case_number,
    owner_id, owner_name, is_shared, contact_id, outcome,
):
    LOG_TABLE.put_item(
        Item={
            "emailId": email_id,
            "timestamp": _now_iso(),
            "mailbox": mailbox,
            "fromAddress": from_addr,
            "subject": subject,
            "caseId": case_number or "",
            "resolvedOwnerId": owner_id or "UNASSIGNED",
            "resolvedOwnerName": owner_name or "Unassigned",
            "isSharedMailbox": is_shared,
            "contactId": contact_id,
            "routingOutcome": outcome,
        }
    )


def _now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
