# Policy: prevent anyone (especially CI) from binding roles/owner to a service
# account or user via Terraform. roles/owner is GCP's "primitive role" that
# grants near-admin access; granting it via IaC is almost always a mistake.
#
# This is the GCP equivalent of the AWS iam_no_wildcard.rego policy.
# AWS uses inline policies with Action/Resource wildcards as the over-permissive
# pattern; GCP uses role bindings, and the most common over-permissive pattern
# is granting the primitive roles (owner, editor, viewer) at project scope.
#
# Mapping:
#   NIST 800-53 AC-6 (Least Privilege)
#   CMMC AC.L2-3.1.5

package terraform.iam.no_owner

import rego.v1

# Roles considered too broad to grant via Terraform.
# Owner, editor, and viewer are "primitive roles" predating GCP's IAM redesign.
# Modern GCP guidance: never grant primitive roles. Use predefined or custom
# roles instead. We block all three primitive roles in this policy.
forbidden_roles := {"roles/owner", "roles/editor", "roles/viewer"}

# Resource types we evaluate. GCP IAM bindings can attach at multiple scopes
# (project, folder, org, individual resource). We check the project-level ones
# here because that's where this project creates bindings.
project_iam_resource_types := {
    "google_project_iam_member",
    "google_project_iam_binding",
}

deny contains msg if {
    some resource in input.resource_changes

    # Only check IAM resource types we care about.
    project_iam_resource_types[resource.type]

    # Skip resources being deleted.
    some action in resource.change.actions
    action != "delete"

    # If the role being granted is in our forbidden set, deny.
    forbidden_roles[resource.change.after.role]

    msg := sprintf(
        "IAM binding %s grants forbidden primitive role %s (violates NIST 800-53 AC-6 least privilege)",
        [resource.address, resource.change.after.role],
    )
}
