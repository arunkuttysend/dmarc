# Tests for Flask API health endpoints
import pytest
import json
from unittest.mock import patch

def test_health_check_success(client, mock_elasticsearch, mock_redis):
    """Test successful health check"""
    response = client.get('/api/health')

    assert response.status_code == 200
    data = json.loads(response.data)

    assert data['status'] == 'healthy'
    assert 'timestamp' in data
    assert 'services' in data
    assert data['services']['elasticsearch']['status'] == 'green'
    assert data['services']['redis']['status'] == 'healthy'

def test_health_check_elasticsearch_down(client, mock_redis):
    """Test health check with Elasticsearch down"""
    with patch('app.es', None):
        response = client.get('/api/health')

        assert response.status_code == 200
        data = json.loads(response.data)

        assert data['services']['elasticsearch']['status'] == 'error'
        assert not data['services']['elasticsearch']['connected']

def test_health_check_redis_down(client, mock_elasticsearch):
    """Test health check with Redis down"""
    with patch('app.redis_client', None):
        response = client.get('/api/health')

        assert response.status_code == 200
        data = json.loads(response.data)

        assert data['services']['redis']['status'] == 'error'
        assert not data['services']['redis']['connected']

def test_statistics_endpoint(client, mock_elasticsearch, mock_redis):
    """Test statistics endpoint"""
    response = client.get('/api/stats')

    assert response.status_code == 200
    data = json.loads(response.data)

    assert 'total_reports' in data
    assert 'total_indices' in data
    assert 'total_size_kb' in data
    assert 'indices' in data
    assert data['total_reports'] == 300  # 100 + 200 from mock

def test_statistics_elasticsearch_unavailable(client, mock_redis):
    """Test statistics endpoint with Elasticsearch unavailable"""
    with patch('app.es', None):
        response = client.get('/api/stats')

        assert response.status_code == 503
        data = json.loads(response.data)
        assert 'error' in data

def test_reports_endpoint(client, mock_elasticsearch, mock_redis):
    """Test reports endpoint"""
    response = client.get('/api/reports')

    assert response.status_code == 200
    data = json.loads(response.data)

    assert 'reports' in data
    assert 'total' in data
    assert 'page' in data
    assert 'size' in data
    assert 'pages' in data
    assert len(data['reports']) == 1
    assert data['total'] == 50

def test_reports_with_filters(client, mock_elasticsearch, mock_redis):
    """Test reports endpoint with filters"""
    response = client.get('/api/reports?org_name=Google&page=2&size=10')

    assert response.status_code == 200
    data = json.loads(response.data)

    assert data['page'] == 2
    assert data['size'] == 10

def test_organizations_aggregation(client, mock_elasticsearch, mock_redis):
    """Test organizations aggregation endpoint"""
    response = client.get('/api/aggregations/organizations')

    assert response.status_code == 200
    data = json.loads(response.data)

    assert 'organizations' in data
    assert len(data['organizations']) == 2
    assert data['organizations'][0]['organization'] == 'Google'
    assert data['organizations'][0]['reports'] == 100

def test_dispositions_aggregation(client, mock_elasticsearch, mock_redis):
    """Test dispositions aggregation endpoint"""
    response = client.get('/api/aggregations/dispositions')

    assert response.status_code == 200
    data = json.loads(response.data)

    assert 'dispositions' in data
    assert len(data['dispositions']) == 2
    assert data['dispositions'][0]['disposition'] == 'pass'
    assert data['dispositions'][0]['count'] == 150

def test_timeline_aggregation(client, mock_elasticsearch, mock_redis):
    """Test timeline aggregation endpoint"""
    response = client.get('/api/aggregations/timeline')

    assert response.status_code == 200
    data = json.loads(response.data)

    assert 'timeline' in data
    assert len(data['timeline']) == 2
    assert data['timeline'][0]['date'] == '2024-01-01'
    assert data['timeline'][0]['count'] == 50

def test_process_report(client, mock_elasticsearch, mock_redis):
    """Test report processing endpoint"""
    test_report = {
        'org_name': 'Test Organization',
        'policy_published': {'domain': 'test.com'},
        'records': []
    }

    response = client.post('/api/reports/process',
                          data=json.dumps(test_report),
                          content_type='application/json')

    assert response.status_code == 200
    data = json.loads(response.data)

    assert data['success'] is True
    assert 'id' in data
    assert 'index' in data

def test_process_report_no_data(client, mock_elasticsearch, mock_redis):
    """Test report processing with no data"""
    response = client.post('/api/reports/process',
                          content_type='application/json')

    assert response.status_code == 400
    data = json.loads(response.data)
    assert 'error' in data

def test_search_reports(client, mock_elasticsearch, mock_redis):
    """Test search endpoint"""
    search_query = {
        'query': {
            'match': {'org_name': 'Google'}
        }
    }

    response = client.post('/api/search',
                          data=json.dumps(search_query),
                          content_type='application/json')

    assert response.status_code == 200
    data = json.loads(response.data)
    assert 'hits' in data

def test_search_reports_no_query(client, mock_elasticsearch, mock_redis):
    """Test search endpoint without query"""
    response = client.post('/api/search',
                          data=json.dumps({}),
                          content_type='application/json')

    assert response.status_code == 400
    data = json.loads(response.data)
    assert 'error' in data

def test_404_endpoint(client):
    """Test 404 error handling"""
    response = client.get('/api/nonexistent')

    assert response.status_code == 404
    data = json.loads(response.data)
    assert 'error' in data
