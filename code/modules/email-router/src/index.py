"""Email case router Lambda — orchestration handler.

Two invocation modes share one routing brain (`_resolve_routing`):

  • SES mode (Task path, `taskdemo@`) — triggered by the SES receipt-rule Lambda
    action. Parses the raw email, routes, and starts an owner-targeted Connect
    **Task** (plus body preview / rendered link / SF email logging).

  • Flow mode (native email, `ordersuccess@`) — invoked from a Connect inbound
    **email contact flow**. Returns a flat string map so the flow can 'Set working
    queue' to the owner's queue and show the agent the Salesforce Case link. The
    email itself is read/replied natively in the agent workspace, so there is no
    S3 body fetch or Task here.

Routing decision for both:
  1. Parse the subject for a Salesforce Case Number.
  2. Resolve the customer (Contact + Account) so everything ties to one 360.
  3. Determine the owner:
       - Case # found  -> live Salesforce Case Owner lookup (Scenario 1).
       - No Case #     -> remembered owner in DynamoDB (Scenario 2 continuity);
                          if none, create a new Salesforce Case (Email-to-Case).

Concerns are split across sibling modules: config, salesforce, storage,
connect_task, connect_flow, email_view.
"""

import json
from email.utils import parseaddr, getaddresses

import connect_email
import connect_flow
import connect_task
import email_view
import salesforce
import storage
from config import (
    logger, CASE_RE, SHARED_MAILBOXES, AUTO_CREATE_CASE, LOG_EMAIL_TO_SF, LINK_CONTACT,
    FLOW_DEBUG,
)


def _resolve_routing(subject, mailbox, from_addr, from_display):
    """Shared decision core (channel-agnostic).

    Does the Salesforce lookups + DynamoDB ownership side-effects and returns the
    routing decision. No channel-specific I/O (no S3 body, no Task, no flow map),
    so both the SES handler and the flow handler reuse it identically.
    """
    # Resolve the customer once (Contact + Account) so the case, its emails,
    # and the customer's activity all tie to the same 360.
    contact_id, account_id = (
        salesforce.resolve_contact_account(from_addr, from_display) if LINK_CONTACT else (None, None)
    )

    m = CASE_RE.search(subject)
    case_number = m.group(1) if m else None

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
            # supervisor Change Owner) is honored, and the reply shows the caseId.
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

    return {
        "case_number": case_number,
        "owner_id": owner_id,
        "owner_name": owner_name,
        "sf_case_id": sf_case_id,
        "contact_id": contact_id,
        "account_id": account_id,
        "outcome": outcome,
    }


def _handle_ses(event):
    """SES mode → owner-targeted Connect Task (Task-path address, e.g. taskdemo@)."""
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

        d = _resolve_routing(subject, mailbox, from_addr, from_display)
        owner_id, owner_name, sf_case_id = d["owner_id"], d["owner_name"], d["sf_case_id"]
        case_number, outcome, contact_id = d["case_number"], d["outcome"], d["contact_id"]

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


def _handle_flow(event):
    """Flow mode → return the routing decision to a Connect email contact flow.

    Reads the subject + endpoints from the flow's Lambda Parameters (preferred, set
    explicitly in the flow block) or the ContactData as a fallback, runs the shared
    routing core, writes an audit row, and returns a flat string map. Connect
    exposes each key as $.External.<key> — the flow uses `targetQueueArn` to Set
    working queue and `salesforceCaseUrl` to show the agent the Case link.
    """
    details = event.get("Details", {}) or {}
    params = details.get("Parameters", {}) or {}
    contact = details.get("ContactData", {}) or {}
    attrs = contact.get("Attributes", {}) or {}

    # Optional payload dump for troubleshooting (subject/body source, key shapes).
    # Off by default (FLOW_DEBUG); verbose and includes PII when on.
    if FLOW_DEBUG:
        logger.info("flow-event: %s", json.dumps(event, default=str))

    # Subject source order: Connect's canonical SegmentAttributes.connect:EmailSubject
    # (confirmed via the flow-event dump) → explicit flow Parameter → contact
    # attribute → contact Name/Description. The segment attribute is the reliable one;
    # the rest are belt-and-suspenders if the payload shape ever changes.
    seg = contact.get("SegmentAttributes", {}) or {}
    seg_subject = (seg.get("connect:EmailSubject") or {}).get("ValueString") or ""
    subject = (
        seg_subject
        or params.get("emailSubject") or attrs.get("emailSubject")
        or contact.get("Name", "") or contact.get("Description", "") or ""
    )
    # Normalize endpoints to the bare local@domain (same as the SES path) so a
    # "Display Name <addr>" form never pollutes the DynamoDB ownership key — the
    # two modes must produce identical keys for Scenario-2 continuity.
    from_display, from_addr = parseaddr(
        params.get("fromAddress") or (contact.get("CustomerEndpoint") or {}).get("Address", "")
    )
    from_addr = from_addr.lower()
    _, mailbox = parseaddr(
        params.get("mailbox") or (contact.get("SystemEndpoint") or {}).get("Address", "")
    )
    mailbox = mailbox.lower()
    connect_contact_id = contact.get("ContactId", "")

    d = _resolve_routing(subject, mailbox, from_addr, from_display)

    is_shared = mailbox in SHARED_MAILBOXES
    case_url = salesforce.case_url(d["sf_case_id"])

    # Log the inbound native email onto the Case (history/360), mirroring the Task
    # path. Body comes from Connect's EMAIL_MESSAGES storage; if unavailable, log a
    # metadata note so the interaction still appears on the Case. Best-effort — never
    # blocks routing.
    if d["sf_case_id"] and LOG_EMAIL_TO_SF:
        text_body, html_body = connect_email.fetch_body(contact)
        if html_body:
            text_body = ""  # prefer the formatted HTML copy on the Case
        elif not text_body:
            text_body = f"(Received via Amazon Connect native email — contactId {connect_contact_id})"
        salesforce.log_email_to_case(
            d["sf_case_id"], subject, from_addr, mailbox, text_body, html_body, d["contact_id"],
        )

    storage.write_audit_log(
        connect_contact_id or "email-flow", mailbox, from_addr, subject, d["case_number"],
        d["owner_id"], d["owner_name"], is_shared, connect_contact_id, d["outcome"],
    )

    resp = connect_flow.build_response(d, mailbox, from_addr, is_shared, case_url)
    logger.info(
        "flow-routed contactId=%s case=%s owner=%s outcome=%s queue=%s",
        connect_contact_id, d["case_number"], d["owner_name"], d["outcome"], resp["targetQueueArn"],
    )
    return resp


def handler(event, context):
    # Connect flow invocations carry Details.ContactData; SES carries Records.
    if isinstance(event, dict) and (event.get("Details") or {}).get("ContactData"):
        return _handle_flow(event)
    return _handle_ses(event)
