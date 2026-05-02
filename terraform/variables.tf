# Input variables for the GCP Automated Access Review stack.
# These are the inputs Terraform needs from the operator.
# Required variables (no default) must be supplied via terraform.tfvars
# or via TF_VAR_<name> environment variables (which is how CI passes secrets).

# The GCP project where everything gets deployed.
# In GCP, every resource lives in exactly one project (similar to AWS account).
variable "project_id" {
  description = "GCP project ID where all resources will be created"
  type        = string
}

# The recipient email for the report.
# In CI, this comes from the RECIPIENT_EMAIL GitHub secret via TF_VAR_recipient_email.
# Locally, set it in terraform.tfvars (which is gitignored).
variable "recipient_email" {
  description = "Email address that receives the access review report"
  type        = string
}

# Default region for regional resources (Cloud Function, Scheduler, etc.)
# us-central1 is the default because Vertex AI Gemini 2.0 Flash is available there
# and it is GCP's most feature-complete region.
variable "region" {
  description = "Default GCP region for regional resources"
  type        = string
  default     = "us-central1"
}

# Cloud Scheduler uses standard cron syntax (NOT AWS rate(...) syntax).
# "0 8 1 * *" = at 08:00 UTC on the 1st of every month.
# Equivalent to AWS's "rate(30 days)" but more precise about timing.
variable "schedule_cron" {
  description = "Cron expression for the access review schedule"
  type        = string
  default     = "0 8 1 * *"
}

# The timezone for the schedule. Cloud Scheduler honors IANA timezone names.
# "Etc/UTC" keeps the schedule timezone-agnostic for global deployments.
variable "schedule_timezone" {
  description = "IANA timezone for the Cloud Scheduler job"
  type        = string
  default     = "Etc/UTC"
}

# Vertex AI Gemini model identifier.
# Format: "<model-name>" used in vertexai.GenerativeModel("...").
# Flash is right-sized for summarization; Pro and Ultra would be over-engineering.
variable "gemini_model" {
  description = "Vertex AI Gemini model used for the narrative summary"
  type        = string
  # gemini-1.5-flash-002 is GA in us-central1 and accessible without approval.
  # gemini-2.0-flash-001 returns 404 in fresh projects until access is granted
  # via Vertex Model Garden. 1.5 Flash is sufficient for summarization.
  default = "gemini-1.5-flash-002"
}

# Used to prefix all resource names so they're identifiable in the GCP console.
# Equivalent to ${var.name_prefix} in the AWS Terraform.
variable "name_prefix" {
  description = "Prefix applied to resource names"
  type        = string
  default     = "gcp-access-review"
}

# Force-destroy the report bucket on terraform destroy even if it contains objects.
# Set to true for the demo so 'terraform destroy' works without manual cleanup.
# In production this should be false; you don't want destroy to delete audit evidence.
variable "report_bucket_force_destroy" {
  description = "Allow terraform destroy to delete the report bucket even if non-empty"
  type        = bool
  default     = true
}

# How long to retain reports in the bucket before lifecycle deletes them.
# 90 days satisfies most federal compliance retention minimums (FedRAMP, SOC 2).
variable "report_retention_days" {
  description = "Number of days to retain CSV reports before lifecycle deletes them"
  type        = number
  default     = 90
}
