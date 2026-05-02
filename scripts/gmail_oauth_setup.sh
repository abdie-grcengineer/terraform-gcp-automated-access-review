#!/bin/bash
# One-time setup of Gmail API OAuth refresh token, written to Secret Manager.
#
# How OAuth works for Gmail:
#   1. You create an OAuth 2.0 client (Desktop type) in GCP Console
#   2. The client has an ID and a secret (the "client credentials")
#   3. A user (you) goes through a consent flow and authorizes the client
#      to access their Gmail
#   4. Google issues a refresh_token (long-lived) and access_token (short-lived)
#   5. The refresh_token can be exchanged for new access_tokens whenever needed
#
# We store ONLY the refresh_token in Secret Manager. The Cloud Function uses
# the refresh_token at runtime to obtain access_tokens via the OAuth token
# endpoint, then calls Gmail API with the access_token.
#
# Run this once. Re-run only if you revoke the refresh token (Gmail will issue
# a new one on next consent flow).

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$SCRIPT_DIR/../terraform"

# Pull config from terraform outputs.
PROJECT_ID=$(terraform -chdir="$TERRAFORM_DIR" output -raw project_id 2>/dev/null)
SECRET_ID=$(terraform -chdir="$TERRAFORM_DIR" output -raw secret_id 2>/dev/null)

if [ -z "$PROJECT_ID" ] || [ -z "$SECRET_ID" ]; then
  echo "Error: terraform outputs not available. Run terraform apply first."
  exit 1
fi

cat <<EOF

=== Gmail OAuth Setup ===

Step 1: Create an OAuth 2.0 client in GCP Console
   1. Open: https://console.cloud.google.com/apis/credentials?project=$PROJECT_ID
   2. Click 'Create Credentials' -> 'OAuth client ID'
   3. If prompted, configure the OAuth consent screen first:
      - User type: External (for personal Gmail) or Internal (Workspace)
      - App name: 'GCP Access Review'
      - User support email: your email
      - Scopes: add 'https://www.googleapis.com/auth/gmail.send'
      - Test users: add your Gmail address
   4. Application type: Desktop app
   5. Name: 'GCP Access Review CLI'
   6. Click Create. Note the Client ID and Client Secret.

Step 2: When ready, paste the Client ID and Client Secret below.

EOF

read -p "OAuth Client ID: " CLIENT_ID
read -p "OAuth Client Secret: " CLIENT_SECRET

cat <<EOF

Step 3: Run the OAuth consent flow.
We will open a URL in your browser. Sign in with the Gmail account that will
SEND the report emails. Approve the gmail.send scope. You will be redirected
to localhost (which won't load); copy the entire URL from your browser.

EOF

# Build the auth URL with offline access (required to get refresh_token)
# and prompt=consent (required to force refresh_token issuance even on re-auth).
SCOPE="https://www.googleapis.com/auth/gmail.send"
REDIRECT="http://localhost:8080"
AUTH_URL="https://accounts.google.com/o/oauth2/v2/auth?response_type=code&client_id=${CLIENT_ID}&redirect_uri=${REDIRECT}&scope=${SCOPE}&access_type=offline&prompt=consent"

echo "Opening browser to:"
echo "  $AUTH_URL"
echo ""

# macOS uses 'open'; Linux uses 'xdg-open'
if command -v open >/dev/null 2>&1; then
  open "$AUTH_URL"
elif command -v xdg-open >/dev/null 2>&1; then
  xdg-open "$AUTH_URL"
else
  echo "(open the URL above manually in your browser)"
fi

echo ""
read -p "Paste the FULL URL you were redirected to: " REDIRECT_URL

# Extract the code parameter from the redirect URL
AUTH_CODE=$(echo "$REDIRECT_URL" | sed -E 's/.*[?&]code=([^&]+).*/\1/')
if [ -z "$AUTH_CODE" ] || [ "$AUTH_CODE" = "$REDIRECT_URL" ]; then
  echo "Error: could not extract code= from URL. Run the script again."
  exit 1
fi

echo ""
echo "Step 4: Exchanging auth code for refresh token..."

# Exchange the auth code for tokens
RESPONSE=$(curl -s --request POST \
  --url https://oauth2.googleapis.com/token \
  --header 'content-type: application/x-www-form-urlencoded' \
  --data "code=${AUTH_CODE}&client_id=${CLIENT_ID}&client_secret=${CLIENT_SECRET}&redirect_uri=${REDIRECT}&grant_type=authorization_code")

REFRESH_TOKEN=$(echo "$RESPONSE" | python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('refresh_token',''))")

if [ -z "$REFRESH_TOKEN" ]; then
  echo "Error: no refresh_token in response."
  echo "Response: $RESPONSE"
  exit 1
fi

echo "Refresh token obtained."

echo ""
echo "Step 5: Writing refresh token to Secret Manager..."

# We store a JSON object with all three values (refresh_token, client_id, client_secret)
# because the Cloud Function needs all three to mint access tokens.
SECRET_PAYLOAD=$(python3 -c "
import json
print(json.dumps({
    'refresh_token': '$REFRESH_TOKEN',
    'client_id':     '$CLIENT_ID',
    'client_secret': '$CLIENT_SECRET'
}))
")

echo "$SECRET_PAYLOAD" | gcloud secrets versions add "$SECRET_ID" \
  --project="$PROJECT_ID" \
  --data-file=-

echo ""
echo "Done. The Cloud Function will pick up the new secret version on next invocation."
echo ""
echo "To verify the secret is readable by the function:"
echo "  gcloud secrets versions access latest --secret=$SECRET_ID --project=$PROJECT_ID"
