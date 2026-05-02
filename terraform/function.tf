# The Cloud Function (compute), the trigger pipeline (Cloud Scheduler -> Pub/Sub
# -> Function), and the source code packaging.
#
# Cloud Functions 2nd gen is the GCP equivalent of AWS Lambda. Differences worth
# knowing:
# - 2nd gen runs on Cloud Run under the hood, so it inherits Cloud Run's runtime
#   characteristics (longer timeouts up to 1 hour, more memory).
# - Source code must be zipped and uploaded to a GCS staging bucket (Lambda lets
#   you upload the zip directly with the function).
# - Triggers are configured separately (HTTP, Pub/Sub via Eventarc, etc.).

# Step 1: Zip the function source directory at plan time.
# Same pattern as the AWS version's archive_file. Saves us from having to
# build the zip in CI; Terraform handles it.
data "archive_file" "function_source" {
  type        = "zip"
  source_dir  = "${path.module}/../src/function"
  output_path = "${path.module}/function_source.zip"
}

# Step 2: Upload the zip to a GCS staging bucket.
# Cloud Functions 2nd gen reads source from GCS, not from your local disk.
# We reuse the report bucket as the staging area to keep resource count down;
# in production you might want a separate staging bucket for cleanliness.
resource "google_storage_bucket_object" "function_source" {
  name   = "function-source/${data.archive_file.function_source.output_md5}.zip"
  bucket = google_storage_bucket.report.name
  source = data.archive_file.function_source.output_path

  # Including the MD5 hash in the object name means a code change uploads to a
  # new object name, which forces the function to redeploy (because the
  # function references this specific object name).
}

# Step 3: Create the Pub/Sub topic that Cloud Scheduler publishes to.
# This is the "fan-in" point. Other event sources (alerts, manual triggers via
# gcloud pubsub publish) can publish to the same topic to invoke the function.
resource "google_pubsub_topic" "trigger" {
  name    = "${var.name_prefix}-trigger"
  project = var.project_id
}

# Step 4: Create the Cloud Function 2nd gen.
# Note the resource type: google_cloudfunctions2_function (with the "2"). The
# v1 resource is google_cloudfunctions_function and is being deprecated.
resource "google_cloudfunctions2_function" "access_review" {
  name        = "${var.name_prefix}-function"
  location    = var.region
  project     = var.project_id
  description = "Scheduled GCP access review with AI-generated narrative summary"

  # build_config: how Cloud Build builds the function container.
  # Cloud Functions 2nd gen uses Cloud Build under the hood (you can see the
  # build artifacts as Cloud Run revisions in the console).
  build_config {
    runtime     = "python312"
    entry_point = "main_handler" # the function name in main.py to call

    source {
      storage_source {
        bucket = google_storage_bucket.report.name
        object = google_storage_bucket_object.function_source.name
      }
    }
  }

  # service_config: runtime behavior of the deployed function.
  service_config {
    max_instance_count = 3 # Don't autoscale crazy; this runs ~once a month
    available_memory   = "512M"
    timeout_seconds    = 540 # 9 minutes; 2nd gen max is 60 minutes for HTTP, 9 for event-driven
    ingress_settings   = "ALLOW_INTERNAL_ONLY"

    # Run as our dedicated service account, not the default Compute SA.
    service_account_email = local.function_sa_email

    # Environment variables passed to the Python code.
    # The function reads these from os.environ at runtime.
    environment_variables = {
      PROJECT_ID      = var.project_id
      REGION          = var.region
      REPORT_BUCKET   = google_storage_bucket.report.name
      RECIPIENT_EMAIL = var.recipient_email
      GEMINI_MODEL    = var.gemini_model
    }

    # Reference the Gmail refresh token secret as an env var.
    # The function code reads os.environ["GMAIL_REFRESH_TOKEN"] at runtime;
    # GCP injects the latest secret version automatically.
    secret_environment_variables {
      key        = "GMAIL_REFRESH_TOKEN"
      project_id = data.google_project.current.number
      secret     = google_secret_manager_secret.gmail_token.secret_id
      version    = "latest"
    }
  }

  # event_trigger: what invokes the function.
  # google.cloud.pubsub.topic.v1.messagePublished fires when a message is
  # published to the configured Pub/Sub topic. Cloud Scheduler publishes to
  # that topic on the configured cron schedule.
  event_trigger {
    trigger_region = var.region
    event_type     = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic   = google_pubsub_topic.trigger.id
    retry_policy   = "RETRY_POLICY_RETRY"
  }

  depends_on = [
    google_project_iam_member.function_iam_reader,
    google_project_iam_member.function_asset_viewer,
    google_project_iam_member.function_scc_viewer,
    google_project_iam_member.function_recommender_viewer,
    google_project_iam_member.function_logs_viewer,
    google_storage_bucket_iam_member.function_report_writer,
    google_project_iam_member.function_vertex_user,
    google_secret_manager_secret_iam_member.function_secret_reader,
  ]
}

# Step 5: Cloud Scheduler job that publishes to the Pub/Sub topic on schedule.
# This is the GCP equivalent of an EventBridge scheduled rule.
resource "google_cloud_scheduler_job" "access_review" {
  name        = "${var.name_prefix}-schedule"
  description = "Triggers the access review function every 30 days"
  schedule    = var.schedule_cron
  time_zone   = var.schedule_timezone
  project     = var.project_id
  region      = var.region

  # Publish a Pub/Sub message; the topic's only subscriber is our function.
  pubsub_target {
    topic_name = google_pubsub_topic.trigger.id
    # The data payload is empty for our use case; the function ignores message
    # contents and just runs its workflow when triggered.
    data = base64encode(jsonencode({ trigger = "scheduled" }))
  }
}
