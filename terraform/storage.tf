# Cloud Storage bucket for storing access review reports.

# The report bucket itself.
# Notes on GCS:
# - Bucket names are globally unique across all of GCP.
# - Encryption at rest is automatic (Google-managed keys), no separate
#   resource needed.
# - Public access is blocked via uniform_bucket_level_access plus
#   public_access_prevention.
resource "google_storage_bucket" "report" {
  name = "${var.name_prefix}-reports-${data.google_project.current.number}"

  # Region for the bucket. Single-region is cheaper than multi-region and
  # adequate for a per-customer report archive.
  location = var.region

  # UBLA (Uniform Bucket-Level Access) is the modern, recommended setting.
  # It disables ACLs and enforces IAM-only access control.
  # When UBLA is true, you cannot accidentally make individual objects public
  # via legacy ACLs. All access goes through IAM bindings only.
  uniform_bucket_level_access = true

  # Belt-and-suspenders public access prevention.
  # "enforced" means even an explicit IAM binding to allUsers/allAuthenticatedUsers
  # is rejected. "inherited" inherits from org policy; "enforced" is stricter.
  public_access_prevention = "enforced"

  # Versioning protects against accidental overwrites and deletes.
  # Each PUT creates a new generation; old generations are retained until
  # the lifecycle rule expires them.
  versioning {
    enabled = true
  }

  # Lifecycle rule: delete reports older than var.report_retention_days.
  # Auto-cleanup prevents unbounded storage cost growth.
  # 90 days satisfies common federal retention minimums (FedRAMP Moderate, SOC 2).
  lifecycle_rule {
    condition {
      age = var.report_retention_days
    }
    action {
      type = "Delete"
    }
  }

  # Allow terraform destroy to delete the bucket even with objects in it.
  # In production this should be false (no, you cannot accidentally delete
  # your audit evidence). For the demo it is true so cleanup works cleanly.
  force_destroy = var.report_bucket_force_destroy

  # GCS encrypts every object at rest by default with Google-managed keys.
  # If we wanted customer-managed keys (CMEK), we'd add an encryption block.
  # For this project, default encryption is sufficient and maps to NIST SC-28.

  labels = {
    project   = var.name_prefix
    managedby = "terraform"
  }
}
