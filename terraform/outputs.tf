# Outputs make Terraform's resource attributes available after apply.
# They are queried with `terraform output -raw NAME` and used by the bash
# scripts to find the resources they need to interact with.

output "report_bucket_name" {
  description = "Name of the GCS bucket storing access review reports"
  value       = google_storage_bucket.report.name
}

output "function_name" {
  description = "Name of the Cloud Function (use to invoke or query manually)"
  value       = google_cloudfunctions2_function.access_review.name
}

output "function_uri" {
  description = "Cloud Run URL for the underlying function service (Cloud Functions 2nd gen)"
  value       = google_cloudfunctions2_function.access_review.service_config[0].uri
}

output "trigger_topic" {
  description = "Pub/Sub topic that triggers the function (publish here to invoke manually)"
  value       = google_pubsub_topic.trigger.name
}

output "scheduler_job" {
  description = "Cloud Scheduler job name (use to manually run the schedule)"
  value       = google_cloud_scheduler_job.access_review.name
}

output "function_service_account" {
  description = "Service account the function runs as (for IAM debugging)"
  value       = google_service_account.function.email
}

output "secret_id" {
  description = "Secret Manager ID for the Gmail OAuth refresh token"
  value       = google_secret_manager_secret.gmail_token.secret_id
}

output "project_id" {
  description = "GCP project ID where everything is deployed"
  value       = var.project_id
}

output "region" {
  description = "Region where regional resources live"
  value       = var.region
}
