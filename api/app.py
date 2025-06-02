from flask import Flask, request, jsonify
from flask_cors import CORS
from flask_socketio import SocketIO, emit
from elasticsearch import Elasticsearch
import redis
import json
import logging
from datetime import datetime, timedelta
import os
from threading import Timer
import uuid
from config import Config
from werkzeug.exceptions import BadRequest

# Initialize Flask app
app = Flask(__name__)
app.config.from_object(Config)
CORS(app, origins=app.config['CORS_ORIGINS'])
socketio = SocketIO(app, cors_allowed_origins=app.config['CORS_ORIGINS'])

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Initialize connections with error handling
es = None
redis_client = None

def init_connections():
    """Initialize Elasticsearch and Redis connections"""
    global es, redis_client
    try:
        es = Elasticsearch([{
            'host': app.config['ELASTICSEARCH_HOST'],
            'port': app.config['ELASTICSEARCH_PORT'],
            'scheme': app.config['ELASTICSEARCH_SCHEME']
        }])
        redis_client = redis.Redis(
            host=app.config['REDIS_HOST'],
            port=app.config['REDIS_PORT'],
            decode_responses=True
        )
        logger.info("Connected to Elasticsearch and Redis")
        return True
    except Exception as e:
        logger.error(f"Failed to connect to services: {e}")
        return False

# Initialize connections
init_connections()

# Configuration
ES_INDEX_PREFIX = "parsedmarc-aggregate"
CACHE_TTL = app.config.get('CACHE_TTL', 300)

# Helper functions
def get_cache_key(endpoint, params):
    """Generate cache key for request"""
    return f"api:{endpoint}:{hash(str(params))}"

def cache_response(key, data, ttl=CACHE_TTL):
    """Cache response data"""
    if redis_client:
        try:
            redis_client.setex(key, ttl, json.dumps(data))
        except Exception as e:
            logger.warning(f"Cache write failed: {e}")

def get_cached_response(key):
    """Get cached response"""
    if redis_client:
        try:
            cached = redis_client.get(key)
            return json.loads(cached) if cached else None
        except Exception as e:
            logger.warning(f"Cache read failed: {e}")
    return None

def emit_live_update(event_type, data):
    """Emit live updates via WebSocket"""
    try:
        socketio.emit('live_update', {
            'type': event_type,
            'data': data,
            'timestamp': datetime.utcnow().isoformat()
        })
    except Exception as e:
        logger.error(f"WebSocket emit failed: {e}")

# API Routes
@app.route('/api/health', methods=['GET'])
def health_check():
    """Health check endpoint"""
    status = {
        'status': 'healthy',
        'timestamp': datetime.utcnow().isoformat(),
        'services': {}
    }

    # Check Elasticsearch
    try:
        if es:
            es_health = es.cluster.health()
            status['services']['elasticsearch'] = {
                'status': es_health['status'],
                'connected': True
            }
        else:
            status['services']['elasticsearch'] = {'status': 'error', 'connected': False}
    except Exception as e:
        status['services']['elasticsearch'] = {'status': 'error', 'error': str(e)}

    # Check Redis
    try:
        if redis_client:
            redis_ping = redis_client.ping()
            status['services']['redis'] = {
                'status': 'healthy' if redis_ping else 'error',
                'connected': redis_ping
            }
        else:
            status['services']['redis'] = {'status': 'error', 'connected': False}
    except Exception as e:
        status['services']['redis'] = {'status': 'error', 'error': str(e)}

    return jsonify(status)

@app.route('/api/stats', methods=['GET'])
def get_statistics():
    """Get DMARC statistics"""
    if not es:
        return jsonify({'error': 'Elasticsearch not available'}), 503

    cache_key = get_cache_key('stats', {})
    cached = get_cached_response(cache_key)
    if cached:
        return jsonify(cached)

    try:
        # Get index statistics
        indices = es.cat.indices(index=f"{ES_INDEX_PREFIX}-*", format='json')

        total_docs = sum(int(idx.get('docs.count', 0)) for idx in indices)
        total_size = sum(float(idx.get('store.size', '0b').replace('kb', '').replace('mb', '').replace('b', '') or 0)
                        for idx in indices)

        stats = {
            'total_reports': total_docs,
            'total_indices': len(indices),
            'total_size_kb': round(total_size, 2),
            'indices': indices
        }

        cache_response(cache_key, stats)
        return jsonify(stats)

    except Exception as e:
        logger.error(f"Error getting statistics: {e}")
        return jsonify({'error': str(e)}), 500

@app.route('/api/reports', methods=['GET'])
def get_reports():
    """Get DMARC reports with filtering and pagination"""
    if not es:
        return jsonify({'error': 'Elasticsearch not available'}), 503

    try:
        # Get query parameters
        page = int(request.args.get('page', 1))
        size = min(int(request.args.get('size', 20)), app.config.get('MAX_PAGE_SIZE', 100))
        org_name = request.args.get('org_name')
        domain = request.args.get('domain')
        disposition = request.args.get('disposition')
        date_from = request.args.get('date_from')
        date_to = request.args.get('date_to')

        # Build Elasticsearch query
        query = {"match_all": {}}
        filters = []

        if org_name:
            filters.append({"term": {"org_name.keyword": org_name}})
        if domain:
            filters.append({"term": {"policy_published.domain.keyword": domain}})
        if disposition:
            filters.append({"nested": {
                "path": "records",
                "query": {"term": {"records.policy_evaluated.disposition.keyword": disposition}}
            }})
        if date_from or date_to:
            date_range = {}
            if date_from:
                date_range["gte"] = date_from
            if date_to:
                date_range["lte"] = date_to
            filters.append({"range": {"@timestamp": date_range}})

        if filters:
            query = {"bool": {"filter": filters}}

        # Execute search
        from_index = (page - 1) * size
        response = es.search(
            index=f"{ES_INDEX_PREFIX}-*",
            body={
                "query": query,
                "size": size,
                "from": from_index,
                "sort": [{"@timestamp": {"order": "desc"}}]
            }
        )

        # Format response
        reports = []
        for hit in response['hits']['hits']:
            report = hit['_source']
            report['_id'] = hit['_id']
            reports.append(report)

        result = {
            'reports': reports,
            'total': response['hits']['total']['value'],
            'page': page,
            'size': size,
            'pages': (response['hits']['total']['value'] + size - 1) // size
        }

        return jsonify(result)

    except Exception as e:
        logger.error(f"Error getting reports: {e}")
        return jsonify({'error': str(e)}), 500

@app.route('/api/aggregations/organizations', methods=['GET'])
def get_top_organizations():
    """Get top reporting organizations"""
    if not es:
        return jsonify({'error': 'Elasticsearch not available'}), 503

    cache_key = get_cache_key('top_orgs', request.args.to_dict())
    cached = get_cached_response(cache_key)
    if cached:
        return jsonify(cached)

    try:
        size = int(request.args.get('size', 10))

        response = es.search(
            index=f"{ES_INDEX_PREFIX}-*",
            body={
                "size": 0,
                "aggs": {
                    "top_organizations": {
                        "terms": {
                            "field": "org_name.keyword",
                            "size": size
                        }
                    }
                }
            }
        )

        organizations = []
        for bucket in response['aggregations']['top_organizations']['buckets']:
            organizations.append({
                'organization': bucket['key'],
                'reports': bucket['doc_count']
            })

        result = {'organizations': organizations}
        cache_response(cache_key, result)
        return jsonify(result)

    except Exception as e:
        logger.error(f"Error getting organizations: {e}")
        return jsonify({'error': str(e)}), 500

@app.route('/api/aggregations/dispositions', methods=['GET'])
def get_disposition_stats():
    """Get DMARC disposition statistics"""
    if not es:
        return jsonify({'error': 'Elasticsearch not available'}), 503

    cache_key = get_cache_key('dispositions', {})
    cached = get_cached_response(cache_key)
    if cached:
        return jsonify(cached)

    try:
        response = es.search(
            index=f"{ES_INDEX_PREFIX}-*",
            body={
                "size": 0,
                "aggs": {
                    "dispositions": {
                        "nested": {"path": "records"},
                        "aggs": {
                            "disposition_breakdown": {
                                "terms": {
                                    "field": "records.policy_evaluated.disposition.keyword"
                                }
                            }
                        }
                    }
                }
            }
        )

        dispositions = []
        for bucket in response['aggregations']['dispositions']['disposition_breakdown']['buckets']:
            dispositions.append({
                'disposition': bucket['key'],
                'count': bucket['doc_count']
            })

        result = {'dispositions': dispositions}
        cache_response(cache_key, result)
        return jsonify(result)

    except Exception as e:
        logger.error(f"Error getting dispositions: {e}")
        return jsonify({'error': str(e)}), 500

@app.route('/api/aggregations/timeline', methods=['GET'])
def get_timeline_data():
    """Get timeline data for reports"""
    if not es:
        return jsonify({'error': 'Elasticsearch not available'}), 503

    try:
        interval = request.args.get('interval', 'day')
        date_from = request.args.get('date_from')
        date_to = request.args.get('date_to')

        # Build date range
        date_range = {}
        if date_from:
            date_range["gte"] = date_from
        if date_to:
            date_range["lte"] = date_to
        else:
            # Default to last 30 days
            date_range["gte"] = (datetime.utcnow() - timedelta(days=30)).isoformat()

        query = {"range": {"@timestamp": date_range}} if date_range else {"match_all": {}}

        response = es.search(
            index=f"{ES_INDEX_PREFIX}-*",
            body={
                "size": 0,
                "query": query,
                "aggs": {
                    "timeline": {
                        "date_histogram": {
                            "field": "@timestamp",
                            "calendar_interval": interval,
                            "format": "yyyy-MM-dd"
                        }
                    }
                }
            }
        )

        timeline = []
        for bucket in response['aggregations']['timeline']['buckets']:
            timeline.append({
                'date': bucket['key_as_string'],
                'count': bucket['doc_count']
            })

        return jsonify({'timeline': timeline})

    except Exception as e:
        logger.error(f"Error getting timeline: {e}")
        return jsonify({'error': str(e)}), 500

@app.route('/api/reports/process', methods=['POST'])
def process_report():
    """Process a new DMARC report"""
    if not es:
        return jsonify({'error': 'Elasticsearch not available'}), 503

    # Robustly handle empty or invalid JSON
    if not request.data or request.data.strip() == b'':
        return jsonify({'error': 'No data provided'}), 400
    data = request.get_json(silent=True)
    if data is None:
        return jsonify({'error': 'Invalid or empty JSON'}), 400
    if not data:
        return jsonify({'error': 'No data provided'}), 400

    # Add processing metadata
    data['@timestamp'] = datetime.utcnow().isoformat()
    data['processed_by'] = 'dmarc-api'
    data['processing_id'] = str(uuid.uuid4())

    # Index the document
    result = es.index(
        index=f"{ES_INDEX_PREFIX}-{datetime.utcnow().strftime('%Y.%m.%d')}",
        body=data
    )

    # Clear relevant caches
    if redis_client:
        keys = redis_client.keys("api:*")
        if keys:
            redis_client.delete(*keys)

    # Emit live update
    emit_live_update('new_report', {
        'id': result['_id'],
        'org_name': data.get('org_name'),
        'domain': data.get('policy_published', {}).get('domain'),
        'timestamp': data['@timestamp']
    })

    return jsonify({
        'success': True,
        'id': result['_id'],
        'index': result['_index']
    })

@app.route('/api/search', methods=['POST'])
def search_reports():
    """Advanced search for DMARC reports"""
    if not es:
        return jsonify({'error': 'Elasticsearch not available'}), 503

    try:
        search_data = request.get_json()

        if not search_data or 'query' not in search_data:
            return jsonify({'error': 'Query required'}), 400

        # Execute the search
        response = es.search(
            index=f"{ES_INDEX_PREFIX}-*",
            body=search_data['query']
        )

        return jsonify(response)

    except Exception as e:
        logger.error(f"Error in search: {e}")
        return jsonify({'error': str(e)}), 500

# WebSocket Events
@socketio.on('connect')
def on_connect():
    """Handle WebSocket connection"""
    logger.info(f"Client connected: {request.sid}")
    emit('status', {'message': 'Connected to DMARC Analyzer'})

@socketio.on('disconnect')
def on_disconnect():
    """Handle WebSocket disconnection"""
    logger.info(f"Client disconnected: {request.sid}")

@socketio.on('subscribe_updates')
def on_subscribe_updates():
    """Subscribe to live updates"""
    logger.info(f"Client subscribed to updates: {request.sid}")
    emit('status', {'message': 'Subscribed to live updates'})

# Background tasks
def simulate_live_data():
    """Simulate live DMARC data for demonstration"""
    import random

    organizations = ['Google', 'Microsoft', 'Yahoo', 'Mimecast', 'Proofpoint']
    domains = ['example.com', 'business.co', 'company.org', 'domain.net']
    dispositions = ['pass', 'fail', 'quarantine', 'reject']

    while True:
        try:
            # Simulate a new report every 30 seconds
            socketio.sleep(30)

            fake_report = {
                'org_name': random.choice(organizations),
                'domain': random.choice(domains),
                'disposition': random.choice(dispositions),
                'count': random.randint(1, 100),
                'timestamp': datetime.utcnow().isoformat()
            }

            emit_live_update('simulated_report', fake_report)

        except Exception as e:
            logger.error(f"Error in background task: {e}")
            break

# Error handlers
@app.errorhandler(404)
def not_found(error):
    return jsonify({'error': 'Endpoint not found'}), 404

@app.errorhandler(500)
def internal_error(error):
    return jsonify({'error': 'Internal server error'}), 500

@app.errorhandler(BadRequest)
def handle_bad_request(error):
    logger.error(f"BadRequest: {error}")
    return jsonify({'error': 'Invalid or malformed JSON'}), 400

@app.errorhandler(400)
def handle_400_error(error):
    logger.error(f"400 Error: {error}")
    return jsonify({'error': 'Invalid or malformed JSON'}), 400

@app.errorhandler(Exception)
def handle_all_exceptions(error):
    if isinstance(error, BadRequest) or getattr(error, 'code', None) == 400:
        logger.error(f"Generic 400 handler: {error}")
        return jsonify({'error': 'Invalid or malformed JSON'}), 400
    logger.error(f"Unhandled Exception: {error}")
    return jsonify({'error': 'Internal server error'}), 500

if __name__ == '__main__':
    # Start background simulation
    import threading
    bg_thread = threading.Thread(target=simulate_live_data)
    bg_thread.daemon = True
    bg_thread.start()

    # Start the Flask-SocketIO server
    socketio.run(app, host='0.0.0.0', port=5000, debug=True)
