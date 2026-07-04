#!/usr/bin/env bash
# Static validation — safe to run without AWS credentials (after `terraform init`).
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> terraform fmt -recursive -check"
terraform fmt -recursive -check

echo "==> terraform validate"
terraform validate

if command -v tflint >/dev/null 2>&1; then
  echo "==> tflint"
  tflint
else
  echo "==> tflint not installed; skipping (optional)"
fi

echo "==> OK"
