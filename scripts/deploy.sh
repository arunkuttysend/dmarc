#!/bin/bash

# DMARC Analyzer - Production Deployment Script
# This script helps deploy the DMARC analyzer to production environments

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
DOCKER_COMPOSE_PROD="docker-compose.prod.yml"
BACKUP_DIR="./backups/production"

log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
}

# Check if production environment file exists
check_production_config() {
    if [ ! -f ".env.production" ]; then
        log_error "Production environment file .env.production not found"
        log_info "Creating template..."

        cat > .env.production << EOF
# Production Environment Configuration
# WARNING: Update all values before deploying

# IMAP Configuration
IMAP_HOST=imap.yourdomain.com
IMAP_USER=dmarc-reports@yourdomain.com
IMAP_PASSWORD=CHANGE_THIS_PASSWORD

# Security
KIBANA_PASSWORD=CHANGE_THIS_STRONG_PASSWORD
ELASTICSEARCH_PASSWORD=CHANGE_THIS_STRONG_PASSWORD

# Performance
ES_MEM_LIMIT=4g
ES_JAVA_OPTS=-Xms2g -Xmx4g

# SSL Configuration (if using)
SSL_CERT_PATH=/etc/ssl/certs/dmarc-analyzer.crt
SSL_KEY_PATH=/etc/ssl/private/dmarc-analyzer.key

# Monitoring
ENABLE_MONITORING=true
ELASTICSEARCH_EXPORTER_ENABLED=true

# Backup
BACKUP_ENABLED=true
BACKUP_SCHEDULE="0 2 * * *"

# Network
EXTERNAL_PORT=443
INTERNAL_PORT=80

# Domain
DOMAIN=dmarc-analyzer.yourdomain.com
EOF

        log_warning "Created .env.production template"
        log_warning "Please edit .env.production with your production settings before deploying"
        exit 1
    fi
}

# Create production docker-compose file
create_production_compose() {
    if [ ! -f "$DOCKER_COMPOSE_PROD" ]; then
        log_info "Creating production docker-compose file..."

        cat > "$DOCKER_COMPOSE_PROD" << 'EOF'
version: '3.8'

services:
  elasticsearch:
    image: docker.elastic.co/elasticsearch/elasticsearch:8.11.1
    container_name: dmarc_elasticsearch_prod
    environment:
      - discovery.type=single-node
      - ES_JAVA_OPTS=${ES_JAVA_OPTS}
      - xpack.security.enabled=true
      - xpack.security.enrollment.enabled=false
      - ELASTIC_PASSWORD=${ELASTICSEARCH_PASSWORD}
      - bootstrap.memory_lock=true
      - cluster.routing.allocation.disk.threshold_enabled=true
      - cluster.routing.allocation.disk.watermark.low=85%
      - cluster.routing.allocation.disk.watermark.high=90%
      - cluster.routing.allocation.disk.watermark.flood_stage=95%
    ulimits:
      memlock:
        soft: -1
        hard: -1
    ports:
      - "127.0.0.1:9200:9200"
    volumes:
      - esdata_prod:/usr/share/elasticsearch/data
      - ./config/elasticsearch.prod.yml:/usr/share/elasticsearch/config/elasticsearch.yml:ro
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "curl -u elastic:${ELASTICSEARCH_PASSWORD} -f http://localhost:9200/_cluster/health || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s
    networks:
      - dmarc-network
    logging:
      driver: "json-file"
      options:
        max-size: "100m"
        max-file: "3"

  kibana:
    image: docker.elastic.co/kibana/kibana:8.11.1
    container_name: dmarc_kibana_prod
    environment:
      - ELASTICSEARCH_HOSTS=http://elasticsearch:9200
      - ELASTICSEARCH_USERNAME=kibana_system
      - ELASTICSEARCH_PASSWORD=${KIBANA_PASSWORD}
      - SERVER_NAME=${DOMAIN}
      - SERVER_HOST=0.0.0.0
      - xpack.security.enabled=true
    ports:
      - "127.0.0.1:5601:5601"
    volumes:
      - ./config/kibana.prod.yml:/usr/share/kibana/config/kibana.yml:ro
      - kibana_data_prod:/usr/share/kibana/data
    depends_on:
      elasticsearch:
        condition: service_healthy
    restart: unless-stopped
    networks:
      - dmarc-network
    logging:
      driver: "json-file"
      options:
        max-size: "100m"
        max-file: "3"

  parsedmarc:
    image: ghcr.io/domainaware/parsedmarc:latest
    container_name: dmarc_parsedmarc_prod
    volumes:
      - ./config/parsedmarc.prod.ini:/etc/parsedmarc.ini:ro
      - parsedmarc_logs_prod:/var/log/parsedmarc
      - parsedmarc_output_prod:/opt/parsedmarc/output
    command: ["-c", "/etc/parsedmarc.ini", "--continuous"]
    depends_on:
      elasticsearch:
        condition: service_healthy
    restart: unless-stopped
    environment:
      - TZ=UTC
      - PYTHONUNBUFFERED=1
    networks:
      - dmarc-network
    logging:
      driver: "json-file"
      options:
        max-size: "100m"
        max-file: "5"

  nginx:
    image: nginx:1.25-alpine
    container_name: dmarc_nginx_prod
    ports:
      - "${EXTERNAL_PORT:-443}:443"
      - "${INTERNAL_PORT:-80}:80"
    volumes:
      - ./config/nginx.prod.conf:/etc/nginx/nginx.conf:ro
      - ./ssl:/etc/nginx/ssl:ro
      - ./logs/nginx:/var/log/nginx
    depends_on:
      - elasticsearch
      - kibana
    restart: unless-stopped
    networks:
      - dmarc-network
    logging:
      driver: "json-file"
      options:
        max-size: "50m"
        max-file: "3"

  elasticsearch-exporter:
    image: quay.io/prometheuscommunity/elasticsearch-exporter:latest
    container_name: dmarc_es_exporter_prod
    command:
      - '--es.uri=http://elasticsearch:9200'
      - '--es.username=elastic'
      - '--es.password=${ELASTICSEARCH_PASSWORD}'
    ports:
      - "127.0.0.1:9114:9114"
    depends_on:
      - elasticsearch
    restart: unless-stopped
    networks:
      - dmarc-network
    profiles:
      - monitoring

volumes:
  esdata_prod:
    driver: local
  kibana_data_prod:
    driver: local
  parsedmarc_logs_prod:
    driver: local
  parsedmarc_output_prod:
    driver: local

networks:
  dmarc-network:
    driver: bridge
EOF

        log_success "Created production docker-compose file"
    fi
}

# Create production configuration files
create_production_configs() {
    log_info "Creating production configuration files..."

    # Elasticsearch production config
    cat > config/elasticsearch.prod.yml << 'EOF'
cluster.name: "dmarc-cluster-prod"
node.name: "dmarc-node-prod"
path.data: /usr/share/elasticsearch/data
path.logs: /usr/share/elasticsearch/logs

network.host: 0.0.0.0
http.port: 9200
discovery.type: single-node

# Security
xpack.security.enabled: true
xpack.security.enrollment.enabled: false

# Performance
bootstrap.memory_lock: true
indices.memory.index_buffer_size: 30%
indices.memory.min_index_buffer_size: 96mb

# Monitoring
xpack.monitoring.collection.enabled: true

# Index management
action.auto_create_index: "+parsedmarc-*,-*"
cluster.routing.allocation.disk.threshold_enabled: true
cluster.routing.allocation.disk.watermark.low: 85%
cluster.routing.allocation.disk.watermark.high: 90%
cluster.routing.allocation.disk.watermark.flood_stage: 95%

# Thread pools
thread_pool.write.queue_size: 1000
thread_pool.search.queue_size: 1000
EOF

    # Kibana production config
    cat > config/kibana.prod.yml << 'EOF'
server.name: "dmarc-kibana-prod"
server.host: "0.0.0.0"
server.port: 5601

elasticsearch.hosts: ["http://elasticsearch:9200"]
elasticsearch.username: "kibana_system"
elasticsearch.password: "${KIBANA_PASSWORD}"

xpack.security.enabled: true
xpack.encryptedSavedObjects.encryptionKey: "CHANGE_THIS_32_CHAR_ENCRYPTION_KEY"

monitoring.kibana.collection.enabled: true

server.maxPayload: 1048576
elasticsearch.requestTimeout: 60000
elasticsearch.pingTimeout: 1500

kibana.defaultAppId: "discover"
data.search.timeout: 60000

logging.appenders.file.type: file
logging.appenders.file.fileName: /usr/share/kibana/logs/kibana.log
logging.appenders.file.layout.type: json
logging.root.level: warn
EOF

    # parsedmarc production config
    cat > config/parsedmarc.prod.ini << 'EOF'
[general]
save_aggregate = True
save_forensic = True
output = /opt/parsedmarc/output
silent = False
log_file = /var/log/parsedmarc/parsedmarc.log

[imap]
host = ${IMAP_HOST}
user = ${IMAP_USER}
password = ${IMAP_PASSWORD}
ssl = True
port = 993
watch = True
delete_reports = False
reports_folder = INBOX
batch_size = 20
test = False
since = 30

[elasticsearch]
host = elasticsearch
port = 9200
ssl = False
verify_certs = False
username = elastic
password = ${ELASTICSEARCH_PASSWORD}
index_suffix = daily
number_of_shards = 2
number_of_replicas = 1
monthly_indexes = True

[logging]
log_file = /var/log/parsedmarc/parsedmarc.log
log_level = INFO

[splunk]
enabled = False

[kafka]
enabled = False

[smtp]
enabled = False
EOF

    log_success "Created production configuration files"
}

# Backup current data
backup_data() {
    if [ "$1" = "--skip-backup" ]; then
        log_warning "Skipping backup as requested"
        return 0
    fi

    log_info "Creating backup of current data..."
    mkdir -p "$BACKUP_DIR"

    local backup_file="$BACKUP_DIR/elasticsearch-$(date +%Y%m%d-%H%M%S).tar.gz"

    if docker volume inspect dmarc_esdata &> /dev/null; then
        docker run --rm \
            -v dmarc_esdata:/data \
            -v "$(pwd)/$BACKUP_DIR":/backup \
            alpine tar czf "/backup/$(basename "$backup_file")" -C /data .

        log_success "Backup created: $backup_file"
    else
        log_warning "No existing data volume found, skipping backup"
    fi
}

# Deploy to production
deploy() {
    log_info "Deploying DMARC Analyzer to production..."

    # Stop development environment if running
    if docker-compose ps | grep -q "Up"; then
        log_info "Stopping development environment..."
        docker-compose down
    fi

    # Start production environment
    log_info "Starting production services..."
    docker-compose -f "$DOCKER_COMPOSE_PROD" --env-file .env.production up -d

    # Wait for services
    log_info "Waiting for services to be ready..."
    sleep 30

    # Verify deployment
    if curl -s -u "elastic:${ELASTICSEARCH_PASSWORD}" "http://localhost:9200/_cluster/health" &> /dev/null; then
        log_success "Production deployment successful!"
        log_info "Services are running:"
        echo "  - Elasticsearch: https://${DOMAIN:-localhost}:9200"
        echo "  - Kibana: https://${DOMAIN:-localhost}:5601"
        echo "  - Monitoring: http://localhost:9114/metrics"
    else
        log_error "Production deployment failed!"
        exit 1
    fi
}

# Main function
main() {
    case "${1:-help}" in
        "check")
            check_production_config
            log_success "Production configuration check passed"
            ;;
        "prepare")
            check_production_config
            create_production_compose
            create_production_configs
            log_success "Production environment prepared"
            log_warning "Please review and update:"
            echo "  - .env.production"
            echo "  - config/*.prod.yml files"
            echo "  - SSL certificates in ./ssl/ directory"
            ;;
        "deploy")
            check_production_config
            backup_data "$2"
            deploy
            ;;
        "backup")
            backup_data
            ;;
        "status")
            docker-compose -f "$DOCKER_COMPOSE_PROD" ps
            ;;
        "logs")
            docker-compose -f "$DOCKER_COMPOSE_PROD" logs -f "${2:-}"
            ;;
        "stop")
            docker-compose -f "$DOCKER_COMPOSE_PROD" down
            ;;
        "restart")
            docker-compose -f "$DOCKER_COMPOSE_PROD" restart "${2:-}"
            ;;
        "help"|"-h"|"--help")
            echo "Usage: $0 [command]"
            echo
            echo "Commands:"
            echo "  check     - Check production configuration"
            echo "  prepare   - Prepare production environment files"
            echo "  deploy    - Deploy to production"
            echo "  backup    - Backup current data"
            echo "  status    - Show production service status"
            echo "  logs      - Show production logs"
            echo "  stop      - Stop production services"
            echo "  restart   - Restart production services"
            echo "  help      - Show this help"
            ;;
        *)
            log_error "Unknown command: $1"
            echo "Run '$0 help' for usage information"
            exit 1
            ;;
    esac
}

main "$@"
