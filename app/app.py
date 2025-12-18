#!/usr/bin/env python3
"""
Data Clearinghouse Application
Watches S3 bucket for new files, processes JSON data, and stores in PostgreSQL
"""

import os
import json
import hashlib
import logging
import time
from datetime import datetime
from typing import Dict, Any, Optional
import boto3
import psycopg2
from psycopg2.extras import RealDictCursor, execute_values
from flask import Flask, jsonify

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Flask app for health checks
app = Flask(__name__)

# Configuration from environment variables
DB_HOST = os.getenv('DB_HOST')
DB_PORT = os.getenv('DB_PORT', '5432')
DB_NAME = os.getenv('DB_NAME', 'clearinghouse')
DB_USER = os.getenv('DB_USER')
DB_PASSWORD = os.getenv('DB_PASSWORD')
S3_BUCKET = os.getenv('S3_BUCKET')
AWS_REGION = os.getenv('AWS_REGION', 'us-west-2')
POLL_INTERVAL = int(os.getenv('POLL_INTERVAL', '30'))  # seconds

# Initialize AWS clients
s3_client = boto3.client('s3', region_name=AWS_REGION)


def get_db_connection():
    """Create and return a database connection"""
    return psycopg2.connect(
        host=DB_HOST,
        port=DB_PORT,
        database=DB_NAME,
        user=DB_USER,
        password=DB_PASSWORD
    )


def calculate_file_hash(content: bytes) -> str:
    """Calculate SHA256 hash of file content"""
    return hashlib.sha256(content).hexdigest()


def log_file_processing_start(
    conn,
    s3_key: str,
    file_name: str,
    file_size: int,
    file_hash: str,
    metadata: Optional[Dict[str, Any]] = None
) -> int:
    """
    Log the start of file processing in file_processing_log table
    Returns the log entry ID
    """
    with conn.cursor(cursor_factory=RealDictCursor) as cur:
        # Use INSERT ... ON CONFLICT to handle duplicates
        insert_query = """
            INSERT INTO file_processing_log 
            (file_name, file_path, s3_bucket, s3_key, file_size, file_hash, status, metadata)
            VALUES (%s, %s, %s, %s, %s, %s, 'processing', %s)
            ON CONFLICT (s3_bucket, s3_key) 
            DO UPDATE SET 
                status = 'processing',
                file_size = EXCLUDED.file_size,
                file_hash = EXCLUDED.file_hash,
                metadata = EXCLUDED.metadata,
                updated_at = CURRENT_TIMESTAMP
            RETURNING id
        """
        cur.execute(
            insert_query,
            (
                file_name,
                s3_key,  # file_path
                S3_BUCKET,
                s3_key,
                file_size,
                file_hash,
                json.dumps(metadata) if metadata else None
            )
        )
        result = cur.fetchone()
        conn.commit()
        log_id = result['id']
        logger.info(f"Logged file processing start: {s3_key} (log_id={log_id})")
        return log_id


def upsert_processed_data(
    conn,
    file_log_id: int,
    records: list[Dict[str, Any]]
):
    """
    Upsert processed data records into processed_data table
    Uses record_data JSONB for flexible schema
    """
    if not records:
        logger.warning(f"No records to upsert for file_log_id={file_log_id}")
        return

    with conn.cursor() as cur:
        # Determine record_type from the first record (or use a default)
        record_type = records[0].get('type', 'unknown') if records else 'unknown'
        
        # Prepare data for bulk insert
        values = [
            (file_log_id, record_type, json.dumps(record))
            for record in records
        ]
        
        # Use INSERT with ON CONFLICT for upsert (if we had a unique constraint)
        # For now, just insert (assuming we want to keep all records)
        insert_query = """
            INSERT INTO processed_data (file_log_id, record_type, record_data)
            VALUES %s
        """
        execute_values(cur, insert_query, values)
        conn.commit()
        logger.info(f"Upserted {len(records)} records for file_log_id={file_log_id}")


def update_file_processing_status(
    conn,
    file_log_id: int,
    status: str,
    error_message: Optional[str] = None
):
    """Update the file processing log status"""
    with conn.cursor() as cur:
        update_query = """
            UPDATE file_processing_log
            SET status = %s,
                processed_at = CASE WHEN %s = 'COMPLETED' THEN CURRENT_TIMESTAMP ELSE processed_at END,
                error_message = %s
            WHERE id = %s
        """
        cur.execute(update_query, (status, status, error_message, file_log_id))
        conn.commit()
        logger.info(f"Updated file_log_id={file_log_id} status to {status}")


def process_json_file(s3_key: str, content: bytes) -> list[Dict[str, Any]]:
    """
    Parse JSON file and extract records for database ingestion.
    Handles multiple JSON structures: arrays, single objects, and nested data containers.
    
    Args:
        s3_key: S3 object key for logging purposes
        content: Raw file content as bytes
        
    Returns:
        List of record dictionaries to be inserted into processed_data table
        
    Raises:
        ValueError: If JSON is malformed, empty, or has unexpected structure
    """
    if not content or len(content) == 0:
        raise ValueError(f"Empty file: {s3_key}")
    
    try:
        decoded_content = content.decode('utf-8').strip()
        if not decoded_content:
            raise ValueError(f"File contains only whitespace: {s3_key}")
        
        data = json.loads(decoded_content)
        
        # Handle different JSON structures
        if isinstance(data, list):
            if len(data) == 0:
                raise ValueError(f"Empty array in {s3_key}")
            records = data
        elif isinstance(data, dict):
            # Single object or object with nested data
            if 'records' in data and isinstance(data['records'], list):
                records = data['records']
            elif 'data' in data and isinstance(data['data'], list):
                records = data['data']
            else:
                # Single object - wrap in list for consistent processing
                records = [data]
        else:
            raise ValueError(f"Unexpected JSON structure in {s3_key}: expected object or array, got {type(data).__name__}")
        
        if not records:
            raise ValueError(f"No records extracted from {s3_key}")
        
        logger.info(f"Parsed {len(records)} records from {s3_key}")
        return records
    except json.JSONDecodeError as e:
        raise ValueError(f"Invalid JSON syntax in {s3_key}: {str(e)}")
    except UnicodeDecodeError as e:
        raise ValueError(f"Invalid UTF-8 encoding in {s3_key}: {str(e)}")
    except Exception as e:
        raise ValueError(f"Error parsing {s3_key}: {str(e)}")


def process_s3_file(s3_key: str) -> bool:
    """
    Process a single S3 file: download, parse, and store in database
    Returns True if successful, False otherwise
    """
    conn = None
    file_log_id = None
    
    try:
        logger.info(f"Processing S3 file: s3://{S3_BUCKET}/{s3_key}")
        
        # Download file from S3
        response = s3_client.get_object(Bucket=S3_BUCKET, Key=s3_key)
        content = response['Body'].read()
        file_size = len(content)
        file_hash = calculate_file_hash(content)
        file_name = os.path.basename(s3_key)
        
        # Get file metadata
        metadata = {
            'content_type': response.get('ContentType', 'application/json'),
            'last_modified': response.get('LastModified', datetime.utcnow()).isoformat(),
            'etag': response.get('ETag', '').strip('"')
        }
        
        # Connect to database
        conn = get_db_connection()
        
        # Log processing start
        file_log_id = log_file_processing_start(
            conn,
            s3_key,
            file_name,
            file_size,
            file_hash,
            metadata
        )
        
        # Parse JSON file
        records = process_json_file(s3_key, content)
        
        # Upsert processed data
        upsert_processed_data(conn, file_log_id, records)
        
        # Update status to COMPLETED
        update_file_processing_status(conn, file_log_id, 'COMPLETED')
        
        logger.info(f"Successfully processed {s3_key} (log_id={file_log_id})")
        return True
        
    except Exception as e:
        logger.error(f"Error processing {s3_key}: {str(e)}", exc_info=True)
        
        # Update status to FAILED
        if conn and file_log_id:
            try:
                update_file_processing_status(
                    conn,
                    file_log_id,
                    'FAILED',
                    str(e)
                )
            except Exception as update_error:
                logger.error(f"Failed to update error status: {str(update_error)}")
        
        return False
        
    finally:
        if conn:
            conn.close()


def get_processed_files(conn) -> set[str]:
    """Get set of S3 keys that have already been processed"""
    with conn.cursor() as cur:
        cur.execute(
            "SELECT s3_key FROM file_processing_log WHERE status IN ('COMPLETED', 'processing')"
        )
        return {row[0] for row in cur.fetchall()}


def watch_s3_bucket():
    """
    Main loop: Poll S3 bucket for new files and process them
    """
    logger.info(f"Starting S3 bucket watcher for s3://{S3_BUCKET}")
    logger.info(f"Poll interval: {POLL_INTERVAL} seconds")
    
    conn = get_db_connection()
    processed_files = get_processed_files(conn)
    conn.close()
    
    logger.info(f"Found {len(processed_files)} previously processed files")
    
    while True:
        try:
            # Get list of objects in S3 bucket
            response = s3_client.list_objects_v2(Bucket=S3_BUCKET)
            
            if 'Contents' not in response:
                logger.debug("No objects found in S3 bucket")
                time.sleep(POLL_INTERVAL)
                continue
            
            # Filter for JSON files that haven't been processed
            new_files = [
                obj['Key']
                for obj in response['Contents']
                if obj['Key'].endswith('.json') and obj['Key'] not in processed_files
            ]
            
            if new_files:
                logger.info(f"Found {len(new_files)} new JSON file(s) to process")
                
                # Process each new file
                for s3_key in new_files:
                    success = process_s3_file(s3_key)
                    if success:
                        processed_files.add(s3_key)
                    # Small delay between files to avoid overwhelming the system
                    time.sleep(1)
            else:
                logger.debug("No new files to process")
            
            # Wait before next poll
            time.sleep(POLL_INTERVAL)
            
        except Exception as e:
            logger.error(f"Error in watch loop: {str(e)}", exc_info=True)
            time.sleep(POLL_INTERVAL)


@app.route('/health')
def health():
    """Health check endpoint"""
    try:
        conn = get_db_connection()
        conn.close()
        return jsonify({'status': 'healthy', 'service': 'clearinghouse-app'}), 200
    except Exception as e:
        return jsonify({'status': 'unhealthy', 'error': str(e)}), 503


@app.route('/ready')
def ready():
    """Readiness check endpoint"""
    try:
        # Check database connection
        conn = get_db_connection()
        with conn.cursor() as cur:
            cur.execute("SELECT 1")
        conn.close()
        
        # Check S3 access
        s3_client.head_bucket(Bucket=S3_BUCKET)
        
        return jsonify({'status': 'ready'}), 200
    except Exception as e:
        return jsonify({'status': 'not ready', 'error': str(e)}), 503


def verify_database_schema(conn):
    """
    Pre-flight check: Verify required database tables exist before processing
    Returns True if schema is valid, False otherwise
    """
    required_tables = ['file_processing_log', 'processed_data']
    try:
        with conn.cursor() as cur:
            cur.execute("""
                SELECT table_name 
                FROM information_schema.tables 
                WHERE table_schema = 'public' 
                AND table_name = ANY(%s)
            """, (required_tables,))
            existing_tables = {row[0] for row in cur.fetchall()}
            
            missing_tables = set(required_tables) - existing_tables
            if missing_tables:
                logger.error(f"Missing required database tables: {', '.join(missing_tables)}")
                return False
            
            logger.info("Database schema verification passed")
            return True
    except Exception as e:
        logger.error(f"Database schema verification failed: {str(e)}")
        return False


def main():
    """
    Main entry point for the Data Clearinghouse application.
    Validates configuration, performs pre-flight checks, and starts the S3 monitoring loop.
    """
    # Validate required environment variables
    required_vars = ['DB_HOST', 'DB_USER', 'DB_PASSWORD', 'S3_BUCKET']
    missing = [var for var in required_vars if not os.getenv(var)]
    
    if missing:
        logger.error(f"Missing required environment variables: {', '.join(missing)}")
        raise ValueError(f"Missing required environment variables: {', '.join(missing)}")
    
    logger.info("Initializing Data Clearinghouse Application")
    logger.info(f"Database: {DB_HOST}:{DB_PORT}/{DB_NAME}")
    logger.info(f"S3 Bucket: s3://{S3_BUCKET}")
    logger.info(f"Poll Interval: {POLL_INTERVAL} seconds")
    
    # Pre-flight check: Verify database schema
    logger.info("Performing pre-flight database schema verification...")
    try:
        conn = get_db_connection()
        if not verify_database_schema(conn):
            raise RuntimeError("Database schema verification failed. Ensure schema initialization job has completed.")
        conn.close()
    except Exception as e:
        logger.error(f"Pre-flight check failed: {str(e)}")
        raise
    
    # Start Flask app in a separate thread for health checks
    import threading
    flask_thread = threading.Thread(
        target=lambda: app.run(host='0.0.0.0', port=8080, debug=False),
        daemon=True
    )
    flask_thread.start()
    logger.info("Health check server started on port 8080")
    
    # Start S3 watcher in main thread
    watch_s3_bucket()


if __name__ == '__main__':
    main()

