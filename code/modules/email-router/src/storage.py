"""DynamoDB persistence: shared-mailbox ownership + routing audit log."""

from config import OWNERSHIP_TABLE, LOG_TABLE, now_iso


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


def write_audit_log(
    email_id, mailbox, from_addr, subject, case_number,
    owner_id, owner_name, is_shared, contact_id, outcome,
):
    LOG_TABLE.put_item(
        Item={
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
    )
