#!/bin/bash
# Quick deployment script for Kubernetes resources
# Usage: ./scripts/deploy.sh

set -e

echo "=== Deploying Clearinghouse Application ==="

# Get Terraform outputs
cd infrastructure/us-west-2/dev
ROLE_ARN=$(terraform output -raw app_service_account_role_arn 2>/dev/null || echo "")
RDS_ENDPOINT=$(terraform output -raw rds_endpoint 2>/dev/null || echo "")
S3_BUCKET=$(terraform output -raw s3_raw_bucket_name 2>/dev/null || echo "")
cd - > /dev/null

if [ -z "$ROLE_ARN" ]; then
  echo "ERROR: Could not get role ARN from Terraform. Make sure Terraform is applied."
  exit 1
fi

echo "Role ARN: $ROLE_ARN"
echo "RDS Endpoint: $RDS_ENDPOINT"
echo "S3 Bucket: $S3_BUCKET"

# Update service account with role ARN
echo ""
echo "=== Updating Service Account ==="
sed -i.bak "s|eks.amazonaws.com/role-arn:.*|eks.amazonaws.com/role-arn: ${ROLE_ARN}|" k8s/service-account.yaml
rm -f k8s/service-account.yaml.bak

# Deploy resources
echo ""
echo "=== Deploying Kubernetes Resources ==="
kubectl apply -f k8s/db-secret.yaml
kubectl apply -f k8s/service-account.yaml

echo ""
echo "=== Initializing Database Schema ==="
kubectl apply -f k8s/schema-init-job.yaml
echo "Waiting for schema initialization to complete..."
kubectl wait --for=condition=complete --timeout=300s job/clearinghouse-schema-init || {
  echo "Schema init job failed or timed out. Check logs:"
  kubectl logs job/clearinghouse-schema-init
  exit 1
}

echo ""
echo "=== Deploying Application ==="
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml

echo ""
echo "=== Waiting for Deployment ==="
kubectl rollout status deployment/clearinghouse-app --timeout=300s

echo ""
echo "=== Deployment Complete ==="
echo ""
echo "Check status with:"
echo "  kubectl get pods -l app=clearinghouse-app"
echo "  kubectl get svc clearinghouse-app"
echo "  kubectl logs -l app=clearinghouse-app"

