"""Shared configuration: env-driven settings, AWS clients, and small utilities.

Imported by the other modules so all config lives in one place.
"""

import json
import logging
import os
import re
from datetime import datetime, timezone

import boto3
from botocore.config import Config

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# --- AWS clients ---
ddb = boto3.resource("dynamodb")
secrets = boto3.client("secretsmanager")
connect = boto3.client("connect")
ses = boto3.client("ses")
# SigV4 is required to presign GETs for KMS-SSE objects (SigV2 is rejected).
s3 = boto3.client("s3", config=Config(signature_version="s3v4"))

# --- DynamoDB tables ---
OWNERSHIP_TABLE = ddb.Table(os.environ["OWNERSHIP_TABLE"])
LOG_TABLE = ddb.Table(os.environ["ROUTING_LOG_TABLE"])
# S6: admin-maintainable routing rules (optional — table only wired when set).
_rules_table_name = os.environ.get("ROUTING_RULES_TABLE", "")
RULES_TABLE = ddb.Table(_rules_table_name) if _rules_table_name else None
# Salesforce Case fields the rules engine may match on (fetched per inbound email).
RULE_CASE_FIELDS = [f.strip() for f in os.environ.get("RULE_CASE_FIELDS", "Type,Priority,Origin,Reason,Status").split(",") if f.strip()]

# --- routing / parsing ---
CASE_RE = re.compile(os.environ["CASE_ID_REGEX"], re.IGNORECASE)
SHARED_MAILBOXES = set(
    a.strip().lower() for a in os.environ["SHARED_MAILBOXES"].split(",") if a.strip()
)
OWNER_FLOW_MAP = json.loads(os.environ.get("OWNER_FLOW_MAP", "{}"))
# Flow mode (native email): ownerId -> Connect queue ARN, plus a shared fallback.
# Empty until the native-email queues are wired (console/Terraform) — an empty
# targetQueueArn lets the inbound email flow branch to a default queue.
OWNER_QUEUE_MAP = json.loads(os.environ.get("OWNER_QUEUE_MAP", "{}"))
# ownerId -> "First Last", so the SLA alert can name the agent behind each owner queue.
OWNER_NAME_MAP = json.loads(os.environ.get("OWNER_NAME_MAP", "{}"))
# S6 specialists: reachable ONLY via routing rules (not owner-routed / not fallback).
# key -> queue ARN, and key -> display name. Keys are the rule targets.
SPECIALIST_QUEUE_MAP = json.loads(os.environ.get("SPECIALIST_QUEUE_MAP", "{}"))
SPECIALIST_NAME_MAP = json.loads(os.environ.get("SPECIALIST_NAME_MAP", "{}"))
# A routing rule's target may be an owner (SF OwnerId) or a specialist (key); this map
# resolves either to a queue ARN.
ROUTE_TARGET_MAP = {**OWNER_QUEUE_MAP, **SPECIALIST_QUEUE_MAP}
FALLBACK_QUEUE_ARN = os.environ.get("FALLBACK_QUEUE_ARN", "")
CONNECT_INSTANCE_ID = os.environ["CONNECT_INSTANCE_ID"]
TASK_FLOW_ARN = os.environ["TASK_FLOW_ARN"]

# --- SLA alert (owner-timeout) ---
# Scheduled sla_check mode polls Connect OLDEST_CONTACT_AGE per owner queue and emails
# a supervisor (SES HTML) when an unhandled email breaches the threshold. There is
# deliberately no overflow queue (validated gap #5) — this is an alert only.
# From must be a verified SES identity (the ccaas.evolvity.com domain covers any local part).
SLA_FROM_ADDRESS = os.environ.get("SLA_FROM_ADDRESS", "")
SLA_ALERT_EMAILS = [e.strip() for e in os.environ.get("SLA_ALERT_EMAILS", "").split(",") if e.strip()]
SLA_THRESHOLD_SECONDS = int(os.environ.get("SLA_THRESHOLD_SECONDS", "300"))
# Re-alert cooldown: don't email again for the same queue within this window, so a
# standing breach doesn't notify every scheduled tick. Default 1h.
SLA_REALERT_SECONDS = int(os.environ.get("SLA_REALERT_SECONDS", "3600"))
# How far back to pull email context (sender/subject/time) from the routing log.
# Wider than the SLA threshold so an email waiting for many hours still lists.
SLA_CONTEXT_HOURS = int(os.environ.get("SLA_CONTEXT_HOURS", "72"))
# Base access URL of the Connect instance (https://<alias>.my.connect.aws) — used to
# link the supervisor straight into the agent workspace from the alert.
CONNECT_ACCESS_URL = os.environ.get("CONNECT_ACCESS_URL", "")

# --- Salesforce ---
SF_SECRET_ARN = os.environ["SF_SECRET_ARN"]
SF_API_VERSION = os.environ.get("SF_API_VERSION", "v60.0")
AUTO_CREATE_CASE = os.environ.get("AUTO_CREATE_CASE", "true").lower() == "true"
LOG_EMAIL_TO_SF = os.environ.get("LOG_EMAIL_TO_SF", "true").lower() == "true"
# On the agent's first reply, advance the SF Case Status to this (from "New" only, so it
# never overrides Working/Escalated/Closed). Empty string disables the status update.
CASE_STATUS_ON_REPLY = os.environ.get("CASE_STATUS_ON_REPLY", "Working").strip()
LINK_CONTACT = os.environ.get("LINK_CONTACT", "true").lower() == "true"

# --- S3 email view ---
INBOUND_BUCKET = os.environ.get("INBOUND_BUCKET", "")
INBOUND_PREFIX = os.environ.get("INBOUND_PREFIX", "inbound/")

# Native-email (flow mode, Fix B): where Connect stores the email body.
CONNECT_EMAIL_BUCKET = os.environ.get("CONNECT_EMAIL_BUCKET", "")
CONNECT_EMAIL_PREFIX = os.environ.get("CONNECT_EMAIL_PREFIX", "")

# When true, flow mode logs the full Connect event (verbose; includes PII). Off by
# default — set FLOW_DEBUG=true on the Lambda to troubleshoot payload shape.
FLOW_DEBUG = os.environ.get("FLOW_DEBUG", "false").lower() == "true"
RENDERED_PREFIX = os.environ.get("RENDERED_PREFIX", "rendered/")
BODY_PREVIEW_CHARS = int(os.environ.get("BODY_PREVIEW_CHARS", "2000"))
RAW_EMAIL_URL_TTL = int(os.environ.get("RAW_EMAIL_URL_TTL", "43200"))  # 12h


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
