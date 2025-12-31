#!/usr/bin/env python3
"""
Test script to validate trade format JSON files against the schema enforcer
"""
import sys
import os

# Add validation directory to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

try:
    from validation.schema_enforcer import validate_agent_output_file, SchemaDriftError
except ImportError as e:
    print(f"ERROR: Cannot import validation module: {e}")
    print("Please install dependencies: pip install -r validation/requirements.txt")
    sys.exit(1)

def test_validation(file_path):
    """Test validation of a single file"""
    print(f"\nTesting: {file_path}")
    try:
        validated = validate_agent_output_file(file_path)
        print(f"✓ Validation passed")
        print(f"  Version: {validated.version}")
        print(f"  Records: {len(validated.records)}")
        if validated.source:
            print(f"  Source: {validated.source}")
        return True
    except SchemaDriftError as e:
        print(f"✗ Validation failed: {e}")
        return False
    except Exception as e:
        print(f"✗ Error: {e}")
        return False

if __name__ == '__main__':
    base_dir = os.path.join(os.path.dirname(__file__), '..', 'sample-data')
    
    format1_json = os.path.join(base_dir, 'sample-trade-format1.json')
    format2_json = os.path.join(base_dir, 'sample-trade-format2.json')
    
    print("=" * 60)
    print("Validation Layer Test - Multi-Format Trade Data")
    print("=" * 60)
    
    results = []
    results.append(("Trade Format 1 (CSV)", test_validation(format1_json)))
    results.append(("Trade Format 2 (Pipe-delimited)", test_validation(format2_json)))
    
    print("\n" + "=" * 60)
    print("Summary:")
    print("=" * 60)
    for name, passed in results:
        status = "✓ PASS" if passed else "✗ FAIL"
        print(f"  {name}: {status}")
    
    all_passed = all(result[1] for result in results)
    sys.exit(0 if all_passed else 1)

