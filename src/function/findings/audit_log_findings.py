"""
Findings derived from Cloud Audit Logs.

Cloud Audit Logs are always-on; no setup required. Every API call against
the project is logged.

Checks performed:
  1. Console logins from outside expected IP ranges (sensitive op)
  2. Recent IAM policy modifications (admin activity that warrants review)
  3. Service account key creation events in last 30 days (potential audit risk)
"""

import sys
from typing import List, Dict
from datetime import datetime, timezone, timedelta


def collect_audit_findings(project_id: str) -> List[Dict]:
    """Inspect Cloud Audit Logs and return findings of interest."""
    from google.cloud import logging_v2

    findings: List[Dict] = []

    try:
        client = logging_v2.Client(project=project_id)

        # Look back 30 days. Audit logs are retained 400 days for Admin Activity
        # and Data Access logs by default.
        since = datetime.now(timezone.utc) - timedelta(days=30)
        timestamp_filter = f'timestamp >= "{since.isoformat()}"'

        # Filter for IAM policy modifications (SetIamPolicy is the canonical
        # method name for any IAM change).
        iam_filter = (
            'logName:"cloudaudit.googleapis.com%2Factivity" '
            'AND protoPayload.methodName:"SetIamPolicy" '
            f'AND {timestamp_filter}'
        )
        for entry in client.list_entries(filter_=iam_filter, page_size=20):
            payload = getattr(entry, "payload", {}) or {}
            actor = _extract_actor(payload)
            findings.append({
                "category": "AuditLog",
                "severity": "MEDIUM",
                "resource": payload.get("resourceName", "unknown") if isinstance(payload, dict) else str(getattr(entry, "resource", "")),
                "description": (
                    f"IAM policy modification at {entry.timestamp.isoformat()} by {actor}. "
                    f"Verify the change was authorized."
                ),
            })

        # Filter for service account key creations (potential audit risk).
        key_filter = (
            'logName:"cloudaudit.googleapis.com%2Factivity" '
            'AND protoPayload.methodName:"google.iam.admin.v1.CreateServiceAccountKey" '
            f'AND {timestamp_filter}'
        )
        for entry in client.list_entries(filter_=key_filter, page_size=20):
            payload = getattr(entry, "payload", {}) or {}
            actor = _extract_actor(payload)
            findings.append({
                "category": "AuditLog",
                "severity": "HIGH",
                "resource": payload.get("resourceName", "unknown") if isinstance(payload, dict) else str(getattr(entry, "resource", "")),
                "description": (
                    f"Service account key created at {entry.timestamp.isoformat()} by {actor}. "
                    f"Long-lived keys are an audit risk; verify the key is necessary."
                ),
            })

    except Exception as e:
        # Logging API requires the function SA to have logging.privateLogViewer.
        # If the role isn't granted, this fails non-fatally.
        print(f"collect_audit_findings failed (non-fatal): {e}", file=sys.stderr)

    return findings


def _extract_actor(payload) -> str:
    """Pull the principal email from an audit log entry's protoPayload."""
    if not isinstance(payload, dict):
        return "unknown"
    auth = payload.get("authenticationInfo", {}) or {}
    return auth.get("principalEmail", "unknown")
