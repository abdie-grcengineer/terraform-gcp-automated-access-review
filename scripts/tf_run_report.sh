#!/bin/bash
# Manually trigger the access review function.
# We publish a message to the Pub/Sub topic that the Cloud Function listens on.
# The function fires within seconds; the report email arrives in 1-2 minutes.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$SCRIPT_DIR/../terraform"

if [ ! -d "$TERRAFORM_DIR/.terraform" ]; then
  echo "Error: $TERRAFORM_DIR is not initialized. Run 'terraform init' first."
  exit 1
fi

# Pull configuration from terraform outputs so this script stays in sync with
# whatever was actually deployed. No hardcoding the topic name.
TOPIC=$(terraform -chdir="$TERRAFORM_DIR" output -raw trigger_topic 2>/dev/null)
PROJECT_ID=$(terraform -chdir="$TERRAFORM_DIR" output -raw project_id 2>/dev/null)
FUNCTION_NAME=$(terraform -chdir="$TERRAFORM_DIR" output -raw function_name 2>/dev/null)
REGION=$(terraform -chdir="$TERRAFORM_DIR" output -raw region 2>/dev/null)

if [ -z "$TOPIC" ]; then
  echo "Error: trigger_topic output not found. Has 'terraform apply' run yet?"
  exit 1
fi

echo "Publishing trigger message to Pub/Sub topic: $TOPIC"
echo ""

# gcloud pubsub publish sends a message with the given payload to the topic.
# Cloud Function picks it up via its event_trigger and runs the handler.
gcloud pubsub topics publish "$TOPIC" \
  --project="$PROJECT_ID" \
  --message='{"trigger":"manual","source":"tf_run_report.sh"}'

echo ""
echo "Function invocation queued."
echo ""
echo "To watch the function logs:"
echo "  gcloud functions logs read $FUNCTION_NAME --region=$REGION --project=$PROJECT_ID --gen2 --limit=50"
echo ""
echo "Or open in console:"
echo "  https://console.cloud.google.com/functions/details/$REGION/$FUNCTION_NAME?project=$PROJECT_ID"
