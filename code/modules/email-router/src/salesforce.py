"""Salesforce REST integration: OAuth (Client Credentials), case owner lookup,
case creation, contact/account resolution, and logging emails onto cases.

All functions are best-effort — they log and return Nones on failure so a
Salesforce hiccup never breaks routing.
"""

import json
import time
import urllib.parse
import urllib.request

from config import logger, secrets, now_iso, SF_API_VERSION, SF_SECRET_ARN

# reused across warm invocations to avoid an OAuth round-trip per email
_token_cache = {}  # {"access_token":..., "instance_url":..., "expires_at": epoch}


def get_token():
    now = time.time()
    if _token_cache.get("expires_at", 0) > now + 30:
        return _token_cache["access_token"], _token_cache["instance_url"]
    creds = json.loads(secrets.get_secret_value(SecretId=SF_SECRET_ARN)["SecretString"])
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
    _token_cache.update(
        access_token=tok["access_token"],
        instance_url=tok["instance_url"],
        expires_at=now + 3300,  # ~55 min
    )
    return tok["access_token"], tok["instance_url"]


# ---- small REST helpers ----

def _soql_escape(value):
    return (value or "").replace("\\", "\\\\").replace("'", "\\'")


def _query(instance_url, token, soql):
    url = f"{instance_url}/services/data/{SF_API_VERSION}/query?q=" + urllib.parse.quote(soql)
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read()).get("records", [])


def _insert(instance_url, token, sobject, body):
    req = urllib.request.Request(
        f"{instance_url}/services/data/{SF_API_VERSION}/sobjects/{sobject}",
        data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read())["id"]


def _update(instance_url, token, sobject, record_id, body):
    req = urllib.request.Request(
        f"{instance_url}/services/data/{SF_API_VERSION}/sobjects/{sobject}/{record_id}",
        data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        method="PATCH",
    )
    with urllib.request.urlopen(req, timeout=10) as r:
        r.read()  # 204 No Content


def _split_name(display, from_addr):
    """Best-effort (FirstName, LastName) from a display name, else the email."""
    display = (display or "").strip()
    if display:
        parts = display.split()
        if len(parts) >= 2:
            return parts[0], " ".join(parts[1:])
        return "", parts[0]
    local = from_addr.split("@")[0] if "@" in from_addr else from_addr
    return "", local or "Unknown"


# ---- public API ----

def resolve_contact_account(from_addr, from_display):
    """Find-or-create a Contact (by email) + Account (by email domain) so cases
    link to a customer 360. Returns (contactId, accountId)."""
    try:
        token, instance_url = get_token()
        found = _query(
            instance_url, token,
            f"SELECT Id, AccountId FROM Contact WHERE Email = '{_soql_escape(from_addr)}' LIMIT 1",
        )
        if found:
            return found[0]["Id"], found[0].get("AccountId")

        domain = from_addr.split("@")[-1] if "@" in from_addr else ""
        account_id = None
        if domain:
            acc = _query(instance_url, token, f"SELECT Id FROM Account WHERE Name = '{_soql_escape(domain)}' LIMIT 1")
            account_id = acc[0]["Id"] if acc else _insert(instance_url, token, "Account", {"Name": domain})

        first, last = _split_name(from_display, from_addr)
        contact_body = {"LastName": last, "Email": from_addr}
        if first:
            contact_body["FirstName"] = first
        if account_id:
            contact_body["AccountId"] = account_id
        contact_id = _insert(instance_url, token, "Contact", contact_body)
        return contact_id, account_id
    except Exception:
        logger.exception("Could not resolve contact/account for %s", from_addr)
        return None, None


def case_url(sf_case_id):
    """Lightning record URL for the agent to open the Case's 360. Best-effort."""
    if not sf_case_id:
        return None
    try:
        _, instance_url = get_token()
        return f"{instance_url}/lightning/r/Case/{sf_case_id}/view"
    except Exception:
        return None


def lookup_case_owner(case_number, contact_id=None, account_id=None):
    """Return (ownerId, ownerName, caseRecordId) for a Case #; link a
    Contact/Account onto the case if it has none."""
    try:
        token, instance_url = get_token()
        soql = (
            "SELECT Id, CaseNumber, OwnerId, Owner.Name, ContactId FROM Case "
            f"WHERE CaseNumber = '{_soql_escape(case_number)}'"
        )
        recs = _query(instance_url, token, soql)
        if not recs:
            return None, None, None
        rec = recs[0]
        if contact_id and not rec.get("ContactId"):
            patch = {"ContactId": contact_id}
            if account_id:
                patch["AccountId"] = account_id
            try:
                _update(instance_url, token, "Case", rec["Id"], patch)
            except Exception:
                logger.exception("Could not link contact to case %s", rec.get("Id"))
        return rec["OwnerId"], (rec.get("Owner") or {}).get("Name"), rec.get("Id")
    except Exception:
        logger.exception("Salesforce lookup failed for case %s", case_number)
        return None, None, None


def related_open_cases(contact_id, account_id, exclude_case_id, limit=5):
    """S5 duplicate-work: find OTHER open cases for the same customer (Contact) and/or
    Account, excluding the current case. Returns (count, summary) where summary is e.g.
    '#00001030 (Sateesh, New); #00001031 (OrgFarm EPIC, Working)'. Best-effort."""
    try:
        clauses = []
        if contact_id:
            clauses.append(f"ContactId = '{_soql_escape(contact_id)}'")
        if account_id:
            clauses.append(f"AccountId = '{_soql_escape(account_id)}'")
        if not clauses:
            return 0, ""
        token, instance_url = get_token()
        where = "(" + " OR ".join(clauses) + ") AND IsClosed = false"
        if exclude_case_id:
            where += f" AND Id != '{_soql_escape(exclude_case_id)}'"
        soql = (
            "SELECT CaseNumber, Status, Owner.Name FROM Case "
            f"WHERE {where} ORDER BY CreatedDate DESC LIMIT {int(limit)}"
        )
        recs = _query(instance_url, token, soql)
        if not recs:
            return 0, ""
        parts = [
            f"#{r.get('CaseNumber')} ({(r.get('Owner') or {}).get('Name') or 'Unassigned'}, {r.get('Status') or ''})"
            for r in recs
        ]
        return len(recs), "; ".join(parts)
    except Exception:
        logger.exception("related_open_cases query failed")
        return 0, ""


def lookup_case_by_id(sf_case_id):
    """Re-read a case's CURRENT owner + number by record Id (used on the no-Case#
    fallback so ownership reassignment done in Salesforce is honored live).
    Returns (ownerId, ownerName, caseNumber)."""
    try:
        token, instance_url = get_token()
        recs = _query(
            instance_url, token,
            f"SELECT OwnerId, Owner.Name, CaseNumber FROM Case WHERE Id = '{_soql_escape(sf_case_id)}'",
        )
        if not recs:
            return None, None, None
        rec = recs[0]
        return rec["OwnerId"], (rec.get("Owner") or {}).get("Name"), rec.get("CaseNumber")
    except Exception:
        logger.exception("Salesforce lookup-by-id failed for %s", sf_case_id)
        return None, None, None


def create_case(subject, from_addr, contact_id=None, account_id=None):
    """Create a Case for a new inquiry; return (caseNumber, ownerId, ownerName,
    caseRecordId). Owner defaults to the Run As user unless assignment rules run."""
    try:
        token, instance_url = get_token()
        case_fields = {
            "Subject": subject or "(no subject)",
            "Description": f"Auto-created from email to shared mailbox. From: {from_addr}",
            "SuppliedEmail": from_addr,
            "Origin": "Email",
        }
        if contact_id:
            case_fields["ContactId"] = contact_id
        if account_id:
            case_fields["AccountId"] = account_id
        new_id = _insert(instance_url, token, "Case", case_fields)
        recs = _query(instance_url, token, f"SELECT CaseNumber, OwnerId, Owner.Name FROM Case WHERE Id = '{new_id}'")
        if not recs:
            return None, None, None, new_id
        rec = recs[0]
        return rec.get("CaseNumber"), rec.get("OwnerId"), (rec.get("Owner") or {}).get("Name"), new_id
    except Exception:
        logger.exception("Salesforce case creation failed")
        return None, None, None, None


def log_email_to_case(sf_case_id, subject, from_addr, to_addr, text_body, html_body,
                      contact_id=None, incoming=True):
    """Create an EmailMessage on the Case (case history) and relate it to the Contact
    (so it also appears on the customer's Activity timeline).

    incoming=True  -> customer's inbound email (Status New).
    incoming=False -> agent's outbound reply/email (Status Sent) — used by S4-B so the
                      Case shows the full in + out thread for supervisor review.
    """
    try:
        token, instance_url = get_token()
        body = {
            "ParentId": sf_case_id,
            "Subject": subject or "(no subject)",
            "FromAddress": from_addr,
            "ToAddress": to_addr,
            "Incoming": incoming,
            "Status": "0" if incoming else "3",  # 0=New (in), 3=Sent (out)
            "MessageDate": now_iso(),
        }
        if text_body:
            body["TextBody"] = text_body
        if html_body:
            body["HtmlBody"] = html_body
        email_id = _insert(instance_url, token, "EmailMessage", body)

        if contact_id:
            # Relate on the customer's address: inbound = From (sender), outbound = To (recipient).
            try:
                _insert(instance_url, token, "EmailMessageRelation", {
                    "EmailMessageId": email_id,
                    "RelationId": contact_id,
                    "RelationType": "FromAddress" if incoming else "ToAddress",
                    "RelationAddress": from_addr if incoming else to_addr,
                })
            except Exception:
                logger.exception("Could not relate email %s to contact %s", email_id, contact_id)
    except Exception:
        logger.exception("Could not log email to case %s", sf_case_id)
