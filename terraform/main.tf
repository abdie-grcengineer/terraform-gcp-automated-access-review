# Terraform's spine: required versions, providers, backend, default project
# context, and lookups for project-level data we need elsewhere.

terraform {
  # Pin Terraform to a recent stable version. 1.10+ has improved GCS backend
  # behavior and consistent locking semantics.
  required_version = ">= 1.10.0"

  # GCS backend stores Terraform state in a Cloud Storage bucket.
  # The bucket itself was created by scripts/bootstrap_gcp.sh because of the
  # bootstrap problem: you cannot Terraform-create the bucket that holds
  # Terraform state.
  #
  # GCS backend has native locking via object generation numbers; locking is
  # always on by default, no flag needed.
  backend "gcs" {
    bucket = "abdi-tf-state-gcp-1777695410"
    prefix = "gcp-access-review"
  }

  # Providers are plugins that translate Terraform's resource declarations into
  # API calls. The hashicorp/google provider talks to the Google Cloud APIs.
  # The archive provider zips local files for upload (used in function.tf).
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
# The project and region passed here become the defaults for every google_*
# resource that doesn't explicitly set them.
provider "google" {
  project = var.project_id
  region  = var.region
}

# Pull metadata about the project for use in IAM bindings and other places.
# The project number is different from the project ID and is required for some
# resource identifiers in GCP, especially Workload Identity Federation principals.
data "google_project" "current" {
  project_id = var.project_id
}

# Locals are computed values used elsewhere in the configuration.
# Putting them in main.tf keeps them in one place.
locals {
  # The full email of the function's service account. Used in IAM bindings,
  # Cloud Function configuration, and Pub/Sub trigger config.
  # GCP service accounts are identified by email, not by ARN.
  function_sa_email = google_service_account.function.email
}
