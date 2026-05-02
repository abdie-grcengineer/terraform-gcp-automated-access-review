# Secret Manager entry for the Gmail OAuth refresh token.
# We store the refresh token here; the Cloud Function reads it at runtime to
# obtain short-lived access tokens for the Gmail API.
#
# Why Secret Manager and not env vars or hardcoded values:
# - Env vars are visible in the Cloud Function configuration to anyone with
#   read access. Secret Manager values are not.
# - Secret Manager versions secrets so token rotation is painless.
# - IAM scopes who can read the secret independently of who can read the
#   function configuration.

# The secret resource. This declares "we will have a secret named X."
# It does not store any value; values are stored as separate "secret versions."
resource "google_secret_manager_secret" "gmail_token" {
  project   = var.project_id
  secret_id = "${var.name_prefix}-gmail-refresh-token"

  # Replication policy: automatic means GCP picks the regions for redundancy.
  # User-managed replication is the alternative if you need data residency control.
  replication {
    auto {}
  }

  labels = {
    project   = var.name_prefix
    managedby = "terraform"
  }
}

# We do NOT create the secret version (the actual token value) in Terraform.
# That happens via scripts/gmail_oauth_setup.sh which runs the OAuth flow,
# obtains the refresh token, and writes it as a new version with:
#   gcloud secrets versions add ... --data-file=-
#
# Reasons to keep the value out of Terraform:
# 1. Refresh tokens are sensitive. Putting them in Terraform state means they
#    end up in the GCS state bucket, accessible to anyone with bucket read access.
# 2. The OAuth flow requires a browser dance that is not automatable in Terraform.
# 3. Token rotation should not require a Terraform run.

# Same pattern is used for any other sensitive runtime config.
# AWS equivalent: Secrets Manager secrets, often populated outside CFN/TF for
# the same reasons.
