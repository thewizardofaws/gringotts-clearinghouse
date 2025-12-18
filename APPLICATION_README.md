# Data Clearinghouse Application

## Overview

The Data Clearinghouse application watches an S3 bucket for new JSON files, processes them, and stores the data in PostgreSQL. It implements a complete data pipeline with tracking and error handling.

## Architecture

### Data Flow

1. **S3 Bucket Monitoring**: Application polls S3 bucket every 30 seconds (configurable) for new `.json` files
2. **File Processing**: When a new file is detected:
   - Downloads file from S3
   - Calculates file hash (SHA256)
   - Logs processing start in `file_processing_log` table
   - Parses JSON content
   - Upserts records into `processed_data` table
   - Updates log status to `COMPLETED` or `FAILED`

### Database Schema

#### `file_processing_log`
Tracks all file processing operations:
- `id`: Primary key
- `file_name`: Original filename
- `s3_bucket`: S3 bucket name
- `s3_key`: Full S3 object key
- `file_size`: File size in bytes
- `file_hash`: SHA256 hash of file content
- `status`: Processing status (`pending`, `processing`, `COMPLETED`, `FAILED`)
- `processed_at`: Timestamp when processing completed
- `error_message`: Error details if processing failed
- `metadata`: JSONB field for additional file metadata
- Unique constraint on `(s3_bucket, s3_key)` to prevent duplicate processing

#### `processed_data`
Stores the actual processed records:
- `id`: Primary key
- `file_log_id`: Foreign key to `file_processing_log`
- `record_type`: Type of record (e.g., "transaction", "batch")
- `record_data`: JSONB field containing the full record
- `created_at`: Timestamp when record was inserted

## Application Features

### JSON Parsing
The application handles multiple JSON structures:
- **Array of objects**: `[{...}, {...}]`
- **Single object**: `{...}`
- **Object with nested data**: `{"records": [...]}` or `{"data": [...]}`

### Error Handling
- Failed files are logged with error messages
- Processing continues even if one file fails
- Duplicate files are handled gracefully (upsert on conflict)

### Health Checks
- `/health`: Basic health check (database connectivity)
- `/ready`: Readiness check (database + S3 access)

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `DB_HOST` | PostgreSQL hostname | Required |
| `DB_PORT` | PostgreSQL port | `5432` |
| `DB_NAME` | Database name | `clearinghouse` |
| `DB_USER` | Database username | Required |
| `DB_PASSWORD` | Database password | Required |
| `S3_BUCKET` | S3 bucket name to watch | Required |
| `AWS_REGION` | AWS region | `us-west-2` |
| `POLL_INTERVAL` | Seconds between S3 polls | `30` |

## Building and Deploying

### 1. Build Docker Image

```bash
./scripts/build-and-push.sh [tag]
```

Or manually:
```bash
docker build -t gringotts-clearinghouse-dev-app:latest .
docker tag gringotts-clearinghouse-dev-app:latest \
  641332413762.dkr.ecr.us-west-2.amazonaws.com/gringotts-clearinghouse-dev-app:latest

aws ecr get-login-password --region us-west-2 | \
  docker login --username AWS --password-stdin \
  641332413762.dkr.ecr.us-west-2.amazonaws.com

docker push 641332413762.dkr.ecr.us-west-2.amazonaws.com/gringotts-clearinghouse-dev-app:latest
```

### 2. Deploy to Kubernetes

```bash
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
```

### 3. Check Deployment Status

```bash
kubectl get pods -l app=clearinghouse-app
kubectl logs -f deployment/clearinghouse-app
```

## Testing

### Upload Sample File

```bash
./scripts/upload-sample.sh sample-transaction.json
```

Or manually:
```bash
aws s3 cp sample-data/sample-transaction.json \
  s3://gringotts-clearinghouse-dev-raw-641332413762/incoming/$(date +%Y%m%d-%H%M%S)-sample.json \
  --region us-west-2
```

### Monitor Processing

**Watch application logs:**
```bash
kubectl logs -f deployment/clearinghouse-app
```

**Check database for processed files:**
```bash
kubectl run db-check --rm -it --image=postgres:15-alpine --restart=Never -- \
  sh -c 'apk add postgresql-client && \
  PGPASSWORD="gringotts-secure-pass" \
  psql -h gringotts-clearinghouse-dev-postgres.ctiuycckkj5b.us-west-2.rds.amazonaws.com \
  -U appuser -d clearinghouse \
  -c "SELECT id, file_name, status, processed_at FROM file_processing_log ORDER BY created_at DESC LIMIT 10;"'
```

**Check processed data:**
```bash
kubectl run db-check-data --rm -it --image=postgres:15-alpine --restart=Never -- \
  sh -c 'apk add postgresql-client && \
  PGPASSWORD="gringotts-secure-pass" \
  psql -h gringotts-clearinghouse-dev-postgres.ctiuycckkj5b.us-west-2.rds.amazonaws.com \
  -U appuser -d clearinghouse \
  -c "SELECT id, file_log_id, record_type, record_data FROM processed_data ORDER BY created_at DESC LIMIT 5;"'
```

## Sample JSON Files

### Array Format
```json
[
  {"id": "txn-001", "type": "transaction", "amount": 100.00},
  {"id": "txn-002", "type": "transaction", "amount": 200.00}
]
```

### Single Object Format
```json
{
  "id": "batch-001",
  "type": "batch",
  "records": [...]
}
```

## Troubleshooting

### File Not Processing

1. **Check if file is in S3:**
   ```bash
   aws s3 ls s3://gringotts-clearinghouse-dev-raw-641332413762/incoming/
   ```

2. **Check application logs:**
   ```bash
   kubectl logs deployment/clearinghouse-app | grep -i error
   ```

3. **Check database for file status:**
   ```bash
   # See if file was logged but failed
   kubectl run db-check --rm -it --image=postgres:15-alpine --restart=Never -- \
     sh -c 'apk add postgresql-client && \
     PGPASSWORD="gringotts-secure-pass" \
     psql -h gringotts-clearinghouse-dev-postgres.ctiuycckkj5b.us-west-2.rds.amazonaws.com \
     -U appuser -d clearinghouse \
     -c "SELECT * FROM file_processing_log WHERE status = '\''FAILED'\'' ORDER BY created_at DESC LIMIT 5;"'
   ```

### IRSA Issues

If S3 access fails, verify IRSA is working:
```bash
kubectl run s3-test --rm -it --image=amazon/aws-cli --restart=Never \
  --serviceaccount=clearinghouse-app -- \
  aws s3 ls s3://gringotts-clearinghouse-dev-raw-641332413762/
```

### Database Connection Issues

Test database connectivity:
```bash
kubectl run db-test --rm -it --image=postgres:15-alpine --restart=Never -- \
  sh -c 'apk add postgresql-client && \
  PGPASSWORD="gringotts-secure-pass" \
  psql -h gringotts-clearinghouse-dev-postgres.ctiuycckkj5b.us-west-2.rds.amazonaws.com \
  -U appuser -d clearinghouse -c "SELECT 1;"'
```

## Performance Considerations

- **Polling Interval**: Default 30 seconds. Adjust `POLL_INTERVAL` for faster/slower processing
- **Batch Processing**: The application processes files sequentially to avoid overwhelming the database
- **Duplicate Prevention**: Uses database unique constraint to prevent reprocessing
- **Error Recovery**: Failed files remain in `FAILED` status and can be manually retried

## Security

- Uses IRSA (IAM Role for Service Accounts) for S3 access - no static credentials
- Database password stored in Kubernetes secret
- Non-root user in Docker container
- Health checks for monitoring

