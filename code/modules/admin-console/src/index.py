"""Admin console Lambda (Function URL): serves a single-page console and a JSON CRUD
API for S6 routing rules + email templates, both stored in DynamoDB.

The HTML shell (GET /) is public; every /api/* call requires the bearer token
(Authorization: Bearer <ADMIN_TOKEN>), so nothing can be read or changed without it.
Serving the page and the API from the same Function URL means no CORS and no API
Gateway. Swap authorization_type NONE -> AWS_IAM (SigV4) or front with Cognito for prod.
"""

import json
import os
import time
import uuid
from decimal import Decimal

import boto3

ddb = boto3.resource("dynamodb")
RULES = ddb.Table(os.environ["ROUTING_RULES_TABLE"])
TEMPLATES = ddb.Table(os.environ["EMAIL_TEMPLATES_TABLE"])
TOKEN = os.environ.get("ADMIN_TOKEN", "")
OWNER_NAME_MAP = json.loads(os.environ.get("OWNER_NAME_MAP", "{}"))

_HTML = open(os.path.join(os.path.dirname(__file__), "console.html")).read()

# Case fields an admin may route on (standard Salesforce Case fields).
RULE_FIELDS = ["Type", "Priority", "Origin", "Reason", "Status"]


def _clean(obj):
    """Make DynamoDB items JSON-serializable (Decimal -> int/float)."""
    if isinstance(obj, list):
        return [_clean(o) for o in obj]
    if isinstance(obj, dict):
        return {k: _clean(v) for k, v in obj.items()}
    if isinstance(obj, Decimal):
        return int(obj) if obj % 1 == 0 else float(obj)
    return obj


def _resp(status, body, content_type="application/json"):
    is_json = content_type == "application/json"
    return {
        "statusCode": status,
        "headers": {"Content-Type": content_type, "Cache-Control": "no-store"},
        "body": json.dumps(body) if is_json else body,
    }


def _authed(headers):
    h = {k.lower(): v for k, v in (headers or {}).items()}
    auth = h.get("authorization", "")
    return bool(TOKEN) and auth == f"Bearer {TOKEN}"


def _now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _rule_item(data):
    now = _now()
    return {
        "ruleId": data.get("ruleId") or f"rule-{uuid.uuid4().hex[:12]}",
        "priority": int(data.get("priority") or 100),
        "field": (data.get("field") or "Type").strip(),
        "op": (data.get("op") or "equals").strip(),
        "value": (data.get("value") or "").strip(),
        "targetOwnerId": (data.get("targetOwnerId") or "").strip(),
        "active": bool(data.get("active", True)),
        "description": (data.get("description") or "").strip(),
        "createdAt": data.get("createdAt") or now,  # preserved on update (see handler)
        "updatedAt": now,
    }


def _template_item(data):
    now = _now()
    return {
        "templateId": data.get("templateId") or f"tmpl-{uuid.uuid4().hex[:12]}",
        "name": (data.get("name") or "Untitled").strip(),
        "shortcut": (data.get("shortcut") or "").strip(),
        "subject": (data.get("subject") or "").strip(),
        "body": data.get("body") or "",
        "active": bool(data.get("active", True)),
        "createdAt": data.get("createdAt") or now,  # preserved on update (see handler)
        "updatedAt": now,
    }


def handler(event, context):
    ctx = (event.get("requestContext") or {}).get("http", {}) or {}
    method = ctx.get("method", "GET").upper()
    path = event.get("rawPath") or ctx.get("path") or "/"
    headers = event.get("headers") or {}
    qs = event.get("queryStringParameters") or {}

    # Public: the console shell.
    if path == "/" or path == "":
        return _resp(200, _HTML, "text/html")

    if not path.startswith("/api/"):
        return _resp(404, {"error": "not found"})

    # Everything under /api/* is token-gated.
    if not _authed(headers):
        return _resp(401, {"error": "unauthorized"})

    # Lets the SPA validate the token + populate dropdowns.
    if path == "/api/config":
        owners = [{"id": k, "name": v} for k, v in sorted(OWNER_NAME_MAP.items(), key=lambda kv: kv[1])]
        return _resp(200, {"owners": owners, "fields": RULE_FIELDS})

    body = {}
    if event.get("body"):
        try:
            body = json.loads(event["body"])
        except ValueError:
            return _resp(400, {"error": "invalid JSON"})

    if path == "/api/rules":
        if method == "GET":
            items = sorted(RULES.scan().get("Items", []), key=lambda r: int(r.get("priority", 100)))
            return _resp(200, {"rules": _clean(items)})
        if method == "POST":
            if body.get("ruleId"):  # update: keep the original createdAt
                ex = RULES.get_item(Key={"ruleId": body["ruleId"]}).get("Item")
                if ex and ex.get("createdAt"):
                    body["createdAt"] = ex["createdAt"]
            item = _rule_item(body)
            RULES.put_item(Item=item)
            return _resp(200, {"rule": _clean(item)})
        if method == "DELETE":
            rid = qs.get("id") or body.get("ruleId")
            if not rid:
                return _resp(400, {"error": "id required"})
            RULES.delete_item(Key={"ruleId": rid})
            return _resp(200, {"deleted": rid})

    if path == "/api/templates":
        if method == "GET":
            items = sorted(TEMPLATES.scan().get("Items", []), key=lambda t: t.get("name", ""))
            return _resp(200, {"templates": _clean(items)})
        if method == "POST":
            if body.get("templateId"):  # update: keep the original createdAt
                ex = TEMPLATES.get_item(Key={"templateId": body["templateId"]}).get("Item")
                if ex and ex.get("createdAt"):
                    body["createdAt"] = ex["createdAt"]
            item = _template_item(body)
            TEMPLATES.put_item(Item=item)
            return _resp(200, {"template": _clean(item)})
        if method == "DELETE":
            tid = qs.get("id") or body.get("templateId")
            if not tid:
                return _resp(400, {"error": "id required"})
            TEMPLATES.delete_item(Key={"templateId": tid})
            return _resp(200, {"deleted": tid})

    return _resp(404, {"error": "not found"})
