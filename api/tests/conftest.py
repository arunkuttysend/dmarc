# Test configuration for Flask API
import pytest
import os
import sys
from unittest.mock import Mock, patch

# Add the api directory to Python path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from app import app, init_connections
from config import TestingConfig

@pytest.fixture
def client():
    """Create a test client for the Flask application"""
    app.config.from_object(TestingConfig)
    app.config['TESTING'] = True

    with app.test_client() as client:
        with app.app_context():
            yield client

@pytest.fixture
def mock_elasticsearch():
    """Mock Elasticsearch client"""
    with patch('app.es') as mock_es:
        # Mock health check
        mock_es.cluster.health.return_value = {'status': 'green'}

        # Mock index statistics
        mock_es.cat.indices.return_value = [
            {'docs.count': '100', 'store.size': '1mb', 'index': 'parsedmarc-aggregate-2024.01.01'},
            {'docs.count': '200', 'store.size': '2mb', 'index': 'parsedmarc-aggregate-2024.01.02'}
        ]

        # Mock search response
        mock_es.search.return_value = {
            'hits': {
                'total': {'value': 50},
                'hits': [
                    {
                        '_id': 'test-id-1',
                        '_source': {
                            'org_name': 'Test Org',
                            'policy_published': {'domain': 'example.com'},
                            '@timestamp': '2024-01-01T00:00:00Z'
                        }
                    }
                ]
            },
            'aggregations': {
                'top_organizations': {
                    'buckets': [
                        {'key': 'Google', 'doc_count': 100},
                        {'key': 'Microsoft', 'doc_count': 80}
                    ]
                },
                'dispositions': {
                    'disposition_breakdown': {
                        'buckets': [
                            {'key': 'pass', 'doc_count': 150},
                            {'key': 'fail', 'doc_count': 30}
                        ]
                    }
                },
                'timeline': {
                    'buckets': [
                        {'key_as_string': '2024-01-01', 'doc_count': 50},
                        {'key_as_string': '2024-01-02', 'doc_count': 75}
                    ]
                }
            }
        }

        # Mock index operation
        mock_es.index.return_value = {
            '_id': 'new-doc-id',
            '_index': 'parsedmarc-aggregate-2024.01.01'
        }

        yield mock_es

@pytest.fixture
def mock_redis():
    """Mock Redis client"""
    with patch('app.redis_client') as mock_redis:
        mock_redis.ping.return_value = True
        mock_redis.get.return_value = None
        mock_redis.setex.return_value = True
        mock_redis.keys.return_value = []
        mock_redis.delete.return_value = 1
        yield mock_redis
