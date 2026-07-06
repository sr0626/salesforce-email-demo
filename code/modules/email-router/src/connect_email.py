"""Retrieve a native-email body from Connect's EMAIL_MESSAGES S3 storage (flow mode).

Connect stores the email content in its own bucket (CONNECT_EMAIL_BUCKET), separate
from the SES `inbound/` prefix the Task path reads — so email_view.fetch_body_and_link
doesn't apply here. Returns (text_body, html_body); ("", "") when unavailable so the
caller falls back to a metadata-only note and case logging never breaks routing.

Storage layout (confirmed from a real object):
  <prefix>/YYYY/MM/DD/<uuid1>_<uuid2>_<YYYYMMDDThh:mm>_UTC.json
  content: {"contentType":"text/html","messageContent":"<html>…</html>"}
The contact's id appears in the filename, so we list the day's objects and match.
"""

import json
from datetime import datetime, timedelta, timezone

from config import logger, s3, CONNECT_EMAIL_BUCKET, CONNECT_EMAIL_PREFIX


def fetch_body(contact):
    """Best-effort fetch of the body Connect stored for this email contact.

    `contact` is the flow event's Details.ContactData. Returns (text_body, html_body).
    """
    if not CONNECT_EMAIL_BUCKET or not CONNECT_EMAIL_PREFIX:
        return "", ""

    # Identifiers that may appear in the object key: the contact ids and the
    # EMAIL_MESSAGE reference ids Connect attaches to the contact.
    ids = {contact.get("ContactId"), contact.get("InitialContactId")}
    ids |= set((contact.get("References") or {}).keys())
    ids = {i for i in ids if i}
    if not ids:
        return "", ""

    base = CONNECT_EMAIL_PREFIX.strip("/")
    now = datetime.now(timezone.utc)
    text_body = html_body = ""
    try:
        # Objects are stored under the UTC date; check today + yesterday for the
        # midnight boundary.
        for day in (now, now - timedelta(days=1)):
            prefix = f"{base}/{day:%Y/%m/%d}/"
            resp = s3.list_objects_v2(Bucket=CONNECT_EMAIL_BUCKET, Prefix=prefix)
            for obj in resp.get("Contents", []):
                key = obj["Key"]
                if not any(i in key for i in ids):
                    continue
                data = json.loads(
                    s3.get_object(Bucket=CONNECT_EMAIL_BUCKET, Key=key)["Body"].read()
                )
                content = data.get("messageContent", "") or ""
                if "html" in (data.get("contentType", "") or "").lower():
                    html_body = html_body or content
                else:
                    text_body = text_body or content
            if text_body or html_body:
                break  # found the message under this day's partition
    except Exception:
        logger.exception("Could not fetch Connect email body for %s", ids)

    return text_body, html_body
