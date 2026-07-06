#!/usr/bin/env bash
#
# demo-new-case.sh — create a fresh Salesforce seed Case owned by a chosen user, so a
# clean demo has a known Case# -> owner mapping. Uses the SF Client-Credentials creds
# already stored in AWS Secrets Manager (the same secret the router Lambda uses).
#
# Requires: awscli (reads the secret) + curl + python3 (JSON parsing; no jq).
# Usage:
#   ./demo-new-case.sh                                   # owner = EPIC (default)
#   ./demo-new-case.sh 005dL00001o4jcLQAQ "Order status" # <ownerId> "<subject>"
#
# Known demo owners (Salesforce User Ids):
#   EPIC (OrgFarm EPIC) : 005dL00001nclyrQAA
#   Sateesh Rudrangi    : 005dL00001o4jcLQAQ
#
set -euo pipefail

REGION="${AWS_REGION:-us-west-2}"
SECRET_ID="${SF_SECRET_ID:-salesforce-email-demo-salesforce-credentials}"
API_VERSION="${SF_API_VERSION:-v60.0}"
OWNER_ID="${1:-005dL00001nclyrQAA}"   # default: EPIC
SUBJECT="${2:-Demo seed case}"

for c in aws curl python3; do
  command -v "$c" >/dev/null || { echo "ERROR: '$c' not found on PATH." >&2; exit 1; }
done

# 1) Salesforce creds from Secrets Manager
SECRET=$(aws secretsmanager get-secret-value --region "$REGION" \
  --secret-id "$SECRET_ID" --query SecretString --output text)
{ read -r CLIENT_ID; read -r CLIENT_SECRET; read -r LOGIN_URL; } < <(
  python3 -c 'import json,sys;c=json.load(sys.stdin);print(c["client_id"]);print(c["client_secret"]);print(c["login_url"].rstrip("/"))' <<<"$SECRET"
)

# 2) OAuth client-credentials token
TOK=$(curl -s -X POST "$LOGIN_URL/services/oauth2/token" \
  -d grant_type=client_credentials -d client_id="$CLIENT_ID" -d client_secret="$CLIENT_SECRET")
{ read -r ACCESS_TOKEN; read -r INSTANCE_URL; } < <(
  python3 -c 'import json,sys
t=json.load(sys.stdin)
if "access_token" not in t: sys.exit("SF token error: "+json.dumps(t))
print(t["access_token"]);print(t["instance_url"])' <<<"$TOK"
)

# 3) create the Case with the chosen owner (no Sforce-Auto-Assign header => our
#    explicit OwnerId sticks; assignment rules do not override it)
BODY=$(python3 -c 'import json,sys
print(json.dumps({"Subject":sys.argv[1],"OwnerId":sys.argv[2],"Origin":"Email",
  "Description":"Demo seed case created by demo-new-case.sh"}))' "$SUBJECT" "$OWNER_ID")
CREATE=$(curl -s -X POST "$INSTANCE_URL/services/data/$API_VERSION/sobjects/Case" \
  -H "Authorization: Bearer $ACCESS_TOKEN" -H "Content-Type: application/json" -d "$BODY")
CASE_ID=$(python3 -c 'import json,sys
r=json.load(sys.stdin)
if not r.get("success"): sys.exit("Case create failed: "+json.dumps(r))
print(r["id"])' <<<"$CREATE")

# 4) read back CaseNumber + Owner.Name and print a ready-to-send subject
Q="SELECT+CaseNumber,OwnerId,Owner.Name+FROM+Case+WHERE+Id='$CASE_ID'"
curl -s -H "Authorization: Bearer $ACCESS_TOKEN" \
  "$INSTANCE_URL/services/data/$API_VERSION/query?q=$Q" | python3 -c 'import json,sys
r=json.load(sys.stdin)["records"][0]
print()
print("Created Case #%s" % r["CaseNumber"])
print("  Owner  : %s (%s)" % (r["Owner"]["Name"], r["OwnerId"]))
print("  Demo   : email subject  \"Case #%s - test\"  ->  ordersuccess@ccaas.evolvity.com" % r["CaseNumber"])'
