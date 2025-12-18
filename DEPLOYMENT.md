# Deployment Guide

This guide covers deploying the Data Clearinghouse application to EKS with S3 and RDS access.

## Prerequisites

1. Terraform infrastructure deployed
2. `kubectl` configured to access the EKS cluster
3. `aws` CLI configured with appropriate credentials
4. Docker installed and running

## Step 1: Deploy Infrastructure (Terraform)

### 1.1 Apply Terraform Changes

```bash
cd infrastructure/us-west-2/dev
terraform init
terraform plan
terraform apply
```

This will create:
- ECR repository for the application container
- IRSA (IAM Role for Service Accounts) with S3 and RDS permissions
- OIDC provider for EKS (if not already exists)

### 1.2 Get Outputs

```bash
terraform output
```

Note the following values:
- `ecr_repository_url`: ECR repository URL
- `app_service_account_role_arn`: IAM role ARN for pods
- `rds_endpoint`: RDS database endpoint
- `s3_raw_bucket_name`: S3 bucket name

## Step 2: Build and Push Docker Image

### 2.1 Update Service Account with Role ARN

Update `k8s/service-account.yaml` with the actual role ARN from Terraform output:

```bash
# Get the role ARN
ROLE_ARN=$(cd infrastructure/us-west-2/dev && terraform output -raw app_service_account_role_arn)

# Update the service account (or edit manually)
sed -i.bak "s|eks.amazonaws.com/role-arn:.*|eks.amazonaws.com/role-arn: ${ROLE_ARN}|" k8s/service-account.yaml
```

### 2.2 Build and Push Image

```bash
# Make script executable (already done)
chmod +x scripts/build-and-push.sh

# Build and push
./scripts/build-and-push.sh [tag]

# Or manually:
AWS_REGION="us-west-2"
AWS_ACCOUNT_ID="641332413762"
ECR_REPO_NAME="gringotts-clearinghouse-dev-app"
ECR_REPO_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO_NAME}"

# Login to ECR
aws ecr get-login-password --region ${AWS_REGION} | \
  docker login --username AWS --password-stdin ${ECR_REPO_URI}

# Build image
docker build -t ${ECR_REPO_NAME}:latest .

# Tag and push
docker tag ${ECR_REPO_NAME}:latest ${ECR_REPO_URI}:latest
docker push ${ECR_REPO_URI}:latest
```

## Step 3: Deploy Kubernetes Resources

### 3.1 Update Configuration Files

Before deploying, update the following files with actual values:

1. **`k8s/service-account.yaml`**: Update the role ARN annotation
2. **`k8s/deployment.yaml`**: 
   - Update image URL if different
   - Verify environment variables match your setup
3. **`k8s/db-secret.yaml`**: Update password (or use a secrets manager)
4. **`k8s/schema-init-job.yaml`**: Verify database connection details

### 3.2 Deploy in Order

```bash
# 1. Create database secret
kubectl apply -f k8s/db-secret.yaml

# 2. Create service account (with IRSA annotation)
kubectl apply -f k8s/service-account.yaml

# 3. Initialize database schema
kubectl apply -f k8s/schema-init-job.yaml

# 4. Wait for schema init to complete
kubectl wait --for=condition=complete --timeout=300s job/clearinghouse-schema-init

# 5. Deploy application
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml

# 6. Verify deployment
kubectl get pods -l app=clearinghouse-app
kubectl get svc clearinghouse-app
```

## Step 4: Verify Deployment

### 4.1 Check Pod Status

```bash
kubectl get pods -l app=clearinghouse-app
kubectl describe pod -l app=clearinghouse-app
kubectl logs -l app=clearinghouse-app
```

### 4.2 Verify IRSA (IAM Role)

```bash
# Check service account
kubectl describe serviceaccount clearinghouse-app

# Test S3 access from a pod
kubectl run s3-test --rm -it --image=amazon/aws-cli --restart=Never -- \
  aws s3 ls s3://gringotts-clearinghouse-dev-raw-641332413762/

# Test RDS connection
kubectl run db-test --rm -it --image=postgres:15-alpine --restart=Never -- \
  sh -c "apk add postgresql-client && PGPASSWORD='gringotts-secure-pass' \
  psql -h gringotts-clearinghouse-dev-postgres.ctiuycckkj5b.us-west-2.rds.amazonaws.com \
  -U appuser -d clearinghouse -c 'SELECT COUNT(*) FROM file_processing_log;'"
```

### 4.3 Check Database Schema

```bash
kubectl logs job/clearinghouse-schema-init
```

## IAM Permissions Summary

The IRSA setup provides the following permissions:

### S3 Access
- `s3:GetObject` - Read files from S3
- `s3:PutObject` - Write files to S3
- `s3:DeleteObject` - Delete files from S3
- `s3:ListBucket` - List objects in bucket

**Resources**: 
- `arn:aws:s3:::gringotts-clearinghouse-dev-raw-641332413762`
- `arn:aws:s3:::gringotts-clearinghouse-dev-raw-641332413762/*`

### RDS Access
- `rds-db:connect` - Connect to RDS database using IAM authentication (optional)

**Note**: RDS access primarily uses network security groups. IAM authentication is optional and requires additional RDS configuration.

## Troubleshooting

### Pods Not Starting

1. Check pod events:
   ```bash
   kubectl describe pod <pod-name>
   ```

2. Check if image exists in ECR:
   ```bash
   aws ecr describe-images --repository-name gringotts-clearinghouse-dev-app --region us-west-2
   ```

3. Verify service account annotation:
   ```bash
   kubectl get serviceaccount clearinghouse-app -o yaml
   ```

### IRSA Not Working

1. Verify OIDC provider exists:
   ```bash
   aws iam list-open-id-connect-providers
   ```

2. Check IAM role trust relationship:
   ```bash
   aws iam get-role --role-name gringotts-clearinghouse-dev-app-sa-role
   ```

3. Verify service account annotation matches role ARN

### Database Connection Issues

1. Check security groups allow traffic from EKS nodes
2. Verify RDS endpoint is correct
3. Check database credentials in secret
4. Test connectivity from a pod manually

## Next Steps

1. **S3 Event Notifications**: Configure S3 bucket notifications to trigger processing
2. **Monitoring**: Set up CloudWatch metrics and logging
3. **Scaling**: Configure HPA (Horizontal Pod Autoscaler) if needed
4. **CI/CD**: Set up GitHub Actions or similar for automated deployments

