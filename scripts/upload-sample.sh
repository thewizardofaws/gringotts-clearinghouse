#!/bin/bash
# Upload sample JSON files to S3 for testing
# Usage: ./scripts/upload-sample.sh [filename]

set -e

AWS_REGION="us-west-2"
S3_BUCKET="gringotts-clearinghouse-dev-raw-641332413762"

# Default to sample-transaction.json if no argument provided
SAMPLE_FILE="${1:-sample-transaction.json}"
SAMPLE_PATH="sample-data/${SAMPLE_FILE}"

if [ ! -f "$SAMPLE_PATH" ]; then
    echo "Error: Sample file not found: $SAMPLE_PATH"
    echo "Available sample files:"
    ls -1 sample-data/*.json 2>/dev/null || echo "  (none found)"
    exit 1
fi

# Generate unique filename with timestamp
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
S3_KEY="incoming/${TIMESTAMP}-${SAMPLE_FILE}"

echo "Uploading $SAMPLE_PATH to s3://${S3_BUCKET}/${S3_KEY}"

aws s3 cp "$SAMPLE_PATH" "s3://${S3_BUCKET}/${S3_KEY}" \
    --region "$AWS_REGION" \
    --content-type "application/json"

echo ""
echo "✓ File uploaded successfully!"
echo ""
echo "S3 Location: s3://${S3_BUCKET}/${S3_KEY}"
echo ""
echo "The application should process this file within the next polling interval (default: 30 seconds)."
echo ""
echo "To watch the application logs:"
echo "  kubectl logs -f deployment/clearinghouse-app"
echo ""
echo "To check the processing status in the database:"
echo "  kubectl run db-check --rm -it --image=postgres:15-alpine --restart=Never -- \\"
echo "    sh -c 'apk add postgresql-client && PGPASSWORD=\"gringotts-secure-pass\" \\"
echo "    psql -h gringotts-clearinghouse-dev-postgres.ctiuycckkj5b.us-west-2.rds.amazonaws.com \\"
echo "    -U appuser -d clearinghouse -c \"SELECT id, file_name, status, processed_at FROM file_processing_log ORDER BY created_at DESC LIMIT 5;\"'"

