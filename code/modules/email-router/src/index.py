"""Email case router Lambda.

Triggered by an SES receipt-rule Lambda action for mail delivered to the shared
mailbox(es). For each message:

  1. Parse the subject for a Salesforce Case Number.
  2. If found  -> look up the Case Owner live in Salesforce (Client Credentials
                  OAuth) and upsert the ownership record.
     If absent -> fall back to the last-known owner for (mailbox, customer) in
                  DynamoDB (shared-mailbox ownership continuity).
  3. Start an Amazon Connect Task carrying caseId/owner attributes, a decoded
     body preview, and a (presigned) link to the raw email in S3.
  4. Write an append-only audit-log row.

SES's event includes parsed commonHeaders (subject/from/to) used for routing.
The full body/thread is read from the raw MIME object SES stored in S3 (best
effort) to give the agent a preview + a link.
"""

import boto3
import email
import json
from botocore.config import Config
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
# SigV4 is required to presign GETs for KMS-SSE objects (SigV2 is rejected).
s3 = boto3.client("s3", config=Config(signature_version="s3v4"))

OWNERSHIP_TABLE = ddb.Table(os.environ["OWNERSHIP_TABLE"])
LOG_TABLE = ddb.Table(os.environ["ROUTING_LOG_TABLE"])
CASE_RE = re.compile(os.environ["CASE_ID_REGEX"], re.IGNORECASE)
SHARED_MAILBOXES = set(
    a.strip().lower() for a in os.environ["SHARED_MAILBOXES"].split(",") if a.strip()
)
SF_API_VERSION = os.environ.get("SF_API_VERSION", "v60.0")
# {salesforceOwnerId: contactFlowArn} — routes each Task to that owner's agent.
OWNER_FLOW_MAP = json.loads(os.environ.get("OWNER_FLOW_MAP", "{}"))
# When an email has no Case # and no prior owner, create a Salesforce Case.
AUTO_CREATE_CASE = os.environ.get("AUTO_CREATE_CASE", "true").lower() == "true"

INBOUND_BUCKET = os.environ.get("INBOUND_BUCKET", "")
INBOUND_PREFIX = os.environ.get("INBOUND_PREFIX", "inbound/")
RENDERED_PREFIX = os.environ.get("RENDERED_PREFIX", "rendered/")
BODY_PREVIEW_CHARS = int(os.environ.get("BODY_PREVIEW_CHARS", "2000"))
RAW_EMAIL_URL_TTL = int(os.environ.get("RAW_EMAIL_URL_TTL", "43200"))  # 12h

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
            # Scenario 1: subject carries a Case # → live owner lookup.
            owner_id, owner_name = _lookup_salesforce_case_owner(case_number)
            outcome = "resolved" if owner_id else "unassigned"
            if owner_id:
                _upsert_ownership(mailbox, from_addr, owner_id, owner_name, case_number)
        else:
            # Scenario 2: no Case # → remembered owner for this customer.
            owner_id, owner_name = _lookup_ownership_fallback(mailbox, from_addr)
            if owner_id:
                outcome = "fallback"
            elif AUTO_CREATE_CASE:
                # New inquiry: no case and no history → create a Salesforce Case,
                # then route to its owner (Email-to-Case style).
                case_number, owner_id, owner_name = _create_salesforce_case(subject, from_addr)
                outcome = "created" if case_number else "unassigned"
                if owner_id:
                    _upsert_ownership(mailbox, from_addr, owner_id, owner_name, case_number)
            else:
                outcome = "unassigned"

        is_shared = mailbox in SHARED_MAILBOXES
        body_preview, raw_url = _fetch_body_and_link(message_id)
        contact_id = _start_connect_task(
            subject, mailbox, from_addr, case_number, owner_id, owner_name,
            is_shared, body_preview, raw_url,
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


def _create_salesforce_case(subject, from_addr):
    """Create a new Salesforce Case for a new inquiry, then return
    (caseNumber, ownerId, ownerName). Best-effort — returns Nones on failure."""
    try:
        token, instance_url = _get_salesforce_token()
        payload = json.dumps({
            "Subject": subject or "(no subject)",
            "Description": f"Auto-created from email to shared mailbox. From: {from_addr}",
            "SuppliedEmail": from_addr,
            "Origin": "Email",
        }).encode()
        req = urllib.request.Request(
            f"{instance_url}/services/data/{SF_API_VERSION}/sobjects/Case",
            data=payload,
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
            },
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=10) as r:
            new_id = json.loads(r.read())["id"]
        # Fetch the new case's number + owner (owner defaults to the run-as user
        # unless Salesforce assignment rules are configured).
        soql = f"SELECT CaseNumber, OwnerId, Owner.Name FROM Case WHERE Id = '{new_id}'"
        url = f"{instance_url}/services/data/{SF_API_VERSION}/query?q=" + urllib.parse.quote(soql)
        req2 = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
        with urllib.request.urlopen(req2, timeout=10) as r:
            recs = json.loads(r.read()).get("records", [])
        if not recs:
            return None, None, None
        rec = recs[0]
        return rec.get("CaseNumber"), rec.get("OwnerId"), (rec.get("Owner") or {}).get("Name")
    except Exception:
        logger.exception("Salesforce case creation failed")
        return None, None, None


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
    subject, mailbox, from_addr, case_number, owner_id, owner_name, is_shared,
    body_preview="", raw_url=None,
):
    # Route to the owner's dedicated flow (-> owner's queue/agent); if the owner
    # isn't mapped (or is unassigned), fall back to the shared flow/queue.
    flow_arn = OWNER_FLOW_MAP.get(owner_id or "", os.environ["TASK_FLOW_ARN"])

    attributes = {
        "caseId": case_number or "",
        "ownerId": owner_id or "UNASSIGNED",
        "ownerName": owner_name or "Unassigned",
        "mailbox": mailbox,
        "fromAddress": from_addr,
        "isSharedMailbox": "true" if is_shared else "false",
    }
    if body_preview:
        attributes["bodyPreview"] = body_preview

    kwargs = dict(
        InstanceId=os.environ["CONNECT_INSTANCE_ID"],
        ContactFlowId=flow_arn,
        Name=f"Email: {subject[:50]}",
        Description=f"From {from_addr} to {mailbox}",
        Attributes=attributes,
    )
    # A clickable link to a browser-renderable view of the email in the Task.
    if raw_url:
        kwargs["References"] = {
            "Email": {"Value": raw_url, "Type": "URL"}
        }

    resp = connect.start_task_contact(**kwargs)
    return resp["ContactId"]


def _fetch_body_and_link(message_id):
    """Read the raw MIME from S3; return (decoded text preview, presigned URL to a
    browser-renderable HTML view we write to S3). The raw .eml isn't readable in a
    browser, so we render the HTML (or wrap the text) into its own object and link
    to that. Best-effort — never fails the routing."""
    if not INBOUND_BUCKET:
        return "", None
    key = INBOUND_PREFIX + message_id
    try:
        raw = s3.get_object(Bucket=INBOUND_BUCKET, Key=key)["Body"].read()
        msg = email.message_from_bytes(raw)
        plain, html = _extract_bodies(msg)
        preview = (plain or _strip_tags(html) or "").strip()[:BODY_PREVIEW_CHARS]

        view_html = _render_email_html(msg, html, plain)
        view_key = RENDERED_PREFIX + message_id + ".html"
        s3.put_object(
            Bucket=INBOUND_BUCKET,
            Key=view_key,
            Body=view_html.encode("utf-8"),
            ContentType="text/html; charset=utf-8",
        )
        url = s3.generate_presigned_url(
            "get_object",
            Params={"Bucket": INBOUND_BUCKET, "Key": view_key},
            ExpiresIn=RAW_EMAIL_URL_TTL,
        )
        return preview, url
    except Exception:
        logger.exception("Could not fetch/parse body for %s", message_id)
        return "", None


def _render_email_html(msg, html, plain):
    """Wrap the email body with a From/To/Date/Subject header block so the
    rendered view reads like a real email."""
    rows = "".join(
        f"<div><b>{label}:</b> {_html_escape(msg.get(name, '') or '')}</div>"
        for label, name in (("From", "From"), ("To", "To"), ("Date", "Date"), ("Subject", "Subject"))
    )
    header = (
        "<div style=\"font-family:Arial,Helvetica,sans-serif;font-size:14px;"
        "background:#f4f6f8;border:1px solid #d8dde3;border-radius:6px;"
        "padding:12px 16px;margin-bottom:16px;color:#16325c\">" + rows + "</div>"
    )
    body = html or (
        "<pre style=\"white-space:pre-wrap;font-family:Arial,Helvetica,sans-serif\">"
        + _html_escape(plain or "(no text body)")
        + "</pre>"
    )
    return (
        "<div style=\"max-width:820px;margin:16px auto;padding:0 8px\">"
        + header + body + "</div>"
    )


def _extract_bodies(msg):
    """Return (text/plain, text/html) body strings (either may be None)."""
    plain, html = None, None
    for part in msg.walk() if msg.is_multipart() else [msg]:
        ctype = part.get_content_type()
        if ctype == "text/plain" and plain is None:
            plain = _decode_part(part)
        elif ctype == "text/html" and html is None:
            html = _decode_part(part)
    return plain, html


def _strip_tags(html):
    return re.sub(r"<[^>]+>", " ", html) if html else ""


def _html_escape(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def _decode_part(part):
    try:
        payload = part.get_payload(decode=True) or b""
        return payload.decode(part.get_content_charset() or "utf-8", "replace")
    except Exception:
        return ""


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
