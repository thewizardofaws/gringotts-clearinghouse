# Data Clearinghouse

A production-ready data ingestion pipeline that monitors an S3 bucket for JSON files, processes them, and stores structured data in PostgreSQL. Built for AWS EKS with IRSA (IAM Roles for Service Accounts) for secure, credential-free S3 access.

## Architecture

### Components

- **Infrastructure (Terraform)**: VPC, EKS cluster (v1.34+), AL2023 Managed Node Groups via NodeConfig API, RDS PostgreSQL, S3 bucket, ECR repository, IRSA configuration
- **Application (Python)**: S3 bucket watcher, JSON parser, database ingestion engine
- **Kubernetes**: Deployment, service, service account with IRSA, database schema initialization

**Note**: This implementation uses the latest EKS standards including Amazon Linux 2023 (AL2023) Managed Node Groups with the NodeConfig API (`node.eks.aws/v1alpha1`), ensuring compatibility with EKS v1.34+ and modern node bootstrap requirements.

### Data Flow

1. **S3 Monitoring**: Application polls the target S3 bucket every 30 seconds (configurable) for new `.json` files
2. **File Processing**: When a new file is detected:
   - Downloads file from S3
   - Calculates SHA256 hash for deduplication
   - Logs processing start in `file_processing_log` table
   - Parses JSON content (supports arrays, single objects, nested structures)
   - Upserts records into `processed_data` table
   - Updates log status to `COMPLETED` or `FAILED`

### Database Schema

**`file_processing_log`**: Tracks all file processing operations
- Unique constraint on `(s3_bucket, s3_key)` prevents duplicate processing
- Status values: `pending`, `processing`, `COMPLETED`, `FAILED`
- Stores file metadata, hash, timestamps, error messages

**`processed_data`**: Stores processed records
- JSONB field for flexible schema
- Links to `file_processing_log` via foreign key
- Indexed for performance

## Prerequisites

- AWS CLI configured with appropriate credentials
- Terraform >= 1.5.0
- kubectl configured to access EKS cluster
- Docker installed and running
- Access to AWS account: 641332413762, region: us-west-2

## Quick Start

### 1. Deploy Infrastructure

```bash
cd infrastructure/us-west-2/dev
terraform init
terraform plan
terraform apply
```

This creates:
- ECR repository for container images
- IRSA (IAM Role for Service Accounts) with S3 and RDS permissions
- OIDC provider for EKS

**Get Terraform Outputs:**
```bash
terraform output
```

Key outputs:
- `ecr_repository_url`: ECR repository URL
- `app_service_account_role_arn`: IAM role ARN for pods
- `rds_endpoint`: RDS database endpoint
- `s3_raw_bucket_name`: S3 bucket name

### 2. Build and Push Application Image

```bash
./scripts/build-and-push.sh [tag]
```

The script:
- Validates prerequisites (Docker, AWS CLI)
- Builds Docker image
- Authenticates with ECR
- Tags and pushes image

### 3. Deploy to Kubernetes

```bash
./scripts/deploy.sh
```

The deployment script:
- Updates service account with IAM role ARN from Terraform
- Creates database secret
- Initializes database schema
- Deploys application deployment and service
- Waits for rollout completion

**Manual Deployment (if needed):**
```bash
# 1. Update service account with role ARN
ROLE_ARN=$(cd infrastructure/us-west-2/dev && terraform output -raw app_service_account_role_arn)
kubectl annotate serviceaccount clearinghouse-app eks.amazonaws.com/role-arn="${ROLE_ARN}" --overwrite

# 2. Deploy resources
kubectl apply -f k8s/db-secret.yaml
kubectl apply -f k8s/service-account.yaml
kubectl apply -f k8s/schema-init-job.yaml

# 3. Wait for schema init
kubectl wait --for=condition=complete --timeout=300s job/clearinghouse-schema-init

# 4. Deploy application
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
```

### 4. Verify Deployment

```bash
# Check pod status
kubectl get pods -l app=clearinghouse-app

# View logs
kubectl logs -f deployment/clearinghouse-app

# Check service
kubectl get svc clearinghouse-app
```

### 5. Test End-to-End

```bash
# Upload sample file
./scripts/upload-sample.sh sample-transaction.json

# Watch processing
kubectl logs -f deployment/clearinghouse-app
```

## Configuration

### Environment Variables

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `DB_HOST` | PostgreSQL hostname | - | Yes |
| `DB_PORT` | PostgreSQL port | `5432` | No |
| `DB_NAME` | Database name | `clearinghouse` | No |
| `DB_USER` | Database username | - | Yes |
| `DB_PASSWORD` | Database password | - | Yes |
| `S3_BUCKET` | S3 bucket name to monitor | - | Yes |
| `AWS_REGION` | AWS region | `us-west-2` | No |
| `POLL_INTERVAL` | Seconds between S3 polls | `30` | No |

### Application Features

- **JSON Parsing**: Handles arrays, single objects, and nested structures
- **Error Handling**: Failed files logged with error messages; processing continues
- **Deduplication**: Database unique constraint prevents reprocessing. If a file fails mid-process, the database entry remains in `FAILED` state. Deleting the failed entry or manually resetting the status allows the poller to re-attempt ingestion during the next cycle.
- **Retry Handling**: The application does not automatically retry failed files. Files that fail processing remain in `FAILED` status in the database. To retry a failed file:
  1. Delete the failed entry from `file_processing_log` table, OR
  2. Update the status to `pending`: `UPDATE file_processing_log SET status = 'pending' WHERE id = <file_id>`
  The next polling cycle will detect the file as new and attempt processing again.
- **Structured Logging**: Application outputs logs in a standardized format for easy ingestion into CloudWatch or ELK stacks
- **Health Checks**: `/health` and `/ready` endpoints for monitoring
- **Pre-flight Checks**: Validates database schema before processing

## IAM Permissions

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

**Note**: RDS access primarily uses network security groups. IAM authentication is optional and requires enabling IAM database authentication on the RDS instance.

## Testing

### Unit Tests

```bash
cd tests
python -m pytest test_json_parsing.py -v
python -m pytest test_s3_processing.py -v
```

### Integration Testing

```bash
# Upload sample file
./scripts/upload-sample.sh sample-transaction.json

# Verify processing in database
kubectl run db-check --rm -it --image=postgres:15-alpine --restart=Never -- \
  sh -c 'apk add postgresql-client && \
  PGPASSWORD="gringotts-secure-pass" \
  psql -h gringotts-clearinghouse-dev-postgres.ctiuycckkj5b.us-west-2.rds.amazonaws.com \
  -U appuser -d clearinghouse \
  -c "SELECT id, file_name, status, processed_at FROM file_processing_log ORDER BY created_at DESC LIMIT 5;"'
```

## Monitoring

### Application Logs

```bash
kubectl logs -f deployment/clearinghouse-app
```

### Health Checks

```bash
# Health endpoint
kubectl port-forward deployment/clearinghouse-app 8080:8080
curl http://localhost:8080/health

# Readiness endpoint
curl http://localhost:8080/ready
```

### Database Status

```bash
# Check processing status
kubectl run db-status --rm -it --image=postgres:15-alpine --restart=Never -- \
  sh -c 'apk add postgresql-client && \
  PGPASSWORD="gringotts-secure-pass" \
  psql -h gringotts-clearinghouse-dev-postgres.ctiuycckkj5b.us-west-2.rds.amazonaws.com \
  -U appuser -d clearinghouse \
  -c "SELECT status, COUNT(*) FROM file_processing_log GROUP BY status;"'
```

## Troubleshooting

### File Not Processing

1. **Verify file exists in S3:**
   ```bash
   aws s3 ls s3://gringotts-clearinghouse-dev-raw-641332413762/incoming/
   ```

2. **Check application logs:**
   ```bash
   kubectl logs deployment/clearinghouse-app | grep -i error
   ```

3. **Check database for failed files:**
   ```bash
   kubectl run db-check-failed --rm -it --image=postgres:15-alpine --restart=Never -- \
     sh -c 'apk add postgresql-client && \
     PGPASSWORD="gringotts-secure-pass" \
     psql -h gringotts-clearinghouse-dev-postgres.ctiuycckkj5b.us-west-2.rds.amazonaws.com \
     -U appuser -d clearinghouse \
     -c "SELECT * FROM file_processing_log WHERE status = '\''FAILED'\'' ORDER BY created_at DESC LIMIT 3;"'
   ```

### Pods Not Starting

1. **Check pod events:**
   ```bash
   kubectl describe pod <pod-name>
   ```

2. **Check if image exists in ECR:**
   ```bash
   aws ecr describe-images --repository-name gringotts-clearinghouse-dev-app --region us-west-2
   ```

3. **Verify service account annotation:**
   ```bash
   kubectl get serviceaccount clearinghouse-app -o yaml
   ```

### IRSA Issues

1. **Verify OIDC provider exists:**
   ```bash
   aws iam list-open-id-connect-providers
   ```

2. **Check IAM role trust relationship:**
   ```bash
   aws iam get-role --role-name gringotts-clearinghouse-dev-app-sa-role
   ```

3. **Test S3 access from a pod:**
   ```bash
   kubectl run s3-test --rm -it --image=amazon/aws-cli --restart=Never \
     --serviceaccount=clearinghouse-app -- \
     aws s3 ls s3://gringotts-clearinghouse-dev-raw-641332413762/
   ```

### Database Connection Issues

1. Check security groups allow traffic from EKS nodes
2. Verify RDS endpoint is correct
3. Check database credentials in secret
4. Test connectivity:
   ```bash
   kubectl run db-test --rm -it --image=postgres:15-alpine --restart=Never -- \
     sh -c 'apk add postgresql-client && \
     PGPASSWORD="gringotts-secure-pass" \
     psql -h gringotts-clearinghouse-dev-postgres.ctiuycckkj5b.us-west-2.rds.amazonaws.com \
     -U appuser -d clearinghouse -c "SELECT 1;"'
   ```

### OIDC Provider Already Exists

If Terraform reports the OIDC provider already exists:
```bash
# Import existing OIDC provider
terraform import aws_iam_openid_connect_provider.eks <provider-arn>
```

## Security

- **IRSA**: IAM Roles for Service Accounts - no static AWS credentials
- **Secrets Management**: Database password stored in Kubernetes secret
- **Container Security**: Non-root user (UID 1000), security contexts, dropped capabilities
- **Network Security**: Private subnets, security groups, VPC isolation
- **Resource Limits**: CPU and memory limits defined in deployment

## Retry Handling

The application implements a manual retry mechanism for failed file processing:

1. **Automatic Retries**: Not implemented. Files that fail during processing are logged with error details and remain in `FAILED` status.

2. **Manual Retry Process**:
   - Failed files are tracked in the `file_processing_log` table with status `FAILED`
   - Error messages are stored in the `error_message` field for troubleshooting
   - To retry a failed file:
     ```sql
     -- Option 1: Delete the failed entry (will be re-detected as new file)
     DELETE FROM file_processing_log WHERE id = <file_id>;
     
     -- Option 2: Reset status to pending (will be picked up on next poll)
     UPDATE file_processing_log SET status = 'pending', error_message = NULL WHERE id = <file_id;
     ```
   - The next polling cycle (default: 30 seconds) will detect the file and attempt processing again

3. **Deduplication**: The unique constraint on `(s3_bucket, s3_key)` ensures that:
   - Successfully processed files (`COMPLETED` status) are never reprocessed
   - Files in `processing` status are not picked up by concurrent pollers
   - Failed files can be manually reset for retry without creating duplicates

## Performance

- **Polling Interval**: Configurable via `POLL_INTERVAL` environment variable
- **Sequential Processing**: Files processed one at a time to avoid database overload
- **Indexing**: Database indexes on status, timestamps, and S3 keys
- **Error Recovery**: Failed files remain in `FAILED` status for manual retry

## Project Structure

```
gringotts-clearinghouse/
├── app/                          # Application source code
│   ├── app.py                   # Main application logic
│   └── requirements.txt         # Python dependencies
├── infrastructure/              # Terraform infrastructure definitions
│   └── us-west-2/
│       └── dev/                 # Development environment
│           ├── ecr.tf           # ECR repository configuration
│           ├── irsa.tf          # IRSA (IAM Roles for Service Accounts)
│           ├── main.tf          # Core infrastructure (VPC, EKS, IAM)
│           ├── outputs.tf       # Terraform outputs
│           ├── rds.tf           # RDS PostgreSQL configuration
│           ├── s3.tf            # S3 bucket configuration
│           ├── variables.tf     # Terraform variables
│           └── versions.tf      # Provider versions and backend
├── k8s/                         # Kubernetes manifests
│   ├── db-secret.yaml          # Database credentials secret
│   ├── deployment.yaml         # Application deployment
│   ├── schema-init-job.yaml    # Database schema initialization
│   ├── service-account.yaml    # IRSA service account
│   └── service.yaml            # Kubernetes service
├── sample-data/                 # Sample JSON files for testing
│   ├── sample-single.json     # Single object format
│   └── sample-transaction.json # Array format
├── scripts/                     # Deployment and utility scripts
│   ├── build-and-push.sh      # Docker build and ECR push
│   ├── deploy.sh               # Kubernetes deployment automation
│   └── upload-sample.sh        # S3 test file upload utility
├── tests/                       # Unit tests
│   ├── test_json_parsing.py    # JSON parsing logic tests
│   ├── test_s3_processing.py   # S3 processing tests
│   └── requirements.txt        # Test dependencies
├── Dockerfile                   # Production Docker image
└── README.md                    # This file
```

**File Counts:**
- Application Code: 2 files
- Infrastructure: 8 Terraform files
- Kubernetes: 5 manifest files
- Scripts: 3 deployment/utility scripts
- Tests: 4 test files

**Excluded from Version Control:**
- `.terraform/` directories (Terraform provider cache)
- `*.tfstate` files (Terraform state)
- `*.tfvars` files (sensitive variable values)
- `.env` files (environment-specific configuration)
- `__pycache__/` directories and `*.pyc` files (Python bytecode)
- `*.log` files (application logs)

## Infrastructure Validation

### IRSA Trust Configuration

The IRSA trust policy correctly matches:
- **Namespace**: `default`
- **Service Account**: `clearinghouse-app`
- **Condition**: `system:serviceaccount:default:clearinghouse-app`

### Dependency Graph

- `irsa.tf` depends on `aws_eks_cluster.this`
- `irsa.tf` references `aws_s3_bucket.raw` for S3 policy
- `irsa.tf` references `aws_db_instance.this` for RDS policy
- ECR repository and OIDC provider created by Terraform

## Next Steps

1. **S3 Event Notifications**: Configure S3 bucket notifications to trigger processing
2. **Monitoring**: Set up CloudWatch metrics and logging
3. **Scaling**: Configure HPA (Horizontal Pod Autoscaler) if needed
4. **CI/CD**: Set up GitHub Actions or similar for automated deployments
5. **Secret Management**: Migrate to AWS Secrets Manager with External Secrets Operator

## License

Proprietary - Internal use only
