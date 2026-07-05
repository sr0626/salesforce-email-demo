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
# SigV4 is required to presign GETs for KMS-SSE objects (SigV2 is rejected).
s3 = boto3.client("s3", config=Config(signature_version="s3v4"))

# --- DynamoDB tables ---
OWNERSHIP_TABLE = ddb.Table(os.environ["OWNERSHIP_TABLE"])
LOG_TABLE = ddb.Table(os.environ["ROUTING_LOG_TABLE"])

# --- routing / parsing ---
CASE_RE = re.compile(os.environ["CASE_ID_REGEX"], re.IGNORECASE)
SHARED_MAILBOXES = set(
    a.strip().lower() for a in os.environ["SHARED_MAILBOXES"].split(",") if a.strip()
)
OWNER_FLOW_MAP = json.loads(os.environ.get("OWNER_FLOW_MAP", "{}"))
CONNECT_INSTANCE_ID = os.environ["CONNECT_INSTANCE_ID"]
TASK_FLOW_ARN = os.environ["TASK_FLOW_ARN"]

# --- Salesforce ---
SF_SECRET_ARN = os.environ["SF_SECRET_ARN"]
SF_API_VERSION = os.environ.get("SF_API_VERSION", "v60.0")
AUTO_CREATE_CASE = os.environ.get("AUTO_CREATE_CASE", "true").lower() == "true"
LOG_EMAIL_TO_SF = os.environ.get("LOG_EMAIL_TO_SF", "true").lower() == "true"
LINK_CONTACT = os.environ.get("LINK_CONTACT", "true").lower() == "true"

# --- S3 email view ---
INBOUND_BUCKET = os.environ.get("INBOUND_BUCKET", "")
INBOUND_PREFIX = os.environ.get("INBOUND_PREFIX", "inbound/")
RENDERED_PREFIX = os.environ.get("RENDERED_PREFIX", "rendered/")
BODY_PREVIEW_CHARS = int(os.environ.get("BODY_PREVIEW_CHARS", "2000"))
RAW_EMAIL_URL_TTL = int(os.environ.get("RAW_EMAIL_URL_TTL", "43200"))  # 12h


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
