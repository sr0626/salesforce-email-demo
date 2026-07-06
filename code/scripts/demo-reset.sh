#!/usr/bin/env bash
#
# demo-reset.sh — clear Connect-side "memory" for a clean demo run.
#
# Empties the two DynamoDB tables so no hanging ownership / audit history skews
# routing:
#   * mailbox-ownership  (Scenario-2 remembered owner per mailbox+customer)
#   * email-routing-log  (routing audit trail)
#
# It does NOT touch Salesforce or in-flight Connect contacts — those are manual
# (see the reminders printed at the end / docs). AWS-side only.
#
# Requires: awscli (configured creds), permission to scan/delete on the tables.
# Usage:
#   ./demo-reset.sh              # prompts before deleting
#   ./demo-reset.sh --yes        # no prompt
#   AWS_REGION=us-west-2 OWNERSHIP_TABLE=... LOG_TABLE=... ./demo-reset.sh
#
set -euo pipefail

REGION="${AWS_REGION:-us-west-2}"
OWNERSHIP_TABLE="${OWNERSHIP_TABLE:-salesforce-email-demo-mailbox-ownership}"
LOG_TABLE="${LOG_TABLE:-salesforce-email-demo-email-routing-log}"
ASSUME_YES=0
[[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && ASSUME_YES=1

command -v aws >/dev/null || { echo "ERROR: awscli not found on PATH." >&2; exit 1; }

echo "Identity / target:"
aws sts get-caller-identity --query '{Account:Account,Arn:Arn}' --output table
echo "  region : $REGION"
echo "  tables : $OWNERSHIP_TABLE , $LOG_TABLE"
echo

if [[ "$ASSUME_YES" -ne 1 ]]; then
  read -r -p "DELETE ALL ITEMS from both tables above? [y/N] " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || { echo "Aborted."; exit 1; }
fi

# clear_table <table> <hashKey> <rangeKey>  (both keys are String type)
clear_table() {
  local table="$1" hk="$2" rk="$3" n=0 h r
  echo "Clearing $table (keys: $hk, $rk) ..."
  # #h/#r aliases avoid the reserved word 'timestamp' in the projection.
  local rows
  rows=$(aws dynamodb scan --region "$REGION" --table-name "$table" \
    --projection-expression "#h,#r" \
    --expression-attribute-names "{\"#h\":\"$hk\",\"#r\":\"$rk\"}" \
    --query "Items[].[$hk.S,$rk.S]" --output text)
  if [[ -z "$rows" ]]; then echo "  already empty"; return; fi
  while IFS=$'\t' read -r h r; do
    [[ -z "${h}${r}" ]] && continue
    aws dynamodb delete-item --region "$REGION" --table-name "$table" \
      --key "{\"$hk\":{\"S\":\"$h\"},\"$rk\":{\"S\":\"$r\"}}"
    n=$((n+1))
  done <<< "$rows"
  echo "  removed $n item(s)"
}

clear_table "$OWNERSHIP_TABLE" "mailbox" "customerEmail"
clear_table "$LOG_TABLE" "emailId" "timestamp"

cat <<'EOF'

DynamoDB cleared. Manual steps (NOT scriptable via AWS CLI) for a fully clean demo:
  • Salesforce : delete the junk auto-created test cases (owned by the Run-As user);
                 create fresh seed cases with  ./demo-new-case.sh  (EPIC by default;
                 pass a Sateesh owner id for a second) — prints the Case# to email;
                 optionally delete test EmailMessages on those cases.
  • Connect    : Contact search (Email) -> clear any In-progress/queued contacts;
                 log agents out/in, set Available, confirm none stuck in "Missed".
  • Gmail      : archive the old customer test threads.
EOF
