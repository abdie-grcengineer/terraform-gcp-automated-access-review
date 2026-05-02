# Policy: every GCS bucket must use Uniform Bucket-Level Access (UBLA) and
# enforce public access prevention.
#
# Equivalent to the AWS s3_public_access.rego policy. GCS doesn't have the
# four-flag PAB model AWS S3 has; instead, UBLA + public_access_prevention
# together provide the equivalent protection.
#
# Mapping:
#   NIST 800-53 AC-3 (Access Enforcement), SC-7 (Boundary Protection)
#   CMMC AC.L2-3.1.3

package terraform.gcs.uniform_access

import rego.v1

# Deny if any GCS bucket has UBLA disabled.
# Without UBLA, legacy ACLs can be applied to individual objects, defeating
# bucket-level IAM enforcement. UBLA is the modern recommended setting and
# disables ACLs entirely.
deny contains msg if {
    some resource in input.resource_changes
    resource.type == "google_storage_bucket"

    some action in resource.change.actions
    action != "delete"

    not resource.change.after.uniform_bucket_level_access

    msg := sprintf(
        "GCS bucket %s has uniform_bucket_level_access disabled (violates NIST 800-53 AC-3)",
        [resource.address],
    )
}

# Deny if public access prevention is not "enforced".
# "inherited" means the bucket follows org policy, which may or may not
# prevent public access. "enforced" rejects all public IAM bindings regardless
# of org policy. For sensitive buckets, "enforced" is the only acceptable value.
deny contains msg if {
    some resource in input.resource_changes
    resource.type == "google_storage_bucket"

    some action in resource.change.actions
    action != "delete"

    resource.change.after.public_access_prevention != "enforced"

    msg := sprintf(
        "GCS bucket %s does not have public_access_prevention=enforced (violates NIST 800-53 SC-7)",
        [resource.address],
    )
}
