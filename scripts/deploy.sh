#!/bin/bash
# Automated deployment script for Kubernetes resources
# Usage: ./scripts/deploy.sh

set -euo pipefail

# Validate prerequisites
if ! command -v kubectl &> /dev/null; then
    echo "ERROR: kubectl is not installed or not in PATH" >&2
    exit 1
fi

if ! command -v terraform &> /dev/null; then
    echo "ERROR: Terraform is not installed or not in PATH" >&2
    exit 1
fi

echo "=== Deploying Clearinghouse Application ==="

# Get Terraform outputs
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TERRAFORM_DIR="${PROJECT_ROOT}/infrastructure/us-west-2/dev"

if [ ! -d "$TERRAFORM_DIR" ]; then
    echo "ERROR: Terraform directory not found: $TERRAFORM_DIR" >&2
    exit 1
fi

cd "$TERRAFORM_DIR"
ROLE_ARN=$(terraform output -raw app_service_account_role_arn 2>/dev/null || echo "")
RDS_ENDPOINT=$(terraform output -raw rds_endpoint 2>/dev/null || echo "")
S3_BUCKET=$(terraform output -raw s3_raw_bucket_name 2>/dev/null || echo "")
cd - > /dev/null

if [ -z "$ROLE_ARN" ]; then
    echo "ERROR: Could not retrieve service account role ARN from Terraform outputs" >&2
    echo "       Ensure Terraform has been applied: cd infrastructure/us-west-2/dev && terraform apply" >&2
    exit 1
fi

echo "Configuration:"
echo "  Role ARN: $ROLE_ARN"
echo "  RDS Endpoint: ${RDS_ENDPOINT:-not available}"
echo "  S3 Bucket: ${S3_BUCKET:-not available}"

# Update service account with role ARN
echo ""
echo "=== Updating Service Account ==="
SERVICE_ACCOUNT_FILE="${PROJECT_ROOT}/k8s/service-account.yaml"
if [ ! -f "$SERVICE_ACCOUNT_FILE" ]; then
    echo "ERROR: Service account file not found: $SERVICE_ACCOUNT_FILE" >&2
    exit 1
fi

# Create backup and update
sed -i.bak "s|eks.amazonaws.com/role-arn:.*|eks.amazonaws.com/role-arn: ${ROLE_ARN}|" "$SERVICE_ACCOUNT_FILE"
rm -f "${SERVICE_ACCOUNT_FILE}.bak"

# Deploy resources
echo ""
echo "=== Deploying Kubernetes Resources ==="
K8S_DIR="${PROJECT_ROOT}/k8s"

if ! kubectl apply -f "${K8S_DIR}/db-secret.yaml"; then
    echo "ERROR: Failed to deploy database secret" >&2
    exit 1
fi

if ! kubectl apply -f "${K8S_DIR}/service-account.yaml"; then
    echo "ERROR: Failed to deploy service account" >&2
    exit 1
fi

echo ""
echo "=== Initializing Database Schema ==="
if ! kubectl apply -f "${K8S_DIR}/schema-init-job.yaml"; then
    echo "ERROR: Failed to create schema initialization job" >&2
    exit 1
fi

echo "Waiting for schema initialization to complete..."
if ! kubectl wait --for=condition=complete --timeout=300s job/clearinghouse-schema-init; then
    echo "ERROR: Schema initialization job failed or timed out" >&2
    echo "Job logs:"
    kubectl logs job/clearinghouse-schema-init || true
    exit 1
fi

echo ""
echo "=== Deploying Application ==="
if ! kubectl apply -f "${K8S_DIR}/deployment.yaml"; then
    echo "ERROR: Failed to deploy application" >&2
    exit 1
fi

if ! kubectl apply -f "${K8S_DIR}/service.yaml"; then
    echo "ERROR: Failed to deploy service" >&2
    exit 1
fi

echo ""
echo "=== Waiting for Deployment Rollout ==="
if ! kubectl rollout status deployment/clearinghouse-app --timeout=300s; then
    echo "ERROR: Deployment rollout failed or timed out" >&2
    echo "Deployment status:"
    kubectl describe deployment clearinghouse-app || true
    exit 1
fi

echo ""
echo "=== Deployment Complete ==="
echo ""
echo "Verification commands:"
echo "  kubectl get pods -l app=clearinghouse-app"
echo "  kubectl get svc clearinghouse-app"
echo "  kubectl logs -f deployment/clearinghouse-app"

