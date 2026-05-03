"""
Findings from Security Command Center (SCC).

SCC is a single aggregation point for security findings across the project.
It surfaces misconfigurations, vulnerabilities, and threats from various
GCP security services.

Note on SCC tiers:
  - Standard tier: free, includes Security Health Analytics findings
  - Premium tier: paid, includes Event Threat Detection, etc.
This code reads whatever findings are available; if SCC is not enabled or has
no findings, we return an empty list.
"""

import sys
from typing import List, Dict


def collect_scc_findings(project_id: str) -> List[Dict]:
    """Pull Security Command Center findings and return as a list of finding dicts."""
    from google.cloud import securitycenter

    findings: List[Dict] = []

    try:
        client = securitycenter.SecurityCenterClient()

        # SCC findings live under sources within an org or project. For project-level
        # SCC (which most non-org users have), the parent resource is the project.
        # Filter to ACTIVE findings only; ignore MUTED and INACTIVE.
        parent = f"projects/{project_id}/sources/-"  # '-' = all sources
        request = {
            "parent": parent,
            "filter": 'state="ACTIVE"',
            "page_size": 100,  # 100 findings is plenty for a digest report
        }

        for result in client.list_findings(request=request):
            finding = result.finding
            findings.append({
                "category": "SCC",
                "severity": _normalize_severity(finding.severity.name),
                "resource": finding.resource_name,
                "description": (
                    f"{finding.category}: {finding.description or finding.event_time}"
                ),
            })

    except Exception as e:
        # Many projects don't have SCC enabled at the project level (it's typically
        # an org-level service). Non-fatal: we log and return what we have.
        print(f"collect_scc_findings failed (non-fatal): {e}", file=sys.stderr)

    return findings


def _normalize_severity(scc_severity: str) -> str:
    """Map SCC severity enum names to our common severity scale."""
    mapping = {
        "CRITICAL": "CRITICAL",
        "HIGH": "HIGH",
        "MEDIUM": "MEDIUM",
        "LOW": "LOW",
        "SEVERITY_UNSPECIFIED": "INFO",
    }
    return mapping.get(scc_severity, "INFO")
