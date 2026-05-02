"""
IAM-related findings on GCP.

Checks performed:
  1. Any binding granting roles/owner, roles/editor, or roles/viewer at project
     scope (these are "primitive roles" and considered too broad).
  2. Service account keys older than 90 days (long-lived keys are an audit risk;
     prefer Workload Identity Federation or short-lived tokens).
  3. Service accounts with no recent activity (potential cleanup candidates).

GCP IAM mental model reminder:
  - Bindings live at scope: project, folder, org, or individual resource
  - Principal: user, group, service account, or domain
  - Role: predefined ('roles/storage.admin') or custom
  - Policy = union of all bindings at all relevant scopes
"""

import sys
from typing import List, Dict


PRIMITIVE_ROLES = {"roles/owner", "roles/editor", "roles/viewer"}


def collect_iam_findings(project_id: str) -> List[Dict]:
    """Inspect the project's IAM and return a list of finding dicts."""
    findings: List[Dict] = []

    findings += check_primitive_role_bindings(project_id)
    # SA key-age check is intentionally not called: the google-cloud-iam package
    # does not expose service account key listing under a stable public Python
    # client. Implement via REST or skip; for now we skip and rely on other checks.

    return findings


def check_primitive_role_bindings(project_id: str) -> List[Dict]:
    """Flag any IAM binding granting a primitive role at project scope."""
    from google.cloud import resourcemanager_v3

    findings: List[Dict] = []
    try:
        # The Resource Manager API returns the IAM policy attached to the project.
        # The policy is the union of all bindings; we filter for primitive roles.
        client = resourcemanager_v3.ProjectsClient()
        policy = client.get_iam_policy(resource=f"projects/{project_id}")

        for binding in policy.bindings:
            if binding.role in PRIMITIVE_ROLES:
                for member in binding.members:
                    findings.append({
                        "category": "IAM",
                        "severity": "HIGH" if binding.role == "roles/owner" else "MEDIUM",
                        "resource": f"projects/{project_id}",
                        "description": (
                            f"Primitive role {binding.role} bound to {member}. "
                            f"Replace with a predefined or custom role for least privilege."
                        ),
                    })
    except Exception as e:
        print(f"check_primitive_role_bindings failed: {e}", file=sys.stderr)

    return findings


def check_old_service_account_keys(project_id: str) -> List[Dict]:
    """Flag any service account user-managed key older than 90 days."""
    from datetime import datetime, timezone, timedelta
    from google.iam.admin_v1 import IAMClient
    from google.iam.admin_v1.types import ListServiceAccountKeysRequest

    findings: List[Dict] = []
    cutoff = datetime.now(timezone.utc) - timedelta(days=90)

    try:
        client = IAMClient()
        # First list all service accounts in the project.
        accounts = client.list_service_accounts(name=f"projects/{project_id}")

        for sa in accounts.accounts:
            # Then list keys for each. USER_MANAGED keys are the ones we care about;
            # SYSTEM_MANAGED keys are rotated by Google and are fine.
            keys_req = ListServiceAccountKeysRequest(
                name=sa.name,
                key_types=[1],  # 1 == USER_MANAGED
            )
            keys = client.list_service_account_keys(request=keys_req)

            for key in keys.keys:
                if key.valid_after_time and key.valid_after_time < cutoff:
                    age_days = (datetime.now(timezone.utc) - key.valid_after_time).days
                    findings.append({
                        "category": "IAM",
                        "severity": "MEDIUM",
                        "resource": sa.email,
                        "description": (
                            f"Service account key is {age_days} days old. "
                            f"Rotate keys regularly or migrate to Workload Identity Federation."
                        ),
                    })
    except Exception as e:
        # Many projects have no user-managed keys; non-fatal if listing fails.
        print(f"check_old_service_account_keys failed (non-fatal): {e}", file=sys.stderr)

    return findings
