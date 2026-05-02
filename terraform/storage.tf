# Cloud Storage bucket for storing access review reports.
# This is the GCP equivalent of the S3 bucket from the AWS version.

# The report bucket itself.
# Key differences from AWS S3:
# - GCS bucket names are globally unique across all of GCP, same as S3.
# - Encryption at rest is automatic (Google-managed keys), no separate
#   resource needed (unlike aws_s3_bucket_server_side_encryption_configuration).
# - Public access is blocked via a single resource flag (uniform_bucket_level_access)
#   plus public_access_prevention rather than four separate flags like AWS PAB.
resource "google_storage_bucket" "report" {
  name = "${var.name_prefix}-reports-${data.google_project.current.number}"

  # Region for the bucket. Single-region is cheaper than multi-region and
  # adequate for a per-customer report archive.
  location = var.region

  # UBLA (Uniform Bucket-Level Access) is the modern, recommended setting.
  # It disables ACLs and enforces IAM-only access control. This is the GCP
  # equivalent of the four AWS public access block flags.
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
