"""
Unit tests for JSON parsing logic
Tests handle malformed, empty, and various JSON structures gracefully
"""

import pytest
import json
from app.app import process_json_file


class TestJSONParsing:
    """Test suite for JSON file parsing functionality"""

    def test_parse_array_of_objects(self):
        """Test parsing a JSON array of objects"""
        content = json.dumps([
            {"id": "txn-001", "amount": 100.0},
            {"id": "txn-002", "amount": 200.0}
        ]).encode('utf-8')
        
        records = process_json_file("test-array.json", content)
        assert len(records) == 2
        assert records[0]["id"] == "txn-001"
        assert records[1]["id"] == "txn-002"

    def test_parse_single_object(self):
        """Test parsing a single JSON object"""
        content = json.dumps({"id": "txn-001", "amount": 100.0}).encode('utf-8')
        
        records = process_json_file("test-single.json", content)
        assert len(records) == 1
        assert records[0]["id"] == "txn-001"

    def test_parse_nested_records(self):
        """Test parsing object with nested 'records' array"""
        content = json.dumps({
            "batch_id": "batch-001",
            "records": [
                {"id": "txn-001", "amount": 100.0},
                {"id": "txn-002", "amount": 200.0}
            ]
        }).encode('utf-8')
        
        records = process_json_file("test-nested-records.json", content)
        assert len(records) == 2
        assert records[0]["id"] == "txn-001"

    def test_parse_nested_data(self):
        """Test parsing object with nested 'data' array"""
        content = json.dumps({
            "batch_id": "batch-001",
            "data": [
                {"id": "txn-001", "amount": 100.0}
            ]
        }).encode('utf-8')
        
        records = process_json_file("test-nested-data.json", content)
        assert len(records) == 1
        assert records[0]["id"] == "txn-001"

    def test_empty_file_raises_error(self):
        """Test that empty file raises ValueError"""
        with pytest.raises(ValueError, match="Empty file"):
            process_json_file("empty.json", b"")

    def test_whitespace_only_raises_error(self):
        """Test that whitespace-only file raises ValueError"""
        with pytest.raises(ValueError, match="only whitespace"):
            process_json_file("whitespace.json", b"   \n\t  ")

    def test_empty_array_raises_error(self):
        """Test that empty array raises ValueError"""
        content = json.dumps([]).encode('utf-8')
        with pytest.raises(ValueError, match="Empty array"):
            process_json_file("empty-array.json", content)

    def test_invalid_json_raises_error(self):
        """Test that invalid JSON raises ValueError"""
        with pytest.raises(ValueError, match="Invalid JSON syntax"):
            process_json_file("invalid.json", b"{ invalid json }")

    def test_non_utf8_raises_error(self):
        """Test that non-UTF-8 content raises ValueError"""
        with pytest.raises(ValueError, match="Invalid UTF-8 encoding"):
            process_json_file("binary.json", b'\xff\xfe\x00\x01')

    def test_unexpected_type_raises_error(self):
        """Test that unexpected JSON type (e.g., string) raises ValueError"""
        content = json.dumps("just a string").encode('utf-8')
        with pytest.raises(ValueError, match="Unexpected JSON structure"):
            process_json_file("string.json", content)

    def test_number_raises_error(self):
        """Test that JSON number raises ValueError"""
        content = json.dumps(123).encode('utf-8')
        with pytest.raises(ValueError, match="Unexpected JSON structure"):
            process_json_file("number.json", content)

    def test_nested_records_not_list_handles_gracefully(self):
        """Test that nested 'records' that isn't a list falls back to single object"""
        content = json.dumps({
            "batch_id": "batch-001",
            "records": "not a list"
        }).encode('utf-8')
        
        records = process_json_file("test-bad-nested.json", content)
        assert len(records) == 1
        assert records[0]["batch_id"] == "batch-001"

    def test_complex_nested_structure(self):
        """Test parsing complex nested structure"""
        content = json.dumps({
            "metadata": {"version": "1.0"},
            "records": [
                {"id": "txn-001", "nested": {"value": 100}},
                {"id": "txn-002", "nested": {"value": 200}}
            ]
        }).encode('utf-8')
        
        records = process_json_file("test-complex.json", content)
        assert len(records) == 2
        assert records[0]["nested"]["value"] == 100

