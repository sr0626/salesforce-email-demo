"""S6 — admin-maintainable routing rules.

The admin console CRUDs rules in the RULES_TABLE (DynamoDB). Here we evaluate the
active rules against a Case's fields and, on the first match (lowest priority number
wins), return the target owner's queue so the flow routes there instead of the
Case-owner's queue. No match → (None, None) and normal routing stands.

A rule: { field, op(equals|in), value, targetOwnerId, priority, active, description }.
"""

from config import RULES_TABLE, ROUTE_TARGET_MAP, logger


def _matches(op, want, have):
    have = (str(have) or "").strip().lower()
    if not have:
        return False
    if op == "in":
        return have in [v.strip().lower() for v in (want or "").split(",") if v.strip()]
    return have == (want or "").strip().lower()


def evaluate(case_fields):
    """Return (targetQueueArn, description) for the first active rule that matches the
    given Case fields, or (None, None). Best-effort — never blocks routing."""
    if RULES_TABLE is None or not case_fields:
        return None, None
    try:
        items = RULES_TABLE.scan().get("Items", [])
    except Exception:
        logger.exception("routing-rules scan failed")
        return None, None

    active = [r for r in items if r.get("active")]
    active.sort(key=lambda r: int(r.get("priority", 100)))
    for r in active:
        if _matches((r.get("op") or "equals").lower(), r.get("value"), case_fields.get(r.get("field"))):
            # Target may be an owner (SF OwnerId) or a specialist (key).
            queue = ROUTE_TARGET_MAP.get(r.get("targetOwnerId") or "")
            if queue:  # ignore rules pointing at an unmapped owner/specialist
                desc = r.get("description") or f'{r.get("field")}={r.get("value")}'
                logger.info("routing-rule matched: %s -> %s", desc, r.get("targetOwnerId"))
                return queue, desc
    return None, None
