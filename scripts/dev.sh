#!/bin/bash

# DMARC Analyzer - Development Helper Script
# This script provides common development tasks

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
PROJECT_NAME="DMARC Analyzer"
REQUIRED_TOOLS=("docker" "docker-compose" "curl" "jq")

# Helper functions
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

# Check if required tools are installed
check_requirements() {
    log_info "Checking system requirements..."

    local missing_tools=()
    for tool in "${REQUIRED_TOOLS[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done

    if [ ${#missing_tools[@]} -ne 0 ]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        echo "Please install the missing tools and try again."

        if [[ "$OSTYPE" == "darwin"* ]]; then
            echo "On macOS, you can install them with:"
            echo "  brew install docker docker-compose curl jq"
        fi

        exit 1
    fi

    log_success "All required tools are installed"
}

# Check if Docker is running
check_docker() {
    if ! docker info &> /dev/null; then
        log_error "Docker is not running. Please start Docker and try again."
        exit 1
    fi
    log_success "Docker is running"
}

# Create necessary directories
setup_directories() {
    log_info "Setting up directory structure..."

    local dirs=(
        "logs/nginx"
        "logs/parsedmarc"
        "logs/elasticsearch"
        "logs/kibana"
        "backups"
        "scripts"
    )

    for dir in "${dirs[@]}"; do
        mkdir -p "$dir"
        log_success "Created directory: $dir"
    done
}

# Copy environment file if it doesn't exist
setup_environment() {
    if [ ! -f ".env" ]; then
        if [ -f ".env.example" ]; then
            cp .env.example .env
            log_warning "Created .env file from .env.example"
            log_warning "Please edit .env with your IMAP credentials before starting services"
        else
            log_error ".env.example file not found"
            exit 1
        fi
    else
        log_success ".env file already exists"
    fi
}

# Validate environment configuration
validate_config() {
    log_info "Validating configuration..."

    if [ ! -f ".env" ]; then
        log_error ".env file not found. Run setup first."
        return 1
    fi

    # Source the .env file
    set -a
    source .env
    set +a

    local required_vars=("IMAP_HOST" "IMAP_USER" "IMAP_PASSWORD")
    local missing_vars=()

    for var in "${required_vars[@]}"; do
        if [ -z "${!var}" ] || [ "${!var}" = "your_"* ]; then
            missing_vars+=("$var")
        fi
    done

    if [ ${#missing_vars[@]} -ne 0 ]; then
        log_error "Missing or incomplete environment variables: ${missing_vars[*]}"
        log_warning "Please edit .env file with your actual IMAP credentials"
        return 1
    fi

    log_success "Configuration is valid"
}

# Check service health
check_services() {
    log_info "Checking service health..."

    local services=("elasticsearch:9200" "kibana:5601" "nginx:80")
    local healthy_services=0

    for service in "${services[@]}"; do
        local name="${service%:*}"
        local port="${service#*:}"

        if curl -s "http://localhost:$port" &> /dev/null; then
            log_success "$name is healthy"
            ((healthy_services++))
        else
            log_warning "$name is not responding on port $port"
        fi
    done

    if [ $healthy_services -eq ${#services[@]} ]; then
        log_success "All services are healthy"
    else
        log_warning "$healthy_services/${#services[@]} services are healthy"
    fi
}

# Wait for services to be ready
wait_for_services() {
    log_info "Waiting for services to be ready..."

    local max_attempts=30
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        if curl -s "http://localhost:9200/_cluster/health" &> /dev/null; then
            log_success "Elasticsearch is ready"
            break
        fi

        echo -n "."
        sleep 2
        ((attempt++))
    done

    if [ $attempt -gt $max_attempts ]; then
        log_error "Timeout waiting for Elasticsearch to be ready"
        return 1
    fi

    # Wait a bit more for other services
    sleep 5
    log_success "Services are ready"
}

# Initialize Elasticsearch indices and templates
init_elasticsearch() {
    log_info "Initializing Elasticsearch..."

    # Create index template for parsedmarc
    curl -s -X PUT "http://localhost:9200/_index_template/parsedmarc-template" \
        -H "Content-Type: application/json" \
        -d '{
            "index_patterns": ["parsedmarc-*"],
            "template": {
                "settings": {
                    "number_of_shards": 1,
                    "number_of_replicas": 0,
                    "refresh_interval": "5s"
                },
                "mappings": {
                    "properties": {
                        "@timestamp": {"type": "date"},
                        "org_name": {"type": "keyword"},
                        "email": {"type": "keyword"},
                        "report_id": {"type": "keyword"},
                        "policy_published": {
                            "properties": {
                                "domain": {"type": "keyword"},
                                "p": {"type": "keyword"},
                                "sp": {"type": "keyword"},
                                "pct": {"type": "integer"}
                            }
                        },
                        "records": {
                            "type": "nested",
                            "properties": {
                                "source_ip": {"type": "ip"},
                                "count": {"type": "long"},
                                "policy_evaluated": {
                                    "properties": {
                                        "disposition": {"type": "keyword"},
                                        "dkim": {"type": "keyword"},
                                        "spf": {"type": "keyword"}
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }' > /dev/null

    if [ $? -eq 0 ]; then
        log_success "Elasticsearch index template created"
    else
        log_warning "Failed to create Elasticsearch index template"
    fi
}

# Setup Kibana index pattern
setup_kibana() {
    log_info "Setting up Kibana..."

    # Wait for Kibana to be ready
    local attempt=1
    while [ $attempt -le 20 ]; do
        if curl -s "http://localhost:5601/api/status" &> /dev/null; then
            break
        fi
        sleep 3
        ((attempt++))
    done

    # Create index pattern
    curl -s -X POST "http://localhost:5601/api/saved_objects/index-pattern/parsedmarc" \
        -H "Content-Type: application/json" \
        -H "kbn-xsrf: true" \
        -d '{
            "attributes": {
                "title": "parsedmarc-*",
                "timeFieldName": "@timestamp"
            }
        }' > /dev/null

    if [ $? -eq 0 ]; then
        log_success "Kibana index pattern created"
    else
        log_warning "Failed to create Kibana index pattern (may already exist)"
    fi
}

# Show service URLs
show_urls() {
    echo
    log_info "Service URLs:"
    echo "  📊 Elasticsearch API: http://localhost:9200"
    echo "  📈 Kibana Dashboard: http://localhost:5601"
    echo "  🌐 API Gateway: http://localhost"
    echo "  🔧 Redis: localhost:6379"
    echo
    log_info "Useful commands:"
    echo "  make status     - Check service status"
    echo "  make logs       - View all logs"
    echo "  make health     - Check service health"
    echo "  ./scripts/test-api.sh - Test API endpoints"
    echo
}

# Main function
main() {
    echo -e "${GREEN}🚀 $PROJECT_NAME - Development Setup${NC}"
    echo "========================================"

    case "${1:-setup}" in
        "check")
            check_requirements
            check_docker
            ;;
        "setup")
            check_requirements
            check_docker
            setup_directories
            setup_environment
            log_success "Setup complete!"
            log_warning "Next steps:"
            echo "  1. Edit .env file with your IMAP credentials"
            echo "  2. Run: make start"
            echo "  3. Run: ./scripts/dev.sh init"
            ;;
        "init")
            validate_config
            wait_for_services
            init_elasticsearch
            setup_kibana
            log_success "Initialization complete!"
            show_urls
            ;;
        "validate")
            validate_config
            check_services
            ;;
        "reset")
            log_warning "This will remove all data and reset the environment"
            read -p "Are you sure? [y/N] " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                docker-compose down -v
                docker system prune -f
                log_success "Environment reset complete"
            else
                log_info "Reset cancelled"
            fi
            ;;
        "help"|"-h"|"--help")
            echo "Usage: $0 [command]"
            echo
            echo "Commands:"
            echo "  setup     - Initial project setup (default)"
            echo "  check     - Check system requirements"
            echo "  init      - Initialize services after startup"
            echo "  validate  - Validate configuration and services"
            echo "  reset     - Reset environment (removes all data)"
            echo "  help      - Show this help"
            ;;
        *)
            log_error "Unknown command: $1"
            echo "Run '$0 help' for usage information"
            exit 1
            ;;
    esac
}

# Run main function with all arguments
main "$@"
