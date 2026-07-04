#!/usr/bin/env bash
# Tear down the stack. The inbound-email S3 bucket has prevent_destroy = true so
# terraform destroy will stop at it by design (raw-email audit trail is kept).
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> Verifying AWS credentials"
aws sts get-caller-identity >/dev/null

echo "==> terraform destroy"
terraform destroy -input=false "$@"

cat <<'NOTE'

NOTE: If destroy stopped at the inbound-email bucket, that is intentional
(prevent_destroy protects the raw-email audit trail). To remove it too:
  1. Empty the bucket:      aws s3 rm s3://<inbound_bucket> --recursive
  2. Delete the 'lifecycle { prevent_destroy = true }' block in
     modules/email-storage/main.tf
  3. Re-run terraform destroy   (or: terraform state rm to drop it from state)

Also remember SES resources are manual: deactivate/delete the receipt rule set
and the domain identity in the SES console if you want a full cleanup (docs/05).
NOTE
