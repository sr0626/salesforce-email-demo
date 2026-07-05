"""Email case router Lambda — orchestration handler.

Triggered by an SES receipt-rule Lambda action for mail to the shared mailbox(es).
For each message:

  1. Parse the subject for a Salesforce Case Number.
  2. Resolve the customer (Contact + Account) so everything ties to one 360.
  3. Determine the owner:
       - Case # found  -> live Salesforce Case Owner lookup (Scenario 1).
       - No Case #     -> remembered owner in DynamoDB (Scenario 2 continuity);
                          if none, create a new Salesforce Case (Email-to-Case).
  4. Enrich: body preview + rendered email link; log the email onto the Case and
     relate it to the Contact.
  5. Start an owner-targeted Amazon Connect Task; write an audit-log row.

Concerns are split across sibling modules: config, salesforce, storage,
connect_task, email_view.
"""

from email.utils import parseaddr, getaddresses

import connect_task
import email_view
import salesforce
import storage
from config import (
    logger, CASE_RE, SHARED_MAILBOXES, AUTO_CREATE_CASE, LOG_EMAIL_TO_SF, LINK_CONTACT,
)


def handler(event, context):
    for record in event["Records"]:
        mail = record["ses"]["mail"]
        message_id = mail["messageId"]
        subject = mail["commonHeaders"].get("subject", "")
        # Normalize to the bare local@domain — headers may arrive as
        # "Display Name <addr>", which must not pollute keys or defeat the
        # shared-mailbox match.
        from_display, from_addr = parseaddr(mail["commonHeaders"].get("from", [""])[0])
        from_addr = from_addr.lower()
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

        # Resolve the customer once (Contact + Account) so the case, its emails,
        # and the customer's activity all tie to the same 360.
        contact_id, account_id = (
            salesforce.resolve_contact_account(from_addr, from_display) if LINK_CONTACT else (None, None)
        )

        if case_number:
            # Scenario 1: subject carries a Case # → live owner lookup.
            owner_id, owner_name, sf_case_id = salesforce.lookup_case_owner(case_number, contact_id, account_id)
            outcome = "resolved" if owner_id else "unassigned"
            if owner_id:
                storage.upsert_ownership(mailbox, from_addr, owner_id, owner_name, case_number, sf_case_id)
        else:
            # Scenario 2: no Case # → remembered owner for this customer.
            owner_id, owner_name, sf_case_id, remembered_case = storage.lookup_ownership_fallback(mailbox, from_addr)
            if owner_id or sf_case_id:
                # Continuation of a known thread. If we know the case, re-read its
                # CURRENT owner + number live so a Salesforce reassignment (agent or
                # supervisor Change Owner) is honored, and the Task shows the caseId.
                if sf_case_id:
                    live_owner, live_name, live_case = salesforce.lookup_case_by_id(sf_case_id)
                    if live_owner:
                        owner_id, owner_name = live_owner, live_name
                    case_number = live_case or remembered_case
                else:
                    case_number = remembered_case
                outcome = "fallback" if owner_id else "unassigned"
                if owner_id:
                    storage.upsert_ownership(mailbox, from_addr, owner_id, owner_name, case_number, sf_case_id)
            elif AUTO_CREATE_CASE:
                # New inquiry: no case and no history → create a Salesforce Case.
                case_number, owner_id, owner_name, sf_case_id = salesforce.create_case(
                    subject, from_addr, contact_id, account_id
                )
                outcome = "created" if case_number else "unassigned"
                if owner_id:
                    storage.upsert_ownership(mailbox, from_addr, owner_id, owner_name, case_number, sf_case_id)
            else:
                outcome = "unassigned"

        is_shared = mailbox in SHARED_MAILBOXES
        body_preview, raw_url, text_body, html_body = email_view.fetch_body_and_link(message_id)
        case_url = salesforce.case_url(sf_case_id)

        # Log the email onto the Case (history) + relate it to the Contact.
        if sf_case_id and LOG_EMAIL_TO_SF:
            salesforce.log_email_to_case(sf_case_id, subject, from_addr, mailbox, text_body, html_body, contact_id)

        task_contact_id = connect_task.start_task(
            subject, mailbox, from_addr, case_number, owner_id, owner_name,
            is_shared, body_preview, raw_url, case_url,
        )
        storage.write_audit_log(
            message_id, mailbox, from_addr, subject, case_number,
            owner_id, owner_name, is_shared, task_contact_id, outcome,
        )
        logger.info(
            "routed messageId=%s case=%s owner=%s outcome=%s contact=%s",
            message_id, case_number, owner_name, outcome, task_contact_id,
        )
    return {"status": "ok"}
