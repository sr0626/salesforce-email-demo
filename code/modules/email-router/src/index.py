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
from datetime import datetime, timezone
from email.utils import parseaddr, getaddresses
from html import escape as _esc

import connect_email
import connect_flow
import connect_task
import email_view
import salesforce
import storage
from config import (
    logger, CASE_RE, SHARED_MAILBOXES, AUTO_CREATE_CASE, LOG_EMAIL_TO_SF, LINK_CONTACT,
    FLOW_DEBUG, connect, ses, CONNECT_INSTANCE_ID, OWNER_QUEUE_MAP, OWNER_NAME_MAP,
    FALLBACK_QUEUE_ARN, SLA_FROM_ADDRESS, SLA_ALERT_EMAILS, SLA_THRESHOLD_SECONDS,
    SLA_REALERT_SECONDS, SLA_CONTEXT_HOURS, CONNECT_ACCESS_URL, CASE_STATUS_ON_REPLY,
)

# Single routing-log marker key for the GLOBAL SLA re-alert cooldown (one consolidated
# email per window, covering all breaching queues).
_SLA_COOLDOWN_KEY = "_ALL"


def _resolve_routing(subject, mailbox, from_addr, from_display):
    """Shared decision core (channel-agnostic).

    Does the Salesforce lookups + DynamoDB ownership side-effects and returns the
    routing decision. No channel-specific I/O (no S3 body, no Task, no flow map),
    so both the SES handler and the flow handler reuse it identically.
    """
    # Resolve the customer once (Contact + Account) so the case, its emails,
    # and the customer's activity all tie to the same 360.
    contact_id, account_id, contact_first = (
        salesforce.resolve_contact_account(from_addr, from_display) if LINK_CONTACT else (None, None, None)
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
        "contact_first_name": contact_first,
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
            owner_id, owner_name, is_shared, task_contact_id, outcome, sf_case_id=sf_case_id,
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
        sf_case_id=d["sf_case_id"],
    )

    # S5 duplicate-work alert: any OTHER open cases for this customer/account?
    dup_count, dup_summary = salesforce.related_open_cases(
        d["contact_id"], d["account_id"], d["sf_case_id"]
    )
    dup_warning = (
        f"⚠️ {dup_count} other open case(s) for this customer: {dup_summary}"
        if dup_count else "No other open cases for this customer."
    )

    # Quick-response personalization. Prefer the CRM Contact first name; fall back to the
    # email display name (native email puts it in CustomerEndpoint.DisplayName). If no
    # name, the greeting is just "Hi," (no dangling comma).
    customer_display = (contact.get("CustomerEndpoint") or {}).get("DisplayName", "") or from_display
    customer_name = d.get("contact_first_name") or (customer_display.split()[0] if customer_display else "")
    greeting = f"Hi {customer_name}," if customer_name else "Hi,"

    resp = connect_flow.build_response(
        d, mailbox, from_addr, is_shared, case_url, dup_count, dup_warning, customer_name, greeting
    )
    logger.info(
        "flow-routed contactId=%s case=%s owner=%s outcome=%s queue=%s dup=%s",
        connect_contact_id, d["case_number"], d["owner_name"], d["outcome"],
        resp["targetQueueArn"], dup_count,
    )
    return resp


def _handle_outbound_log(event):
    """S4-B: EventBridge Connect Contact Event (COMPLETED) for an agent's outbound
    EMAIL — log the sent message as an Outgoing EmailMessage on the SF Case so the
    Case shows the full in + out thread (supervisor review / audit).

    Only AGENT_REPLY / OUTBOUND email contacts are logged. The reply maps to its Case
    via the related inbound contact in the routing log; the body is read from Connect's
    EMAIL_MESSAGES storage (keyed by the reply contactId).
    """
    d = event.get("detail", {}) or {}

    def g(*names):  # Connect emits mixed-case field names across event types
        for n in names:
            if d.get(n) not in (None, ""):
                return d[n]
        return None

    if FLOW_DEBUG:
        logger.info("contact-event: %s", json.dumps(event, default=str))

    channel = (g("channel", "Channel") or "").upper()
    init = (g("initiationMethod", "InitiationMethod") or "").upper()
    contact_id = g("contactId", "ContactId")
    related = g("relatedContactId", "RelatedContactId") or \
        g("initialContactId", "InitialContactId") or g("previousContactId", "PreviousContactId")
    logger.info("contact-event ch=%s init=%s contactId=%s related=%s", channel, init, contact_id, related)

    if channel != "EMAIL" or init not in ("AGENT_REPLY", "OUTBOUND"):
        return {"status": "skipped", "reason": f"channel={channel} init={init}"}
    if not LOG_EMAIL_TO_SF:
        return {"status": "disabled"}

    # Map the outbound reply back to its Case via the inbound contact's routing-log row.
    routing = storage.lookup_routing_by_contact(related)
    case_number = (routing or {}).get("caseId")
    if not case_number:
        logger.info("outbound-log: no case mapping (contactId=%s related=%s init=%s)",
                    contact_id, related, init)
        return {"status": "no-case"}

    mailbox = (routing or {}).get("mailbox", "")
    customer = (routing or {}).get("fromAddress", "")
    subject = (routing or {}).get("subject", "")

    # Resolve the SF Case record id from the case number (reuses the owner lookup query).
    owner_id, owner_name, sf_case_id = salesforce.lookup_case_owner(case_number, None, None)
    if not sf_case_id:
        return {"status": "case-not-found", "case": case_number}

    # Outbound body from Connect's EMAIL_MESSAGES storage (keyed by the reply contactId).
    text_body, html_body = connect_email.fetch_body({"ContactId": contact_id})
    if not text_body and not html_body:
        text_body = f"(Outbound email sent via Amazon Connect — contactId {contact_id})"

    salesforce.log_email_to_case(
        sf_case_id, subject, mailbox, customer, text_body, html_body,
        contact_id=None, incoming=False,
    )

    # Advance the Case status on the agent's reply (New -> Working), so the CRM reflects
    # that it's being worked. Only lifts from New; never overrides a later status.
    if CASE_STATUS_ON_REPLY:
        new_status = salesforce.advance_case_status(sf_case_id, CASE_STATUS_ON_REPLY)
        if new_status:
            logger.info("case %s status advanced -> %s (agent reply)", case_number, new_status)

    storage.write_audit_log(
        contact_id, mailbox, mailbox, subject, case_number,
        owner_id, owner_name, mailbox in SHARED_MAILBOXES, contact_id, "outbound-logged",
    )
    logger.info("outbound-logged contactId=%s case=%s init=%s", contact_id, case_number, init)
    return {"status": "ok", "case": case_number}


def _handle_sla_check(event):
    """Owner-timeout alert (scheduled). Poll Connect for the oldest unhandled email
    in each owner queue; SNS-alert a supervisor for any queue past the SLA threshold.

    There is deliberately no overflow queue (validated gap #5) — emails stay with
    their owner and a supervisor is alerted to intervene. Triggered by an EventBridge
    schedule with input {"task": "sla_check"}; the rule can be toggled on for demos.
    """
    if not SLA_FROM_ADDRESS or not SLA_ALERT_EMAILS:
        return {"status": "no-recipient"}

    # Watch every owner queue plus the shared fallback. GetCurrentMetricData filters
    # on the queue *id* (the UUID after /queue/), not the full ARN.
    arns = set(OWNER_QUEUE_MAP.values()) | ({FALLBACK_QUEUE_ARN} if FALLBACK_QUEUE_ARN else set())
    queue_ids = sorted({a.rsplit("/queue/", 1)[-1] for a in arns if "/queue/" in a})
    if not queue_ids:
        return {"status": "no-queues"}

    resp = connect.get_current_metric_data(
        InstanceId=CONNECT_INSTANCE_ID,
        Filters={"Queues": queue_ids, "Channels": ["EMAIL"]},
        Groupings=["QUEUE"],
        CurrentMetrics=[
            {"Name": "OLDEST_CONTACT_AGE", "Unit": "SECONDS"},
            {"Name": "CONTACTS_IN_QUEUE", "Unit": "COUNT"},
        ],
    )

    breaches = []  # (queueId, ageSeconds, waitingCount)
    for result in resp.get("MetricResults", []):
        queue = (result.get("Dimensions", {}) or {}).get("Queue", {}) or {}
        qid = queue.get("Id") or (queue.get("Arn", "").rsplit("/queue/", 1)[-1])
        age = count = 0
        for coll in result.get("Collections", []):
            name = (coll.get("Metric", {}) or {}).get("Name")
            val = int(coll.get("Value") or 0)
            if name == "OLDEST_CONTACT_AGE":
                age = val
            elif name == "CONTACTS_IN_QUEUE":
                count = val
        if age >= SLA_THRESHOLD_SECONDS:
            breaches.append((qid, age, count))

    if not breaches:
        logger.info("sla-check queues=%d breaches=0 threshold=%ds", len(queue_ids), SLA_THRESHOLD_SECONDS)
        return {"status": "ok", "queues": len(queue_ids), "breaches": 0, "alerted": 0}

    # Re-alert cooldown (GLOBAL): send ONE consolidated email covering every breaching
    # queue, then stay quiet for SLA_REALERT_SECONDS. A single marker (not per-queue) so
    # queues whose breach windows are offset don't each trigger their own email.
    if not storage.sla_alert_due(_SLA_COOLDOWN_KEY, SLA_REALERT_SECONDS):
        logger.info("sla-check breaches=%d within re-alert cooldown", len(breaches))
        return {"status": "ok", "queues": len(queue_ids), "breaches": len(breaches), "alerted": 0}
    due = breaches

    def queue_name(qid):
        try:
            return connect.describe_queue(InstanceId=CONNECT_INSTANCE_ID, QueueId=qid)["Queue"]["Name"]
        except Exception:
            return f"queue {qid}"

    # The metric gives a per-queue count + oldest age but NOT the individual contacts,
    # so attribute the context emails to queues via the routing log: map each queue back
    # to its owner and show that owner's most-recent emails under it (fallback queue =
    # owners with no dedicated queue). Capped at the waiting count so the list reconciles.
    qid_to_owner = {
        arn.rsplit("/queue/", 1)[-1]: oid
        for oid, arn in OWNER_QUEUE_MAP.items() if "/queue/" in arn
    }
    owned_ids = set(qid_to_owner.values())
    fallback_qid = FALLBACK_QUEUE_ARN.rsplit("/queue/", 1)[-1] if "/queue/" in FALLBACK_QUEUE_ARN else None
    recent = storage.recent_inbound_emails(SLA_CONTEXT_HOURS, limit=50)

    def emails_for_queue(qid, n):
        owner = qid_to_owner.get(qid)
        if owner:
            rows = [r for r in recent if r.get("resolvedOwnerId") == owner]
        elif qid == fallback_qid:
            rows = [r for r in recent if r.get("resolvedOwnerId") not in owned_ids]
        else:
            rows = []
        return rows[:n]

    # Normalize each breaching queue into a render-agnostic dict so the text + HTML
    # bodies stay in sync. The list is a routing-log proxy for the metric count; when
    # it's short (an email older than the context window, or handled since) `extra`
    # records the gap so "N waiting / fewer shown" is never unexplained.
    queues = []
    for qid, age, count in due:
        rows = emails_for_queue(qid, min(count or 5, 5))
        emails = []
        for r in rows:
            ts_raw = r.get("timestamp") or ""
            emails.append({
                "subject": r.get("subject") or "(no subject)",
                "sender": r.get("fromAddress") or "unknown sender",
                "received": ts_raw[:16].replace("T", " "),
                "waited": _age_since(ts_raw),  # per-email waiting time (now - received)
                "case_no": r.get("caseId") or "",
                "link": salesforce.case_url(r.get("sfCaseId")) if r.get("sfCaseId") else None,
            })
        owner = qid_to_owner.get(qid)
        agent = OWNER_NAME_MAP.get(owner, "—") if owner else "Shared / unassigned"
        queues.append({
            "name": queue_name(qid), "agent": agent, "count": count,
            "age": _fmt_dur(age), "emails": emails,
            "extra": max(count - len(rows), 0),
        })

    threshold_min = SLA_THRESHOLD_SECONDS // 60
    # Lead the subject with the worst actual wait (severity), not the SLA threshold.
    worst = _fmt_dur(max(age for _, age, _ in due))
    total_waiting = sum(count for _, _, count in due)
    subject = f"SLA alert: {total_waiting} email(s) unhandled, oldest {worst}"
    ses.send_email(
        Source=SLA_FROM_ADDRESS,
        Destination={"ToAddresses": SLA_ALERT_EMAILS},
        Message={
            "Subject": {"Data": subject},
            "Body": {
                "Text": {"Data": _sla_text(threshold_min, queues)},
                "Html": {"Data": _sla_html(threshold_min, queues)},
            },
        },
    )
    storage.sla_mark_alerted(_SLA_COOLDOWN_KEY)

    logger.info("sla-check queues=%d breaches=%d alerted=%d threshold=%ds",
                len(queue_ids), len(breaches), len(due), SLA_THRESHOLD_SECONDS)
    return {"status": "ok", "queues": len(queue_ids), "breaches": len(breaches), "alerted": len(due)}


def _fmt_dur(seconds):
    """Human-readable duration, largest two units: 45s / 6m 40s / 10h 20m / 1d 16h."""
    s = max(int(seconds), 0)
    d, rem = divmod(s, 86400)
    h, rem = divmod(rem, 3600)
    m, sec = divmod(rem, 60)
    if d:
        return f"{d}d {h}h"
    if h:
        return f"{h}h {m}m"
    if m:
        return f"{m}m {sec}s"
    return f"{sec}s"


def _age_since(ts_raw):
    """'now - <ISO timestamp>' as a compact duration; '' on bad input."""
    try:
        ts = datetime.strptime((ts_raw or "")[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)
    except ValueError:
        return ""
    return _fmt_dur((datetime.now(timezone.utc) - ts).total_seconds())


def _sla_text(threshold_min, queues):
    """Plain-text alert body (also the SES text alternative)."""
    blocks = []
    for q in queues:
        lines = [f'  ▸ {q["name"]} · {q["agent"]} — {q["count"]} waiting']
        for e in q["emails"]:
            tag = f'Case #{e["case_no"]}' if e["case_no"] else "new case"
            if e["link"]:
                tag = f'{tag} — {e["link"]}'
            wait = f'waiting {e["waited"]}, ' if e["waited"] else ""
            lines.append(f'      · "{e["subject"]}" — from {e["sender"]}, {wait}'
                         f'received {e["received"]} UTC — {tag}')
        if q["extra"]:
            lines.append(f'      · … +{q["extra"]} more not listed')
        blocks.append("\n".join(lines))
    parts = [
        f"{len(queues)} owner queue(s) have email waiting longer than {threshold_min} minute(s).",
        "", "\n\n".join(blocks),
    ]
    if CONNECT_ACCESS_URL:
        parts += ["", f"Open Amazon Connect: {CONNECT_ACCESS_URL}"]
    parts += ["", "No overflow queue is configured by design — reassign the case in Salesforce "
              "or pick it up in Amazon Connect."]
    return "\n".join(parts)


def _sla_html(threshold_min, queues):
    """Styled HTML alert body (SES). Inline styles only — email clients strip <style>."""
    td = "padding:8px 12px;border-bottom:1px solid #eaeaea"
    summary_rows = "".join(
        f'<tr><td style="{td}">{_esc(q["name"])}</td>'
        f'<td style="{td}">{_esc(q["agent"])}</td>'
        f'<td align="center" style="{td}">{q["count"]}</td>'
        f'<td style="{td}">{_esc(q["age"])}</td></tr>'
        for q in queues
    )
    pill = ("display:inline-block;font-size:12px;font-weight:600;padding:1px 9px;"
            "border-radius:999px;text-decoration:none")
    blocks = ""
    for q in queues:
        rows_html = ""
        for i, e in enumerate(q["emails"]):
            top = "" if i == 0 else "border-top:1px solid #ececf0;"
            if e["case_no"] and e["link"]:
                case = (f'<a href="{_esc(e["link"])}" style="{pill};background:#e8f0fe;color:#0b5cad">'
                        f'Case #{_esc(e["case_no"])} &#8599;</a>')
            elif e["case_no"]:
                case = (f'<span style="{pill};background:#eef0f2;color:#5b6472">'
                        f'Case #{_esc(e["case_no"])}</span>')
            else:
                case = f'<span style="{pill};background:#eef0f2;color:#5b6472">new case</span>'
            wait_chip = (
                f'<span style="background:#fdecea;color:#b3261e;font-weight:600;font-size:12px;'
                f'padding:1px 8px;border-radius:999px">waiting {_esc(e["waited"])}</span> &nbsp;&middot;&nbsp; '
                if e["waited"] else ""
            )
            rows_html += (
                f'<div style="padding:9px 0;{top}">'
                f'<div style="font-weight:600;color:#1a1c22;font-size:14px">{_esc(e["subject"])}</div>'
                f'<div style="color:#6b7280;font-size:12.5px;margin-top:3px">'
                f'{wait_chip}{_esc(e["sender"])} &nbsp;&middot;&nbsp; received {_esc(e["received"])} UTC '
                f'&nbsp;&middot;&nbsp; {case}</div>'
                f'</div>'
            )
        if q["extra"]:
            rows_html += (f'<div style="padding:8px 0 0;border-top:1px solid #ececf0;'
                          f'color:#9aa2ad;font-size:12.5px">&#8230; +{q["extra"]} more not listed</div>')
        blocks += (
            f'<div style="border:1px solid #ececf0;border-left:4px solid #b3261e;border-radius:8px;'
            f'background:#fafbfc;padding:12px 14px;margin:14px 0 0">'
            f'<div style="font-weight:700;font-size:15px;color:#1a1c22;margin-bottom:2px">{_esc(q["name"])} '
            f'<span style="font-weight:400;color:#6b7280;font-size:13px">&middot; {_esc(q["agent"])}</span></div>'
            f'{rows_html}</div>'
        )
    open_connect = (
        f'<p style="margin:20px 0 0"><a href="{_esc(CONNECT_ACCESS_URL)}" '
        f'style="background:#0b5cad;color:#fff;padding:9px 16px;border-radius:5px;'
        f'text-decoration:none;font-size:14px">Open Amazon Connect</a></p>'
        if CONNECT_ACCESS_URL else ""
    )
    return (
        '<div style="font-family:Arial,Helvetica,sans-serif;color:#202124;max-width:680px;'
        'margin:0 auto;padding:8px">'
        '<h2 style="margin:0 0 2px;font-size:20px">⚠️ Owner-timeout SLA alert</h2>'
        f'<p style="color:#555;margin:0 0 14px">{len(queues)} queue(s) have email waiting '
        f'longer than {threshold_min} minute(s).</p>'
        '<table cellspacing="0" cellpadding="0" style="border-collapse:collapse;width:100%;'
        'border:1px solid #eaeaea;font-size:14px">'
        '<thead><tr style="background:#f4f6f8;text-align:left">'
        '<th style="padding:8px 12px">Queue</th>'
        '<th style="padding:8px 12px">Owner / agent</th>'
        '<th style="padding:8px 12px" align="center">Waiting</th>'
        '<th style="padding:8px 12px">Oldest</th></tr></thead>'
        f'<tbody>{summary_rows}</tbody></table>'
        f'{blocks}{open_connect}'
        '<p style="color:#999;font-size:12px;margin:22px 0 0">No overflow queue is configured '
        'by design — reassign the case in Salesforce or pick it up in Amazon Connect.</p></div>'
    )


def handler(event, context):
    # Dispatch by event shape:
    #   EventBridge schedule {"task": "sla_check"} -> owner-timeout alert
    #   EventBridge Connect Contact Event -> outbound-logging (S4-B)
    #   Connect flow invocation (Details.ContactData) -> flow-mode routing
    #   SES receipt-rule (Records) -> Task path
    if isinstance(event, dict):
        if event.get("task") == "sla_check":
            return _handle_sla_check(event)
        if event.get("detail-type") == "Amazon Connect Contact Event":
            return _handle_outbound_log(event)
        if (event.get("Details") or {}).get("ContactData"):
            return _handle_flow(event)
    return _handle_ses(event)
