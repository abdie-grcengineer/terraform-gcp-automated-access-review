"""
Cloud Function entrypoint for the GCP automated access review.

Triggered by Pub/Sub messages on the configured topic. Cloud Scheduler
publishes one message per scheduled run; the script tf_run_report.sh
publishes one for manual invocations.

Workflow:
1. Collect findings from native GCP security services.
2. Generate a CSV report and write it to GCS.
3. Generate a narrative summary via Vertex AI Gemini.
4. Email the report to the configured recipient via Gmail API.

The handler MUST be named matching the entry_point in function.tf
(currently "main_handler"). Cloud Functions 2nd gen looks up this name
in main.py at deploy time.
"""

import base64
import csv
import io
import json
import os
import sys
from datetime import datetime, timezone

import functions_framework

from findings.iam_findings import collect_iam_findings
from findings.scc_findings import collect_scc_findings
from findings.audit_log_findings import collect_audit_findings
from narrative import generate_narrative
from reporting import build_csv
from email_sender import send_report_email


# Pub/Sub-triggered functions in 2nd gen receive a CloudEvent.
# The decorator wires the handler to the Cloud Functions runtime.
@functions_framework.cloud_event
def main_handler(cloud_event):
    """Entrypoint invoked by Pub/Sub via Eventarc."""
    project_id = os.environ["PROJECT_ID"]
    region = os.environ["REGION"]
    report_bucket = os.environ["REPORT_BUCKET"]
    recipient_email = os.environ["RECIPIENT_EMAIL"]
    gemini_model = os.environ["GEMINI_MODEL"]
    gmail_secret = os.environ["GMAIL_REFRESH_TOKEN"]

    print(f"Starting access review for project {project_id}", file=sys.stderr)

    # Decode the Pub/Sub message payload (base64-encoded JSON).
    # We don't actually use the message contents; we just need the trigger.
    message_data = {}
    if cloud_event and cloud_event.data:
        try:
            raw = cloud_event.data.get("message", {}).get("data", "")
            if raw:
                message_data = json.loads(base64.b64decode(raw).decode())
        except Exception as e:
            print(f"Could not decode Pub/Sub data (non-fatal): {e}", file=sys.stderr)

    print(f"Triggered by: {message_data.get('trigger', 'unknown')}", file=sys.stderr)

    # Collect findings from each source. Each function returns a list of
    # finding dicts with a common shape: {category, severity, resource, description}.
    findings = []
    findings += collect_iam_findings(project_id)
    findings += collect_scc_findings(project_id)
    findings += collect_audit_findings(project_id)

    print(f"Collected {len(findings)} total findings", file=sys.stderr)

    # Build the CSV report and upload to GCS.
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H-%M-%SZ")
    report_filename = f"access-review-{timestamp}.csv"
    csv_buffer = build_csv(findings)
    upload_to_gcs(report_bucket, report_filename, csv_buffer.getvalue())
    print(f"Report uploaded to gs://{report_bucket}/{report_filename}", file=sys.stderr)

    # Generate the narrative summary via Vertex AI Gemini.
    narrative = generate_narrative(findings, project_id, region, gemini_model)
    print("Narrative generated", file=sys.stderr)

    # Send the email via Gmail API.
    send_report_email(
        gmail_secret_json=gmail_secret,
        recipient=recipient_email,
        subject=f"GCP Access Review - {timestamp}",
        narrative=narrative,
        csv_attachment=csv_buffer.getvalue(),
        csv_filename=report_filename,
    )
    print(f"Email sent to {recipient_email}", file=sys.stderr)

    return {
        "statusCode": 200,
        "body": json.dumps({
            "findings_count": len(findings),
            "report": f"gs://{report_bucket}/{report_filename}",
        }),
    }


def upload_to_gcs(bucket_name: str, object_name: str, content: str) -> None:
    """Upload a CSV string to Cloud Storage. Imported lazily to keep cold start fast."""
    from google.cloud import storage

    client = storage.Client()
    bucket = client.bucket(bucket_name)
    blob = bucket.blob(object_name)
    blob.upload_from_string(content, content_type="text/csv")
