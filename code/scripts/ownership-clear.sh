#!/usr/bin/env bash
#
# ownership-clear.sh — clear the remembered Scenario-2 ownership for ONE customer
# email (across all mailboxes), so their next email re-resolves fresh (Case# lookup
# or auto-create) without wiping the whole table.
#
# Requires: awscli (configured creds). Usage:
#   ./ownership-clear.sh                        # default: skrudrangi@gmail.com
#   ./ownership-clear.sh someone@example.com
#
set -euo pipefail

REGION="${AWS_REGION:-us-west-2}"
OWNERSHIP_TABLE="${OWNERSHIP_TABLE:-salesforce-email-demo-mailbox-ownership}"
# stored customerEmail is lowercased by the Lambda — match that.
CUSTOMER=$(printf '%s' "${1:-skrudrangi@gmail.com}" | tr '[:upper:]' '[:lower:]')

command -v aws >/dev/null || { echo "ERROR: awscli not found on PATH." >&2; exit 1; }

echo "Clearing ownership for customer: $CUSTOMER"
echo "  table : $OWNERSHIP_TABLE   region: $REGION"

# customerEmail is the range key (not directly queryable) -> scan + filter, delete matches.
rows=$(aws dynamodb scan --region "$REGION" --table-name "$OWNERSHIP_TABLE" \
  --filter-expression "customerEmail = :ce" \
  --expression-attribute-values "{\":ce\":{\"S\":\"$CUSTOMER\"}}" \
  --projection-expression "mailbox, customerEmail" \
  --query "Items[].[mailbox.S, customerEmail.S]" --output text)

if [[ -z "$rows" ]]; then echo "  no ownership rows found for $CUSTOMER"; exit 0; fi

n=0
while IFS=$'\t' read -r mbox cust; do
  [[ -z "${mbox}${cust}" ]] && continue
  aws dynamodb delete-item --region "$REGION" --table-name "$OWNERSHIP_TABLE" \
    --key "{\"mailbox\":{\"S\":\"$mbox\"},\"customerEmail\":{\"S\":\"$cust\"}}"
  echo "  deleted (mailbox=$mbox, customer=$cust)"
  n=$((n+1))
done <<< "$rows"
echo "Removed $n ownership row(s) for $CUSTOMER"
