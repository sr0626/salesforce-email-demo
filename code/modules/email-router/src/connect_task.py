"""Create the Amazon Connect Task for a routed email."""

from config import connect, OWNER_FLOW_MAP, CONNECT_INSTANCE_ID, TASK_FLOW_ARN


def start_task(
    subject, mailbox, from_addr, case_number, owner_id, owner_name, is_shared,
    body_preview="", raw_url=None, case_url=None,
):
    # Route to the owner's dedicated flow (-> owner's queue/agent); if the owner
    # isn't mapped (or is unassigned), fall back to the shared flow/queue.
    flow_arn = OWNER_FLOW_MAP.get(owner_id or "", TASK_FLOW_ARN)

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
        InstanceId=CONNECT_INSTANCE_ID,
        ContactFlowId=flow_arn,
        Name=f"Email: {subject[:50]}",
        Description=f"From {from_addr} to {mailbox}",
        Attributes=attributes,
    )
    # Clickable links in the Task: the rendered email, and the Salesforce Case.
    refs = {}
    if raw_url:
        refs["Email"] = {"Value": raw_url, "Type": "URL"}
    if case_url:
        refs["SalesforceCase"] = {"Value": case_url, "Type": "URL"}
    if refs:
        kwargs["References"] = refs

    resp = connect.start_task_contact(**kwargs)
    return resp["ContactId"]
