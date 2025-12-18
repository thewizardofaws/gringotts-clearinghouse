"""
Unit tests for S3 processing logic
Tests mock S3 responses and error handling
"""

import pytest
from unittest.mock import Mock, patch, MagicMock
from app.app import calculate_file_hash, process_s3_file


class TestS3Processing:
    """Test suite for S3 file processing functionality"""

    def test_calculate_file_hash(self):
        """Test SHA256 hash calculation"""
        content = b"test content"
        hash1 = calculate_file_hash(content)
        hash2 = calculate_file_hash(content)
        
        assert hash1 == hash2
        assert len(hash1) == 64  # SHA256 produces 64-character hex string
        assert isinstance(hash1, str)

    def test_calculate_file_hash_different_content(self):
        """Test that different content produces different hashes"""
        hash1 = calculate_file_hash(b"content1")
        hash2 = calculate_file_hash(b"content2")
        
        assert hash1 != hash2

    @patch('app.app.s3_client')
    @patch('app.app.get_db_connection')
    def test_process_s3_file_success(self, mock_db_conn, mock_s3_client):
        """Test successful S3 file processing"""
        # Mock S3 response
        mock_s3_response = {
            'Body': Mock(read=lambda: b'[{"id": "txn-001", "amount": 100.0}]'),
            'ContentType': 'application/json',
            'LastModified': '2024-01-01T00:00:00Z',
            'ETag': '"abc123"'
        }
        mock_s3_client.get_object.return_value = mock_s3_response
        
        # Mock database connection and cursor
        mock_conn = MagicMock()
        mock_cursor = MagicMock()
        mock_conn.cursor.return_value.__enter__.return_value = mock_cursor
        mock_conn.cursor.return_value.__exit__.return_value = None
        mock_cursor.fetchone.return_value = {'id': 1}
        mock_db_conn.return_value = mock_conn
        
        # Execute
        result = process_s3_file("test-key.json")
        
        # Verify
        assert result is True
        mock_s3_client.get_object.assert_called_once()
        assert mock_conn.commit.called

    @patch('app.app.s3_client')
    def test_process_s3_file_s3_error(self, mock_s3_client):
        """Test handling of S3 access errors"""
        mock_s3_client.get_object.side_effect = Exception("S3 access denied")
        
        result = process_s3_file("test-key.json")
        
        assert result is False

    @patch('app.app.s3_client')
    @patch('app.app.get_db_connection')
    def test_process_s3_file_invalid_json(self, mock_db_conn, mock_s3_client):
        """Test handling of invalid JSON in S3 file"""
        # Mock S3 response with invalid JSON
        mock_s3_response = {
            'Body': Mock(read=lambda: b'{ invalid json }'),
            'ContentType': 'application/json',
            'LastModified': '2024-01-01T00:00:00Z',
            'ETag': '"abc123"'
        }
        mock_s3_client.get_object.return_value = mock_s3_response
        
        # Mock database connection
        mock_conn = MagicMock()
        mock_cursor = MagicMock()
        mock_conn.cursor.return_value.__enter__.return_value = mock_cursor
        mock_conn.cursor.return_value.__exit__.return_value = None
        mock_cursor.fetchone.return_value = {'id': 1}
        mock_db_conn.return_value = mock_conn
        
        # Execute
        result = process_s3_file("test-invalid.json")
        
        # Verify file was logged but processing failed
        assert result is False
        assert mock_conn.commit.called

    @patch('app.app.s3_client')
    @patch('app.app.get_db_connection')
    def test_process_s3_file_empty_file(self, mock_db_conn, mock_s3_client):
        """Test handling of empty S3 file"""
        mock_s3_response = {
            'Body': Mock(read=lambda: b''),
            'ContentType': 'application/json',
            'LastModified': '2024-01-01T00:00:00Z',
            'ETag': '"abc123"'
        }
        mock_s3_client.get_object.return_value = mock_s3_response
        
        mock_conn = MagicMock()
        mock_cursor = MagicMock()
        mock_conn.cursor.return_value.__enter__.return_value = mock_cursor
        mock_conn.cursor.return_value.__exit__.return_value = None
        mock_cursor.fetchone.return_value = {'id': 1}
        mock_db_conn.return_value = mock_conn
        
        result = process_s3_file("test-empty.json")
        
        assert result is False

