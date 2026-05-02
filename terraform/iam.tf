# IAM for the Cloud Function: a service account it runs as, plus the role
# bindings that give it the permissions it needs to do its job.
#
# Big difference from AWS:
# - In AWS, you write inline JSON policies attached to roles.
# - In GCP, you bind a principal (the service account) to predefined roles
#   at a resource scope (project, bucket, function, etc.). The "policy" is
#   the union of all bindings.
# - There is no inline IAM policy concept. You either use Google's predefined
#   roles or define a custom role separately and bind to it.

# The service account the Cloud Function runs as.
# Every Cloud Function 2nd gen needs an attached service account; without it,
# the function gets the default Compute Engine service account, which has
# more privilege than we want.
resource "google_service_account" "function" {
  account_id   = "${var.name_prefix}-function-sa"
  display_name = "Access Review Function Service Account"
  description  = "Identity assumed by the access review Cloud Function. Permissions are granted via project IAM bindings below."
  project      = var.project_id
}

# Permission: read the project's IAM policy.
# Cloud Function inspects who has what role on the project.
# roles/iam.securityReviewer is read-only across IAM resources;
# the lighter alternative roles/iam.roleViewer is too narrow (only sees roles, not bindings).
resource "google_project_iam_member" "function_iam_reader" {
  project = var.project_id
  role    = "roles/iam.securityReviewer"
  member  = "serviceAccount:${local.function_sa_email}"
}

# Permission: read Cloud Asset inventory.
# Cloud Asset Inventory aggregates all GCP resources across a project and is
# the most efficient way to enumerate resources for the report.
# Equivalent in spirit to AWS's IAM list operations + Resource Groups Tagging API.
resource "google_project_iam_member" "function_asset_viewer" {
  project = var.project_id
  role    = "roles/cloudasset.viewer"
  member  = "serviceAccount:${local.function_sa_email}"
}

# Permission: read Security Command Center findings.
# SCC is GCP's equivalent of AWS Security Hub. Findings include misconfigurations,
# threats, vulnerabilities. The findingsViewer role is read-only.
resource "google_project_iam_member" "function_scc_viewer" {
  project = var.project_id
  role    = "roles/securitycenter.findingsViewer"
  member  = "serviceAccount:${local.function_sa_email}"
}

# Permission: read Recommender API output.
# Recommender provides actionable suggestions like "remove this stale IAM grant"
# or "downgrade this role." It is GCP's nearest equivalent to IAM Access Analyzer.
resource "google_project_iam_member" "function_recommender_viewer" {
  project = var.project_id
  role    = "roles/recommender.iamViewer"
  member  = "serviceAccount:${local.function_sa_email}"
}

# Permission: read Cloud Audit Logs.
# Audit Logs are GCP's equivalent of CloudTrail. Always-on, no setup required.
# The privateLogViewer role can read Data Access logs in addition to Admin Activity.
resource "google_project_iam_member" "function_logs_viewer" {
  project = var.project_id
  role    = "roles/logging.privateLogViewer"
  member  = "serviceAccount:${local.function_sa_email}"
}

# Permission: write objects to the report bucket.
# Bucket-scoped binding rather than project-wide so the function only has
# write access to this specific bucket, not all GCS buckets in the project.
# This is least privilege done right.
resource "google_storage_bucket_iam_member" "function_report_writer" {
  bucket = google_storage_bucket.report.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${local.function_sa_email}"
}

# Permission: invoke Vertex AI models.
# aiplatform.user is the predefined role for invoking Vertex AI services
# (predict, generateContent, etc.). It does not allow creating models or training.
resource "google_project_iam_member" "function_vertex_user" {
  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${local.function_sa_email}"
}

# Permission: read secrets from Secret Manager (the Gmail OAuth refresh token).
# secretAccessor is a fine-grained role that only allows reading secret values.
# Scoped to the specific secret resource, not the whole project.
resource "google_secret_manager_secret_iam_member" "function_secret_reader" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.gmail_token.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${local.function_sa_email}"
}

# Permission: allow the Pub/Sub service to invoke the Cloud Function.
# When Cloud Functions 2nd gen has an event trigger from Pub/Sub, GCP creates
# an underlying Eventarc trigger which uses a Pub/Sub-pushed Cloud Run invocation.
# The Pub/Sub service account needs roles/run.invoker on the function (which is
# itself a Cloud Run service under the hood for 2nd gen functions).
# The role binding is on the function resource itself, configured later.
