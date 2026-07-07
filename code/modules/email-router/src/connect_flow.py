"""Build the routing decision returned to a Connect inbound email contact flow.

Flow mode (native email): the flow's 'Invoke AWS Lambda function' block calls the
handler, which returns this flat string map. Connect surfaces each key as
$.External.<key>, so the flow can:
  • Set working queue → `targetQueueArn` (owner's queue; shared fallback if unmapped)
  • Show the agent the Case → `salesforceCaseUrl` (rendered in the workspace view)

Connect requires the return value to be a flat object of string values (no nesting).
"""

from config import OWNER_QUEUE_MAP, FALLBACK_QUEUE_ARN


def build_response(decision, mailbox, from_addr, is_shared, case_url,
                   dup_count=0, dup_warning=""):
    owner_id = decision["owner_id"]
    # Route to the owner's queue; if the owner isn't mapped (or is unassigned),
    # fall back to the shared queue. Empty string lets the flow branch to a default.
    queue_arn = OWNER_QUEUE_MAP.get(owner_id or "", FALLBACK_QUEUE_ARN)

    return {
        "caseId": decision["case_number"] or "",
        "ownerId": owner_id or "UNASSIGNED",
        "ownerName": decision["owner_name"] or "Unassigned",
        "targetQueueArn": queue_arn or "",
        "salesforceCaseUrl": case_url or "",
        "mailbox": mailbox,
        "fromAddress": from_addr,
        "isSharedMailbox": "true" if is_shared else "false",
        "routingOutcome": decision["outcome"],
        # S5 duplicate-work alert (surfaced in the SF-360 screen-pop).
        "dupCount": str(dup_count),
        "dupWarning": dup_warning,
    }
