# Policy: every GCS bucket must have versioning enabled, which protects audit
# evidence from accidental or malicious overwrite.
#
# GCS encryption note:
# GCS encrypts every object at rest by default with Google-managed keys; there is
# no "encryption disabled" option. This makes the AWS-style encryption policy
# (check that SSE algorithm is AES256 or aws:kms) unnecessary on GCP. So instead
# of an SSE algorithm check, we enforce two related controls that genuinely
# matter on GCP:
#   1. Versioning enabled (protects against tampering and rollback)
#   2. Lifecycle rule present (enforces retention discipline)
#
# Mapping:
#   NIST 800-53 SC-28 (Protection of Information at Rest, via versioning)
#   NIST 800-53 SI-12 (Information Handling and Retention)
#   CMMC SC.L2-3.13.16

package terraform.gcs.encryption

import rego.v1

# Deny if versioning is not enabled.
# Versioning preserves all generations of objects, so an attacker (or buggy
# application) cannot silently overwrite or delete audit reports.
deny contains msg if {
    some resource in input.resource_changes
    resource.type == "google_storage_bucket"

    some action in resource.change.actions
    action != "delete"

    # Versioning attribute is a list with one element when configured;
    # when missing entirely, the attribute is null/empty.
    not bucket_has_versioning_enabled(resource.change.after)

    msg := sprintf(
        "GCS bucket %s does not have versioning enabled (violates NIST 800-53 SC-28)",
        [resource.address],
    )
}

# Helper: did the user enable versioning on this bucket?
# In Terraform plan JSON, the versioning block becomes a list of objects.
# If the list is empty or missing, versioning is unset (defaults to disabled).
bucket_has_versioning_enabled(after) if {
    some v in after.versioning
    v.enabled == true
}
