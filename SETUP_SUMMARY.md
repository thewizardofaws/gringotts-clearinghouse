# Setup Summary

This document summarizes all the components created for the Data Clearinghouse deployment.

## Files Created

### Terraform Infrastructure

1. **`infrastructure/us-west-2/dev/ecr.tf`**
   - ECR repository for application container images
   - Lifecycle policy to keep last 10 images
   - Image scanning enabled

2. **`infrastructure/us-west-2/dev/irsa.tf`**
   - OIDC provider for EKS (enables IRSA)
   - IAM role for service account with path `/interview/`
   - IAM policies for S3 and RDS access
   - Trust relationship for Kubernetes service account

3. **`infrastructure/us-west-2/dev/outputs.tf`** (updated)
   - Added outputs for ECR repository URL
   - Added output for service account role ARN
   - Added output for OIDC provider ARN

### Kubernetes Manifests

1. **`k8s/service-account.yaml`**
   - Kubernetes service account with IRSA annotation
   - Allows pods to assume IAM role for AWS API access

2. **`k8s/deployment.yaml`**
   - Application deployment with 2 replicas
   - Environment variables for RDS and S3
   - Health checks configured
   - Resource limits defined

3. **`k8s/service.yaml`**
   - ClusterIP service exposing the application
   - Port 80 -> 8080

4. **`k8s/db-secret.yaml`**
   - Kubernetes secret for database password
   - **Note**: In production, use AWS Secrets Manager

5. **`k8s/schema-init-job.yaml`**
   - One-time job to initialize database schema
   - Creates `file_processing_log` and `processed_data` tables
   - Sets up indexes and triggers

### Scripts

1. **`scripts/build-and-push.sh`**
   - Builds Docker image
   - Tags and pushes to ECR
   - Handles ECR login

2. **`scripts/deploy.sh`**
   - Automated deployment script
   - Updates service account with role ARN
   - Deploys all Kubernetes resources in order
   - Waits for completion

### Documentation

1. **`DEPLOYMENT.md`**
   - Complete deployment guide
   - Step-by-step instructions
   - Troubleshooting section

2. **`Dockerfile.example`**
   - Example Dockerfile template
   - Replace with your actual application Dockerfile

## IAM Permissions

### Service Account Role (`gringotts-clearinghouse-dev-app-sa-role`)

**S3 Permissions:**
- `s3:GetObject` - Read files
- `s3:PutObject` - Write files
- `s3:DeleteObject` - Delete files
- `s3:ListBucket` - List bucket contents

**RDS Permissions:**
- `rds-db:connect` - Connect to RDS (if IAM auth enabled)

**Resources:**
- S3: `arn:aws:s3:::gringotts-clearinghouse-dev-raw-641332413762` and `/*`
- RDS: `arn:aws:rds-db:us-west-2:641332413762:dbuser:*/appuser`

## Database Schema

The schema initialization job creates:

1. **`file_processing_log`** table
   - Tracks files processed from S3
   - Stores file metadata, status, timestamps
   - Unique constraint on S3 bucket + key

2. **`processed_data`** table
   - Stores processed records
   - References file_processing_log
   - JSONB for flexible data storage

3. **Indexes** for performance
   - Status, created_at, S3 key indexes

4. **Triggers** for auto-updating timestamps

## Quick Start

```bash
# 1. Apply Terraform
cd infrastructure/us-west-2/dev
terraform apply

# 2. Build and push image
cd ../../..
./scripts/build-and-push.sh

# 3. Deploy to Kubernetes
./scripts/deploy.sh
```

## Important Notes

1. **OIDC Provider**: If the OIDC provider already exists, you may need to import it:
   ```bash
   terraform import aws_iam_openid_connect_provider.eks <provider-arn>
   ```

2. **Service Account Role ARN**: The role ARN in `k8s/service-account.yaml` will be automatically updated by `deploy.sh`, or you can update it manually after running `terraform output`.

3. **Database Password**: Currently stored in `k8s/db-secret.yaml`. For production, use AWS Secrets Manager with External Secrets Operator.

4. **Image URL**: Update `k8s/deployment.yaml` with the actual ECR repository URL from Terraform output.

5. **RDS IAM Auth**: The RDS IAM policy is included but requires enabling IAM database authentication on the RDS instance. Currently using username/password authentication.

## Next Steps

1. Replace `Dockerfile.example` with your actual application Dockerfile
2. Implement S3 event notifications or polling mechanism
3. Add monitoring and logging (CloudWatch, Prometheus)
4. Set up CI/CD pipeline
5. Configure autoscaling (HPA)
6. Implement proper secret management

