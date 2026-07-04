#!/usr/bin/env bash
# Deploy the salesforce-email-demo Terraform stack.
# Runs terraform init + apply and prints the outputs the manual SES Phase B needs.
#
# This script does NOT set up SES (that is manual, see docs/05) and does NOT
# populate the Salesforce secret (see docs/06). Run it yourself; review the plan.
set -euo pipefail

cd "$(dirname "$0")/.."

# ---- CONFIG (edit or override via env) --------------------------------------
REGION="${REGION:-us-west-2}"
INSTANCE_ALIAS="${INSTANCE_ALIAS:-salesforce-email-demo}"
SES_DOMAIN="${SES_DOMAIN:-ccaas.evolvity.com}"
SHARED_MAILBOXES="${SHARED_MAILBOXES:-ordersuccess@ccaas.evolvity.com}"
# -----------------------------------------------------------------------------

echo "==> Verifying AWS credentials"
aws sts get-caller-identity >/dev/null

# Seed a terraform.tfvars from CONFIG if the user hasn't created one.
if [[ ! -f terraform.tfvars ]]; then
  echo "==> No terraform.tfvars found; writing one from CONFIG"
  cat > terraform.tfvars <<EOF
region           = "${REGION}"
instance_alias   = "${INSTANCE_ALIAS}"
ses_domain       = "${SES_DOMAIN}"
shared_mailboxes = "${SHARED_MAILBOXES}"
EOF
fi

echo "==> terraform init"
terraform init -input=false

echo "==> terraform apply"
terraform apply -input=false "$@"

echo
echo "==> Outputs (needed for manual SES Phase B — docs/05):"
terraform output

cat <<'NEXT'

Next steps:
  1. Populate the Salesforce secret (docs/06):
       aws secretsmanager put-secret-value --secret-id <salesforce_secret_name> \
         --secret-string '{"client_id":"...","client_secret":"...","login_url":"https://<mydomain>"}' \
         --region us-west-2
  2. SES Phase B (docs/05): create the receipt rule set + rule, point its S3
     action at <inbound_bucket> (prefix inbound/) and its Lambda action at
     <email_router_lambda_arn>, accept the "allow SES to invoke" prompt, then
     set the rule set active.
  3. Create a Connect agent user + assign the Email-Routing-Profile (docs/03).
NEXT
