#!/bin/bash
# One-time bootstrap of GCP foundation resources Terraform cannot manage itself:
#   - Project (if it doesn't exist)
#   - Required APIs enabled
#   - GCS state bucket (versioned)
#   - Workload Identity Federation pool + provider for GitHub Actions OIDC
#   - Service account with deploy permissions
#
# This is the chicken-and-egg foundation. You cannot Terraform-create the
# bucket holding Terraform state, or the WIF that GitHub Actions uses to
# authenticate to Terraform.
#
# Idempotent: running this on an account that already has these resources
# is a no-op. Safe to re-run.
set -e

# === Edit these for your account ===
GH_OWNER="abdie-grcengineer"
GH_REPO="terraform-gcp-automated-access-review"
PROJECT_DISPLAY_NAME="GCP Automated Access Review"
PROJECT_ID_PREFIX="gcp-access-review"
REGION="us-central1"
WIF_POOL="github-actions-pool"
WIF_PROVIDER="github-actions-provider"
SA_NAME="github-actions-deploy"
# ===================================

# If a project ID is provided as the first arg, use it. Otherwise create new.
if [ -n "$1" ]; then
  PROJECT_ID="$1"
  echo "Using existing project: $PROJECT_ID"
else
  PROJECT_ID="${PROJECT_ID_PREFIX}-$(date +%s)"
  echo "Creating new project: $PROJECT_ID"
  gcloud projects create "$PROJECT_ID" --name="$PROJECT_DISPLAY_NAME"
fi

gcloud config set project "$PROJECT_ID"

PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)")
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
STATE_BUCKET="abdi-tf-state-gcp-${PROJECT_NUMBER}"

# Pick the first billing account if not already linked.
BILLING_ACCOUNT=$(gcloud billing accounts list --filter="open=true" --format="value(name.basename())" | head -1)
if [ -n "$BILLING_ACCOUNT" ]; then
  echo "Linking billing: $BILLING_ACCOUNT"
  gcloud billing projects link "$PROJECT_ID" --billing-account="$BILLING_ACCOUNT" 2>&1 || true
fi

echo ""
echo "=== Enabling APIs (idempotent) ==="
gcloud services enable \
  cloudfunctions.googleapis.com \
  cloudbuild.googleapis.com \
  run.googleapis.com \
  eventarc.googleapis.com \
  storage.googleapis.com \
  cloudscheduler.googleapis.com \
  pubsub.googleapis.com \
  aiplatform.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  cloudresourcemanager.googleapis.com \
  cloudasset.googleapis.com \
  recommender.googleapis.com \
  securitycenter.googleapis.com \
  logging.googleapis.com \
  gmail.googleapis.com \
  secretmanager.googleapis.com \
  --project="$PROJECT_ID"

echo ""
echo "=== Creating state bucket (if not exists) ==="
if gcloud storage buckets describe "gs://$STATE_BUCKET" >/dev/null 2>&1; then
  echo "State bucket already exists: gs://$STATE_BUCKET"
else
  gcloud storage buckets create "gs://$STATE_BUCKET" \
    --project="$PROJECT_ID" \
    --location="$REGION" \
    --uniform-bucket-level-access
  gcloud storage buckets update "gs://$STATE_BUCKET" --versioning
fi

echo ""
echo "=== Creating Workload Identity Pool (if not exists) ==="
if gcloud iam workload-identity-pools describe "$WIF_POOL" --location=global --project="$PROJECT_ID" >/dev/null 2>&1; then
  echo "WIF pool already exists: $WIF_POOL"
else
  gcloud iam workload-identity-pools create "$WIF_POOL" \
    --project="$PROJECT_ID" \
    --location=global \
    --display-name="GitHub Actions Pool"
fi

echo ""
echo "=== Creating WIF Provider for GitHub (if not exists) ==="
if gcloud iam workload-identity-pools providers describe "$WIF_PROVIDER" --workload-identity-pool="$WIF_POOL" --location=global --project="$PROJECT_ID" >/dev/null 2>&1; then
  echo "WIF provider already exists: $WIF_PROVIDER"
else
  gcloud iam workload-identity-pools providers create-oidc "$WIF_PROVIDER" \
    --project="$PROJECT_ID" \
    --location=global \
    --workload-identity-pool="$WIF_POOL" \
    --display-name="GitHub Actions Provider" \
    --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner" \
    --attribute-condition="assertion.repository_owner == '${GH_OWNER}'" \
    --issuer-uri="https://token.actions.githubusercontent.com"
fi

echo ""
echo "=== Creating deploy service account (if not exists) ==="
if gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT_ID" >/dev/null 2>&1; then
  echo "Service account already exists: $SA_EMAIL"
else
  gcloud iam service-accounts create "$SA_NAME" \
    --project="$PROJECT_ID" \
    --display-name="GitHub Actions Terraform Deploy"
fi

echo ""
echo "=== Granting roles to deploy SA ==="
for role in roles/editor roles/iam.securityAdmin roles/iam.serviceAccountAdmin roles/storage.admin; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="$role" \
    --condition=None \
    --quiet >/dev/null
  echo "  attached: $role"
done

echo ""
echo "=== Allowing GitHub repo to impersonate the SA ==="
gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
  --project="$PROJECT_ID" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WIF_POOL}/attribute.repository/${GH_OWNER}/${GH_REPO}" \
  --quiet >/dev/null

WIF_PROVIDER_RESOURCE="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WIF_POOL}/providers/${WIF_PROVIDER}"

echo ""
echo "================================================================"
echo "Bootstrap complete. Save these values:"
echo "================================================================"
echo "GCP_PROJECT_ID:       $PROJECT_ID"
echo "GCP_PROJECT_NUMBER:   $PROJECT_NUMBER"
echo "GCP_STATE_BUCKET:     $STATE_BUCKET"
echo "GCP_SERVICE_ACCOUNT:  $SA_EMAIL"
echo "GCP_WIF_PROVIDER:     $WIF_PROVIDER_RESOURCE"
echo ""
echo "Set as GitHub repo secrets:"
echo "  gh secret set GCP_PROJECT_ID      --body \"$PROJECT_ID\""
echo "  gh secret set GCP_SERVICE_ACCOUNT --body \"$SA_EMAIL\""
echo "  gh secret set GCP_WIF_PROVIDER    --body \"$WIF_PROVIDER_RESOURCE\""
echo "================================================================"
