# Quick Start Guide

## Build and Deploy Application

### 1. Build and Push Docker Image

```bash
./scripts/build-and-push.sh
```

### 2. Deploy to Kubernetes

```bash
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
```

### 3. Verify Deployment

```bash
kubectl get pods -l app=clearinghouse-app
kubectl logs -f deployment/clearinghouse-app
```

## Test End-to-End Processing

### Upload Sample File

```bash
./scripts/upload-sample.sh sample-transaction.json
```

### Watch Processing in Real-Time

**Terminal 1 - Application Logs:**
```bash
kubectl logs -f deployment/clearinghouse-app
```

**Terminal 2 - Database Status:**
```bash
# Check file processing log
kubectl run db-check --rm -it --image=postgres:15-alpine --restart=Never -- \
  sh -c 'apk add postgresql-client && \
  PGPASSWORD="gringotts-secure-pass" \
  psql -h gringotts-clearinghouse-dev-postgres.ctiuycckkj5b.us-west-2.rds.amazonaws.com \
  -U appuser -d clearinghouse \
  -c "SELECT id, file_name, status, processed_at, error_message FROM file_processing_log ORDER BY created_at DESC LIMIT 5;"'
```

**Terminal 3 - Processed Data:**
```bash
# Check processed records
kubectl run db-check-data --rm -it --image=postgres:15-alpine --restart=Never -- \
  sh -c 'apk add postgresql-client && \
  PGPASSWORD="gringotts-secure-pass" \
  psql -h gringotts-clearinghouse-dev-postgres.ctiuycckkj5b.us-west-2.rds.amazonaws.com \
  -U appuser -d clearinghouse \
  -c "SELECT id, file_log_id, record_type, record_data->>\''id'\'' as record_id, record_data->>\''amount'\'' as amount FROM processed_data ORDER BY created_at DESC LIMIT 10;"'
```

## Expected Output

### Application Logs Should Show:
```
INFO - Processing S3 file: s3://.../incoming/20241218-120000-sample-transaction.json
INFO - Logged file processing start: ... (log_id=1)
INFO - Parsed 3 records from ...
INFO - Upserted 3 records for file_log_id=1
INFO - Updated file_log_id=1 status to COMPLETED
INFO - Successfully processed ... (log_id=1)
```

### Database Should Show:
- `file_processing_log`: Entry with status='COMPLETED'
- `processed_data`: 3 records (one for each transaction in the sample file)

## Manual Upload Command

If you prefer to upload manually:

```bash
aws s3 cp sample-data/sample-transaction.json \
  s3://gringotts-clearinghouse-dev-raw-641332413762/incoming/$(date +%Y%m%d-%H%M%S)-sample.json \
  --region us-west-2 \
  --content-type application/json
```

## Troubleshooting

### File Not Processing?

1. Check if file exists in S3:
   ```bash
   aws s3 ls s3://gringotts-clearinghouse-dev-raw-641332413762/incoming/
   ```

2. Check application logs for errors:
   ```bash
   kubectl logs deployment/clearinghouse-app | tail -50
   ```

3. Check for failed files in database:
   ```bash
   kubectl run db-check-failed --rm -it --image=postgres:15-alpine --restart=Never -- \
     sh -c 'apk add postgresql-client && \
     PGPASSWORD="gringotts-secure-pass" \
     psql -h gringotts-clearinghouse-dev-postgres.ctiuycckkj5b.us-west-2.rds.amazonaws.com \
     -U appuser -d clearinghouse \
     -c "SELECT * FROM file_processing_log WHERE status = '\''FAILED'\'' ORDER BY created_at DESC LIMIT 3;"'
   ```

