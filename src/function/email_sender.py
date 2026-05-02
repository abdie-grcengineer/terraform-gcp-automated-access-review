"""
Send the access review report via the Gmail API.

OAuth flow used:
  - The function reads a JSON blob from Secret Manager containing
    {refresh_token, client_id, client_secret}
  - It exchanges the refresh token for a short-lived access token via the
    OAuth 2.0 token endpoint
  - It constructs a multipart MIME message with the narrative as body and
    the CSV as an attachment
  - It calls Gmail API users.messages.send with the base64-encoded raw message

The sender is the Gmail account that authorized the OAuth client during
gmail_oauth_setup.sh. The recipient comes from the RECIPIENT_EMAIL env var.

Why use Gmail API instead of SES-equivalent:
  - GCP has no native send-email service like SES
  - Decision logged in docs/design-decisions.md
  - Gmail API quota: free tier is 500 sends/day, plenty for monthly reports
"""

import base64
import json
import sys
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from email.mime.application import MIMEApplication


def send_report_email(
    gmail_secret_json: str,
    recipient: str,
    subject: str,
    narrative: str,
    csv_attachment: str,
    csv_filename: str,
) -> None:
    """Send a multipart email via Gmail API."""
    secret_data = json.loads(gmail_secret_json)
    access_token = _refresh_access_token(secret_data)

    message = _build_message(recipient, subject, narrative, csv_attachment, csv_filename)
    raw = base64.urlsafe_b64encode(message.as_bytes()).decode()

    _send_via_gmail_api(access_token, raw)


def _refresh_access_token(secret_data: dict) -> str:
    """Exchange the long-lived refresh token for a short-lived access token.

    Gmail API access tokens are valid for 1 hour. Refresh tokens are long-lived
    (until revoked by the user). We do a fresh exchange on every send rather
    than caching, because the function is short-lived anyway.
    """
    import requests

    response = requests.post(
        "https://oauth2.googleapis.com/token",
        data={
            "client_id":     secret_data["client_id"],
            "client_secret": secret_data["client_secret"],
            "refresh_token": secret_data["refresh_token"],
            "grant_type":    "refresh_token",
        },
        timeout=30,
    )
    response.raise_for_status()
    return response.json()["access_token"]


def _build_message(
    recipient: str,
    subject: str,
    narrative: str,
    csv_attachment: str,
    csv_filename: str,
) -> MIMEMultipart:
    """Construct the multipart MIME email."""
    message = MIMEMultipart()
    message["to"] = recipient
    message["subject"] = subject

    # Body: the narrative summary as plain text.
    body_part = MIMEText(narrative, "plain")
    message.attach(body_part)

    # Attachment: the CSV report.
    attachment = MIMEApplication(csv_attachment.encode("utf-8"), _subtype="csv")
    attachment.add_header("Content-Disposition", "attachment", filename=csv_filename)
    message.attach(attachment)

    return message


def _send_via_gmail_api(access_token: str, raw_message: str) -> None:
    """POST the raw message to Gmail's users.messages.send endpoint."""
    import requests

    url = "https://gmail.googleapis.com/gmail/v1/users/me/messages/send"
    headers = {
        "Authorization": f"Bearer {access_token}",
        "Content-Type":  "application/json",
    }
    body = {"raw": raw_message}

    response = requests.post(url, headers=headers, json=body, timeout=30)

    if not response.ok:
        # Surface the error body for debugging; Gmail API errors are usually
        # informative ("authentication failed", "invalid recipient", etc.).
        print(f"Gmail API error: {response.status_code} {response.text}", file=sys.stderr)
        response.raise_for_status()
