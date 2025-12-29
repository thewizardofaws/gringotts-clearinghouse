#!/usr/bin/env python3
"""
Schema Enforcer for Data Clearinghouse
Validates LLM/Agent outputs against strict Pydantic schemas to prevent schema drift.
Treats validation failures as deployment failures (SchemaDriftError).
"""

import json
import logging
from typing import Any, Dict, List, Optional, Union
from pydantic import BaseModel, Field, ValidationError, field_validator

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


class SchemaDriftError(Exception):
    """
    Raised when LLM/Agent output fails schema validation.
    This is treated as a deployment failure - drift is not tolerated.
    """
    pass


# Define strict schema for Agent outputs
class AgentOutputRecord(BaseModel):
    """Strict schema for individual records in Agent output"""
    id: str = Field(..., description="Unique identifier for the record")
    timestamp: str = Field(..., description="ISO 8601 timestamp")
    type: str = Field(..., description="Record type identifier")
    data: Dict[str, Any] = Field(..., description="Record payload data")
    metadata: Optional[Dict[str, Any]] = Field(None, description="Optional metadata")
    
    @field_validator('timestamp')
    @classmethod
    def validate_timestamp(cls, v: str) -> str:
        """Validate timestamp is ISO 8601 format"""
        from datetime import datetime
        try:
            datetime.fromisoformat(v.replace('Z', '+00:00'))
            return v
        except ValueError:
            raise ValueError(f"Invalid ISO 8601 timestamp: {v}")
    
    @field_validator('type')
    @classmethod
    def validate_type(cls, v: str) -> str:
        """Validate type is non-empty"""
        if not v or not v.strip():
            raise ValueError("Type cannot be empty")
        return v.strip()
    
    class Config:
        extra = 'forbid'  # Reject any extra fields not in schema


class AgentOutputSchema(BaseModel):
    """Strict schema for complete Agent output payload"""
    version: str = Field(..., description="Schema version")
    records: List[AgentOutputRecord] = Field(..., min_length=1, description="List of records")
    source: Optional[str] = Field(None, description="Source identifier")
    
    @field_validator('version')
    @classmethod
    def validate_version(cls, v: str) -> str:
        """Validate version format"""
        if not v or not v.strip():
            raise ValueError("Version cannot be empty")
        return v.strip()
    
    class Config:
        extra = 'forbid'  # Reject any extra fields not in schema


def validate_llm_output(raw_string: str) -> AgentOutputSchema:
    """
    Validate raw LLM string output against strict schema.
    
    Args:
        raw_string: Raw string output from LLM/Agent
        
    Returns:
        Validated AgentOutputSchema object
        
    Raises:
        SchemaDriftError: If validation fails (treated as deployment failure)
        ValueError: If string cannot be parsed as JSON
    """
    try:
        # Parse JSON from raw string
        parsed_data = json.loads(raw_string.strip())
    except json.JSONDecodeError as e:
        error_msg = f"Invalid JSON syntax in LLM output: {str(e)}"
        logger.error(error_msg)
        raise SchemaDriftError(error_msg) from e
    
    try:
        # Validate against Pydantic schema
        validated_output = AgentOutputSchema(**parsed_data)
        logger.info(f"Successfully validated LLM output: {len(validated_output.records)} records")
        return validated_output
    except ValidationError as e:
        error_msg = f"Schema validation failed: {e.json()}"
        logger.error(error_msg)
        raise SchemaDriftError(error_msg) from e
    except Exception as e:
        error_msg = f"Unexpected validation error: {str(e)}"
        logger.error(error_msg)
        raise SchemaDriftError(error_msg) from e


def validate_agent_output_file(file_path: str) -> AgentOutputSchema:
    """
    Validate Agent output from a file.
    
    Args:
        file_path: Path to file containing Agent output
        
    Returns:
        Validated AgentOutputSchema object
        
    Raises:
        SchemaDriftError: If validation fails
        FileNotFoundError: If file does not exist
        IOError: If file cannot be read
    """
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            content = f.read()
        return validate_llm_output(content)
    except FileNotFoundError:
        raise FileNotFoundError(f"File not found: {file_path}")
    except IOError as e:
        raise IOError(f"Error reading file {file_path}: {str(e)}")


if __name__ == '__main__':
    """
    CLI usage example for testing validation
    """
    import sys
    
    if len(sys.argv) < 2:
        print("Usage: python schema_enforcer.py <json_file_or_string>")
        sys.exit(1)
    
    input_data = sys.argv[1]
    
    try:
        # Try as file path first, then as raw string
        try:
            validated = validate_agent_output_file(input_data)
        except (FileNotFoundError, IOError):
            validated = validate_llm_output(input_data)
        
        print("✓ Validation passed")
        print(f"  Version: {validated.version}")
        print(f"  Records: {len(validated.records)}")
        if validated.source:
            print(f"  Source: {validated.source}")
    except SchemaDriftError as e:
        print(f"✗ Validation failed: {e}")
        sys.exit(1)

