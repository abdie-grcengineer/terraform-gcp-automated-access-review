"""
Generate the executive-summary narrative for the report using Vertex AI Gemini.

Why Gemini over Claude on Vertex (decision logged in docs/design-decisions.md):
  - Native to GCP, no model access approval queue
  - Right-sized for summarization (Flash is the cheap, fast tier)
  - Removes external dependency on Anthropic approval

The function:
  1. Initializes the Vertex AI client for the configured project + region
  2. Builds a prompt summarizing the findings count by severity and category
  3. Calls Gemini with a directive to produce an executive summary
  4. Returns the narrative as a plain text string
"""

import sys
from collections import Counter
from typing import List, Dict


def generate_narrative(findings: List[Dict], project_id: str, region: str, model: str) -> str:
    """Call Gemini and return the narrative summary."""
    try:
        # google-genai is the unified SDK for Gemini and other Google models.
        # vertexai=True tells it to use Vertex AI endpoints (which use IAM/SA auth
        # via the function's service account) rather than AI Studio (API key auth).
        from google import genai

        client = genai.Client(vertexai=True, project=project_id, location=region)

        prompt = _build_prompt(findings)

        response = client.models.generate_content(
            model=model,
            contents=prompt,
        )

        return (response.text or "").strip()

    except Exception as e:
        # If Vertex fails (model access not enabled, region unsupported, quota),
        # fall back to a basic non-AI summary so the report still ships.
        print(f"Vertex AI generation failed, using fallback summary: {e}", file=sys.stderr)
        return _fallback_summary(findings)


def _build_prompt(findings: List[Dict]) -> str:
    """Compose the prompt for Gemini, including findings statistics."""
    # Count findings by category and severity.
    by_category = Counter(f["category"] for f in findings)
    by_severity = Counter(f["severity"] for f in findings)

    # Surface the top 10 findings to give the model concrete examples.
    top_findings = findings[:10]
    top_findings_text = "\n".join(
        f"- [{f['severity']}] {f['category']}: {f['description'][:200]}"
        for f in top_findings
    )

    return f"""You are a GRC engineer summarizing the results of an automated GCP access review for an executive audience. Be direct, specific, and avoid jargon.

Total findings: {len(findings)}
By category: {dict(by_category)}
By severity: {dict(by_severity)}

Top findings:
{top_findings_text}

Write a 3-paragraph executive summary that includes:
1. The overall security posture (good, mixed, concerning).
2. The 2-3 most pressing issues that need attention.
3. Recommended next steps for the security team.

Do not include preamble or sign-off; produce only the body text."""


def _fallback_summary(findings: List[Dict]) -> str:
    """Plain-text summary when Gemini is unavailable. Better than no narrative."""
    by_severity = Counter(f["severity"] for f in findings)
    by_category = Counter(f["category"] for f in findings)

    return (
        f"GCP Access Review summary (AI narrative unavailable, basic counts only).\n\n"
        f"Total findings: {len(findings)}.\n"
        f"By severity: {dict(by_severity)}.\n"
        f"By category: {dict(by_category)}.\n\n"
        f"Review the attached CSV for full details."
    )
