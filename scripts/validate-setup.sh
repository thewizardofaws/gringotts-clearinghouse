#!/bin/bash
# Validation script for IRSA and deployment setup
# Usage: ./scripts/validate-setup.sh

set -e

echo "=========================================="
echo "IRSA and Deployment Setup Validation"
echo "=========================================="
echo ""

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT/infrastructure/us-west-2/dev" || exit 1

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

ERRORS=0
WARNINGS=0

# Function to check status
check_pass() {
    echo -e "${GREEN}✓${NC} $1"
}

check_fail() {
    echo -e "${RED}✗${NC} $1"
    ((ERRORS++))
}

check_warn() {
    echo -e "${YELLOW}⚠${NC} $1"
    ((WARNINGS++))
}

echo "1. IRSA Trust Check"
echo "-------------------"

# Check if EKS cluster exists and get OIDC issuer
EKS_CLUSTER_NAME="gringotts-clearinghouse-dev-eks"
OIDC_ISSUER=$(aws eks describe-cluster --name "$EKS_CLUSTER_NAME" --region us-west-2 \
    --query 'cluster.identity.oidc.issuer' --output text 2>/dev/null || echo "")

if [ -z "$OIDC_ISSUER" ]; then
    check_fail "Cannot retrieve EKS cluster OIDC issuer"
else
    check_pass "EKS cluster OIDC issuer found: $OIDC_ISSUER"
fi

# Check if irsa.tf references the correct OIDC issuer
IRSA_FILE="../irsa.tf"
if [ ! -f "$IRSA_FILE" ]; then
    IRSA_FILE="irsa.tf"
fi
if grep -q "aws_eks_cluster.this.identity" "$IRSA_FILE" 2>/dev/null; then
    check_pass "irsa.tf correctly references aws_eks_cluster.this.identity"
else
    check_fail "irsa.tf does not reference EKS cluster OIDC issuer correctly"
fi

# Check service account namespace and name
SA_FILE="$PROJECT_ROOT/k8s/service-account.yaml"
SA_NAMESPACE=$(grep "^  namespace:" "$SA_FILE" 2>/dev/null | awk '{print $2}' | tr -d ' ' || echo "")
SA_NAME=$(grep "^  name:" "$SA_FILE" 2>/dev/null | awk '{print $2}' || echo "")

if [ "$SA_NAMESPACE" = "default" ] && [ "$SA_NAME" = "clearinghouse-app" ]; then
    check_pass "Service account namespace (default) and name (clearinghouse-app) match"
else
    check_fail "Service account namespace or name mismatch. Found: namespace=$SA_NAMESPACE, name=$SA_NAME"
fi

# Check trust policy condition
if grep -q "system:serviceaccount:default:clearinghouse-app" "$PROJECT_ROOT/infrastructure/us-west-2/dev/irsa.tf"; then
    check_pass "Trust policy condition matches service account (system:serviceaccount:default:clearinghouse-app)"
else
    check_fail "Trust policy condition does not match service account"
fi

# Check OIDC provider URL format in trust policy
IRSA_FILE="$PROJECT_ROOT/infrastructure/us-west-2/dev/irsa.tf"
if grep -q "aws_iam_openid_connect_provider.eks.url" "$IRSA_FILE" 2>/dev/null; then
    check_pass "Trust policy uses OIDC provider URL variable correctly"
else
    check_warn "Could not verify OIDC provider URL format in trust policy"
fi

echo ""
echo "2. Dependency Graph Check"
echo "-------------------------"

# Check if ECR and IRSA resources are in Terraform files
if [ -f "$PROJECT_ROOT/infrastructure/us-west-2/dev/ecr.tf" ]; then
    check_pass "ecr.tf exists"
else
    check_fail "ecr.tf does not exist"
fi

if [ -f "$PROJECT_ROOT/infrastructure/us-west-2/dev/irsa.tf" ]; then
    check_pass "irsa.tf exists"
else
    check_fail "irsa.tf does not exist"
fi

# Check if EKS cluster is in state
if terraform state list 2>/dev/null | grep -q "aws_eks_cluster.this"; then
    check_pass "EKS cluster is in Terraform state"
    
    # Check if OIDC issuer is available in cluster
    CLUSTER_OIDC=$(terraform state show aws_eks_cluster.this 2>/dev/null | grep "oidc" | head -1 || echo "")
    if [ -n "$CLUSTER_OIDC" ]; then
        check_pass "EKS cluster has OIDC issuer configured"
    else
        check_warn "EKS cluster OIDC issuer not found in state (may need refresh)"
    fi
else
    check_fail "EKS cluster not found in Terraform state"
fi

# Check if OIDC provider will be created
if terraform plan -out=/dev/null 2>&1 | grep -q "aws_iam_openid_connect_provider.eks"; then
    check_pass "OIDC provider will be created by Terraform"
elif terraform state list 2>/dev/null | grep -q "aws_iam_openid_connect_provider.eks"; then
    check_pass "OIDC provider already exists in Terraform state"
else
    check_warn "OIDC provider not found in plan or state (may need terraform apply)"
fi

# Check dependencies
if grep -q "aws_eks_cluster.this" "$PROJECT_ROOT/infrastructure/us-west-2/dev/irsa.tf"; then
    check_pass "irsa.tf depends on aws_eks_cluster.this"
else
    check_fail "irsa.tf missing dependency on aws_eks_cluster.this"
fi

if grep -q "aws_s3_bucket.raw" "$PROJECT_ROOT/infrastructure/us-west-2/dev/irsa.tf"; then
    check_pass "irsa.tf references aws_s3_bucket.raw for S3 policy"
else
    check_fail "irsa.tf missing reference to aws_s3_bucket.raw"
fi

echo ""
echo "3. Manifest Variable Check"
echo "--------------------------"

# Get actual values from Terraform
RDS_ENDPOINT=$(terraform output -raw rds_endpoint 2>/dev/null || echo "")
S3_BUCKET=$(terraform output -raw s3_raw_bucket_name 2>/dev/null || echo "")
AWS_REGION="us-west-2"

# Check deployment.yaml
DEPLOYMENT_FILE="$PROJECT_ROOT/k8s/deployment.yaml"

if [ ! -f "$DEPLOYMENT_FILE" ]; then
    check_fail "deployment.yaml not found"
else
    check_pass "deployment.yaml exists"
    
    # Check DB_HOST
    DEPLOY_DB_HOST=$(grep -A 1 "name: DB_HOST" "$DEPLOYMENT_FILE" | grep "value:" | awk -F'"' '{print $2}' || echo "")
    if [ -n "$RDS_ENDPOINT" ] && [ "$DEPLOY_DB_HOST" = "$RDS_ENDPOINT" ]; then
        check_pass "DB_HOST in deployment.yaml matches Terraform output: $RDS_ENDPOINT"
    elif [ -n "$DEPLOY_DB_HOST" ]; then
        if [ -n "$RDS_ENDPOINT" ]; then
            check_warn "DB_HOST mismatch. Deployment: $DEPLOY_DB_HOST, Terraform: $RDS_ENDPOINT"
        else
            check_warn "DB_HOST set to $DEPLOY_DB_HOST (Terraform output not available)"
        fi
    else
        check_fail "DB_HOST not found in deployment.yaml"
    fi
    
    # Check S3_BUCKET
    DEPLOY_S3_BUCKET=$(grep -A 1 "name: S3_BUCKET" "$DEPLOYMENT_FILE" | grep "value:" | awk -F'"' '{print $2}' || echo "")
    if [ -n "$S3_BUCKET" ] && [ "$DEPLOY_S3_BUCKET" = "$S3_BUCKET" ]; then
        check_pass "S3_BUCKET in deployment.yaml matches Terraform output: $S3_BUCKET"
    elif [ -n "$DEPLOY_S3_BUCKET" ]; then
        if [ -n "$S3_BUCKET" ]; then
            check_warn "S3_BUCKET mismatch. Deployment: $DEPLOY_S3_BUCKET, Terraform: $S3_BUCKET"
        else
            check_warn "S3_BUCKET set to $DEPLOY_S3_BUCKET (Terraform output not available)"
        fi
    else
        check_fail "S3_BUCKET not found in deployment.yaml"
    fi
    
    # Check AWS_REGION
    DEPLOY_AWS_REGION=$(grep -A 1 "name: AWS_REGION" "$DEPLOYMENT_FILE" | grep "value:" | awk -F'"' '{print $2}' || echo "")
    if [ "$DEPLOY_AWS_REGION" = "$AWS_REGION" ]; then
        check_pass "AWS_REGION in deployment.yaml matches: $AWS_REGION"
    else
        check_warn "AWS_REGION mismatch. Deployment: $DEPLOY_AWS_REGION, Expected: $AWS_REGION"
    fi
fi

echo ""
echo "4. Service Account Annotation Check"
echo "-----------------------------------"

SA_ROLE_ARN=$(grep "eks.amazonaws.com/role-arn:" "$PROJECT_ROOT/k8s/service-account.yaml" | awk '{print $2}' || echo "")
EXPECTED_ROLE_NAME="gringotts-clearinghouse-dev-app-sa-role"
EXPECTED_ROLE_ARN="arn:aws:iam::641332413762:role/interview/${EXPECTED_ROLE_NAME}"

if [ -n "$SA_ROLE_ARN" ]; then
    if [[ "$SA_ROLE_ARN" == *"$EXPECTED_ROLE_NAME"* ]]; then
        check_pass "Service account has role ARN annotation: $SA_ROLE_ARN"
    else
        check_warn "Service account role ARN may be incorrect: $SA_ROLE_ARN (expected: $EXPECTED_ROLE_ARN)"
    fi
else
    check_fail "Service account missing eks.amazonaws.com/role-arn annotation"
fi

echo ""
echo "=========================================="
echo "Validation Summary"
echo "=========================================="
echo -e "Errors: ${RED}${ERRORS}${NC}"
echo -e "Warnings: ${YELLOW}${WARNINGS}${NC}"

if [ $ERRORS -eq 0 ]; then
    echo -e "${GREEN}✓ All critical checks passed!${NC}"
    exit 0
else
    echo -e "${RED}✗ Some critical checks failed. Please fix errors before deploying.${NC}"
    exit 1
fi

