# DMARC Analyzer

A comprehensive DMARC report analyzer using `parsedmarc`, Elasticsearch, and Kibana for processing and visualizing DMARC aggregate reports.

## 🚀 Features

- **Automated DMARC Report Processing**: Continuously fetches and parses DMARC reports from IMAP
- **Elasticsearch Backend**: Powerful search and analytics engine for DMARC data
- **Kibana Dashboards**: Rich visualizations and data exploration
- **Redis Caching**: Performance optimization for API responses
- **Nginx Gateway**: Rate limiting and API routing
- **Docker Compose**: Complete containerized setup
- **Health Monitoring**: Built-in health checks and monitoring

## 📋 Prerequisites

- Docker and Docker Compose
- An email account that receives DMARC aggregate reports
- At least 4GB RAM (8GB recommended)
- 10GB+ disk space for data storage

## 🛠️ Quick Start

### 1. Clone and Setup

```bash
git clone <your-repo>
cd dmarc
make setup
```

### 2. Configure Environment

Edit the `.env` file with your IMAP credentials:

```bash
cp .env.example .env
# Edit .env with your IMAP settings
```

### 3. Start Services

```bash
make start
```

### 4. Verify Setup

```bash
make status
make health
```

## 🔧 Configuration

### IMAP Setup

Configure your IMAP settings in `.env`:

```env
IMAP_HOST=imap.gmail.com
IMAP_USER=dmarc-reports@yourdomain.com
IMAP_PASSWORD=your_app_specific_password
```

**Gmail Users**: Use App-Specific Passwords, not your regular password.

### Email Forwarding

Set up DMARC report forwarding to your designated email:

1. Add DMARC record with `rua=mailto:dmarc-reports@yourdomain.com`
2. Configure email forwarding from various providers to your IMAP account

## 🌐 Access URLs

- **Elasticsearch API**: http://localhost:9200
- **Kibana Dashboard**: http://localhost:5601
- **API Gateway**: http://localhost (Nginx proxy)
- **Redis**: localhost:6379

## 📊 API Usage

### Basic Search

```bash
curl -X GET "http://localhost:9200/parsedmarc-*/_search?pretty" \
  -H "Content-Type: application/json" \
  -d '{"query": {"match_all": {}}, "size": 10}'
```

### Filter by Disposition

```bash
curl -X GET "http://localhost:9200/parsedmarc-*/_search?pretty" \
  -H "Content-Type: application/json" \
  -d '{
    "query": {
      "bool": {
        "should": [
          {"match": {"policy_evaluated.disposition": "quarantine"}},
          {"match": {"policy_evaluated.disposition": "reject"}}
        ]
      }
    }
  }'
```

### Aggregate by Disposition

```bash
curl -X GET "http://localhost:9200/parsedmarc-*/_search?pretty" \
  -H "Content-Type: application/json" \
  -d '{
    "size": 0,
    "aggs": {
      "disposition_counts": {
        "terms": {
          "field": "policy_evaluated.disposition.keyword"
        }
      }
    }
  }'
```

### Time-Series Analysis

```bash
curl -X GET "http://localhost:9200/parsedmarc-*/_search?pretty" \
  -H "Content-Type: application/json" \
  -d '{
    "size": 0,
    "aggs": {
      "messages_over_time": {
        "date_histogram": {
          "field": "@timestamp",
          "interval": "day"
        }
      }
    },
    "query": {
      "range": {
        "@timestamp": {
          "gte": "now-7d"
        }
      }
    }
  }'
```

## 🔍 Monitoring and Maintenance

### View Logs

```bash
# All services
make logs

# Specific service
make logs-parsedmarc
make logs-elasticsearch
make logs-kibana
```

### Health Checks

```bash
make health
```

### Backup Data

```bash
make backup
```

### Clean Up

```bash
# Stop services
make stop

# Remove everything (including data)
make clean
```

## 📈 Performance Optimization

### Elasticsearch Tuning

- **Memory**: Allocated 2GB by default, increase for production
- **Shards**: Single shard per index for small datasets
- **Replicas**: 0 replicas for single-node setup

### Index Management

The system creates daily indices with the pattern `parsedmarc-aggregate-YYYY.MM.DD`. Consider implementing Index Lifecycle Management (ILM) for production.

### Redis Caching

Redis is configured for API response caching:
- 256MB memory limit
- LRU eviction policy
- Optimized for API response caching

## 🛡️ Security Considerations

### Development Setup
- Elasticsearch security disabled
- No authentication on services
- CORS enabled for development

### Production Recommendations
1. Enable Elasticsearch security
2. Configure authentication
3. Use environment variables for secrets
4. Implement proper firewall rules
5. Enable SSL/TLS

## 📝 Data Structure

DMARC reports are parsed into structured JSON with fields:

- `org_name`: Reporting organization
- `email`: Reporter email
- `extra_contact_info`: Additional contact info
- `report_id`: Unique report identifier
- `date_range`: Report time range
- `policy_published`: Published DMARC policy
- `records`: Array of individual records
  - `source_ip`: Source IP address
  - `count`: Message count
  - `policy_evaluated`: DMARC evaluation results
  - `identifiers`: Domain identifiers
  - `auth_results`: SPF/DKIM results

## 🔧 Troubleshooting

### Common Issues

1. **Elasticsearch won't start**
   - Check available memory (needs 1GB+)
   - Verify Docker has enough resources

2. **parsedmarc not connecting**
   - Verify IMAP credentials
   - Check firewall settings
   - Review parsedmarc logs

3. **No data appearing**
   - Confirm DMARC reports are in the inbox
   - Check parsedmarc processing logs
   - Verify Elasticsearch index creation

### Log Locations

```bash
# Container logs
docker compose logs <service_name>

# Persistent logs
./logs/nginx/          # Nginx logs
./logs/parsedmarc/     # parsedmarc logs (if mounted)
```

## 🚀 Development

### Adding Frontend

The Elasticsearch API is exposed and ready for frontend integration:

```javascript
// Example frontend API call
fetch('http://localhost:9200/parsedmarc-*/_search', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({
    query: { match_all: {} },
    size: 100
  })
})
```

### Custom Dashboards

Use Kibana at http://localhost:5601 to create:
- DMARC compliance dashboards
- Threat analysis visualizations
- Sender reputation reports
- Time-series trend analysis

## 📚 Additional Resources

- [parsedmarc Documentation](https://github.com/domainaware/parsedmarc)
- [Elasticsearch API Reference](https://www.elastic.co/guide/en/elasticsearch/reference/current/rest-apis.html)
- [DMARC Specification](https://tools.ietf.org/html/rfc7489)
- [Kibana User Guide](https://www.elastic.co/guide/en/kibana/current/index.html)

## 📄 License

MIT License - see LICENSE file for details.
# dmarc
