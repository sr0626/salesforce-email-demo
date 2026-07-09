"""DynamoDB persistence: shared-mailbox ownership + routing audit log."""

from datetime import datetime, timedelta, timezone

from boto3.dynamodb.conditions import Key

from config import OWNERSHIP_TABLE, LOG_TABLE, now_iso

# Marker rows for the SLA re-alert cooldown share the routing-log table under a
# reserved emailId prefix (no extra table); they are skipped by email listings.
_SLA_MARKER_PREFIX = "SLA_ALERT#"


def upsert_ownership(mailbox, customer_email, owner_id, owner_name, case_number, sf_case_id=None):
    item = {
        "mailbox": mailbox,
        "customerEmail": customer_email.lower(),
        "ownerId": owner_id,
        "ownerName": owner_name,
        "caseId": case_number,
        "lastUpdated": now_iso(),
    }
    if sf_case_id:
        item["sfCaseId"] = sf_case_id
    OWNERSHIP_TABLE.put_item(Item=item)


def lookup_ownership_fallback(mailbox, customer_email):
    item = OWNERSHIP_TABLE.get_item(
        Key={"mailbox": mailbox, "customerEmail": customer_email.lower()}
    ).get("Item")
    if not item:
        return None, None, None, None
    return item["ownerId"], item["ownerName"], item.get("sfCaseId"), item.get("caseId")


def lookup_routing_by_contact(inbound_contact_id):
    """S4-B: find the routing-log row for an inbound email contact (emailId = the
    inbound Connect contactId) so an outbound reply can be mapped back to its Case.
    Returns the most recent matching item, or None."""
    if not inbound_contact_id:
        return None
    resp = LOG_TABLE.query(
        KeyConditionExpression=Key("emailId").eq(inbound_contact_id),
        ScanIndexForward=False,
        Limit=1,
    )
    items = resp.get("Items", [])
    return items[0] if items else None


def write_audit_log(
    email_id, mailbox, from_addr, subject, case_number,
    owner_id, owner_name, is_shared, contact_id, outcome, sf_case_id=None, routed_queue=None,
):
    item = {
        "emailId": email_id,
        "timestamp": now_iso(),
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
    if sf_case_id:
        # Stored so the SLA alert can deep-link the Case (case number alone can't).
        item["sfCaseId"] = sf_case_id
    if routed_queue:
        # The queue id the email actually landed in (rule override incl. specialists), so
        # the SLA alert attributes a waiting email to the right queue, not just the owner.
        item["routedQueue"] = routed_queue
    LOG_TABLE.put_item(Item=item)


def recent_inbound_emails(hours=24, limit=8):
    """SLA alert context: recent INBOUND email rows (subject/sender/time/case) from the
    routing log, newest first. Excludes outbound-log rows and SLA marker rows. A small
    Scan — fine for the demo table; add a timestamp GSI if the log ever grows large."""
    cutoff = (datetime.now(timezone.utc) - timedelta(hours=hours)).strftime("%Y-%m-%dT%H:%M:%S")
    items = LOG_TABLE.scan().get("Items", [])
    rows = [
        i for i in items
        if not str(i.get("emailId", "")).startswith(_SLA_MARKER_PREFIX)
        and i.get("routingOutcome") != "outbound-logged"
        and (i.get("timestamp") or "") >= cutoff
    ]
    rows.sort(key=lambda i: i.get("timestamp") or "", reverse=True)
    return rows[:limit]


def sla_alert_due(queue_id, cooldown_seconds):
    """True if this queue hasn't been SLA-alerted within cooldown_seconds (de-dupes the
    repeat email a standing breach would otherwise send on every scheduled tick)."""
    resp = LOG_TABLE.query(
        KeyConditionExpression=Key("emailId").eq(f"{_SLA_MARKER_PREFIX}{queue_id}"),
        ScanIndexForward=False,
        Limit=1,
    )
    items = resp.get("Items", [])
    if not items:
        return True
    try:
        last = datetime.strptime(items[0]["timestamp"][:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)
    except (KeyError, ValueError):
        return True
    return (datetime.now(timezone.utc) - last).total_seconds() >= cooldown_seconds


def sla_mark_alerted(queue_id):
    LOG_TABLE.put_item(Item={
        "emailId": f"{_SLA_MARKER_PREFIX}{queue_id}",
        "timestamp": now_iso(),
        "routingOutcome": "sla-alert",
    })
