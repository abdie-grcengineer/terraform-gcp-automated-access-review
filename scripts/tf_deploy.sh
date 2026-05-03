#!/bin/bash
# Deploy with the OPA policy gate.
# Four-step ritual: plan -> JSON export -> conftest gate -> apply saved plan.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$SCRIPT_DIR/../terraform"
POLICY_DIR="$SCRIPT_DIR/../policy"

cd "$TERRAFORM_DIR"

echo "=== 1. Generating Terraform plan ==="
# -input=false: never prompt for variables in CI; fail fast if missing.
# -out=tfplan: save the plan to disk so we can evaluate it with Conftest.
terraform plan -out=tfplan -input=false

echo ""
echo "=== 2. Exporting plan to JSON for policy evaluation ==="
# Conftest reads JSON, not Terraform's binary plan format.
terraform show -json tfplan > tfplan.json

echo ""
echo "=== 3. Running OPA/Conftest policy gate ==="
# --all-namespaces: evaluate every package under policy/ (we use namespaced packages).
conftest test --policy "$POLICY_DIR" --all-namespaces tfplan.json

echo ""
echo "=== 4. All policies passed, applying plan ==="
# terraform apply tfplan applies the EXACT saved plan that just passed the gate.
# No re-planning, no opportunity for drift between policy decision and apply.
terraform apply tfplan

echo ""
echo "=== Deploy complete ==="
