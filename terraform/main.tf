# Terraform's spine: required versions, providers, backend, default project
# context, and lookups for project-level data we need elsewhere.

terraform {
  # Pin Terraform to a recent stable version. 1.10+ has S3-native locking
  # and improved GCS backend behavior.
  required_version = ">= 1.10.0"

  # GCS backend stores Terraform state in a Cloud Storage bucket.
  # The bucket itself was created by scripts/bootstrap_gcp.sh because of the
  # bootstrap problem: you cannot Terraform-create the bucket that holds
  # Terraform state. Same idea as the S3 backend pattern in the AWS version.
  #
  # GCS backend has native locking via object generation numbers. There is no
  # equivalent flag to AWS use_lockfile = true; locking is always on by default.
  backend "gcs" {
    bucket = "abdi-tf-state-gcp-1777695410"
    prefix = "gcp-access-review"
  }

  # Providers are plugins that translate Terraform's resource declarations into
  # API calls. The hashicorp/google provider talks to the Google Cloud APIs.
  # The archive provider (same one we used in AWS) zips local files for upload.
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

# Configure the Google Cloud provider.
# The project, region, and zone passed here become the defaults for every
# google_* resource that doesn't explicitly set them. AWS uses default_tags
# for similar provider-level defaults; GCP uses provider-level project/region.
provider "google" {
  project = var.project_id
  region  = var.region
}

# Pull metadata about the project for use in IAM bindings and other places.
# Equivalent to AWS's data.aws_caller_identity.current. The project number is
# different from the project ID and is required for some resource ARNs in GCP
# (especially Workload Identity Federation principals).
data "google_project" "current" {
  project_id = var.project_id
}

# Locals are computed values used elsewhere in the configuration.
# Putting them in main.tf keeps them in one place.
locals {
  # The full email of the function's service account. Used in IAM bindings,
  # Cloud Function configuration, and Pub/Sub trigger config.
  # Note: GCP service accounts are identified by email, not ARN like AWS roles.
  function_sa_email = google_service_account.function.email
}
