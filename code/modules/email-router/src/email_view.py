"""Read the raw MIME from S3; produce a text preview and a browser-renderable
HTML view (written back to S3) that the agent can open from the Task."""

import email
import re

from config import (
    logger, s3, INBOUND_BUCKET, INBOUND_PREFIX, RENDERED_PREFIX,
    BODY_PREVIEW_CHARS, RAW_EMAIL_URL_TTL,
)


def fetch_body_and_link(message_id):
    """Return (text preview, presigned URL to an HTML view, text_body, html_body).
    The raw .eml isn't browser-readable, so we render the HTML (or wrap the text)
    into its own S3 object and presign that. Best-effort — never fails routing."""
    if not INBOUND_BUCKET:
        return "", None, None, None
    key = INBOUND_PREFIX + message_id
    try:
        raw = s3.get_object(Bucket=INBOUND_BUCKET, Key=key)["Body"].read()
        msg = email.message_from_bytes(raw)
        plain, html = _extract_bodies(msg)
        preview = (plain or _strip_tags(html) or "").strip()[:BODY_PREVIEW_CHARS]

        view_html = _render_email_html(msg, html, plain)
        view_key = RENDERED_PREFIX + message_id + ".html"
        s3.put_object(
            Bucket=INBOUND_BUCKET,
            Key=view_key,
            Body=view_html.encode("utf-8"),
            ContentType="text/html; charset=utf-8",
        )
        url = s3.generate_presigned_url(
            "get_object",
            Params={"Bucket": INBOUND_BUCKET, "Key": view_key},
            ExpiresIn=RAW_EMAIL_URL_TTL,
        )
        return preview, url, plain, html
    except Exception:
        logger.exception("Could not fetch/parse body for %s", message_id)
        return "", None, None, None


def _render_email_html(msg, html, plain):
    """Wrap the body with a From/To/Date/Subject header block so it reads like a
    real email."""
    rows = "".join(
        f"<div><b>{label}:</b> {_html_escape(msg.get(name, '') or '')}</div>"
        for label, name in (("From", "From"), ("To", "To"), ("Date", "Date"), ("Subject", "Subject"))
    )
    header = (
        "<div style=\"font-family:Arial,Helvetica,sans-serif;font-size:14px;"
        "background:#f4f6f8;border:1px solid #d8dde3;border-radius:6px;"
        "padding:12px 16px;margin-bottom:16px;color:#16325c\">" + rows + "</div>"
    )
    body = html or (
        "<pre style=\"white-space:pre-wrap;font-family:Arial,Helvetica,sans-serif\">"
        + _html_escape(plain or "(no text body)")
        + "</pre>"
    )
    return (
        "<div style=\"max-width:820px;margin:16px auto;padding:0 8px\">"
        + header + body + "</div>"
    )


def _extract_bodies(msg):
    """Return (text/plain, text/html) body strings (either may be None)."""
    plain, html = None, None
    for part in msg.walk() if msg.is_multipart() else [msg]:
        ctype = part.get_content_type()
        if ctype == "text/plain" and plain is None:
            plain = _decode_part(part)
        elif ctype == "text/html" and html is None:
            html = _decode_part(part)
    return plain, html


def _strip_tags(html):
    return re.sub(r"<[^>]+>", " ", html) if html else ""


def _html_escape(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def _decode_part(part):
    try:
        payload = part.get_payload(decode=True) or b""
        return payload.decode(part.get_content_charset() or "utf-8", "replace")
    except Exception:
        return ""
