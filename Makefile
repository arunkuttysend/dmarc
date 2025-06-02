.PHONY: start stop restart logs status clean backup health setup

# Default target
all: setup start

# Setup the environment
setup:
	@echo "Setting up DMARC Analyzer..."
	@if [ ! -f .env ]; then cp .env.example .env && echo "Created .env file. Please edit it with your configuration."; fi
	@mkdir -p logs/nginx logs/parsedmarc logs/elasticsearch
	@docker network create dmarc-network 2>/dev/null || true
	@echo "Setup complete!"

# Start all services
start:
	@echo "Starting DMARC Analyzer services..."
	docker compose up -d
	@echo "Services started. Use 'make status' to check health."

# Stop all services
stop:
	@echo "Stopping DMARC Analyzer services..."
	docker compose down

# Restart all services
restart:
	@echo "Restarting DMARC Analyzer services..."
	docker compose restart

# Show logs for all services
logs:
	docker compose logs -f

# Show logs for specific service
logs-elasticsearch:
	docker compose logs -f elasticsearch

logs-kibana:
	docker compose logs -f kibana

logs-parsedmarc:
	docker compose logs -f parsedmarc

logs-nginx:
	docker compose logs -f nginx

logs-redis:
	docker compose logs -f redis

# Show status of all services
status:
	@echo "=== Container Status ==="
	docker compose ps
	@echo "\n=== Service Health ==="
	@make health

# Clean up everything (WARNING: This will delete all data)
clean:
	@echo "WARNING: This will delete all data including Elasticsearch indices!"
	@read -p "Are you sure? [y/N] " -n 1 -r; \
	if [[ $$REPLY =~ ^[Yy]$$ ]]; then \
		echo "\nCleaning up..."; \
		docker compose down -v; \
		docker system prune -f; \
		echo "Cleanup complete."; \
	else \
		echo "\nCancelled."; \
	fi

# Backup Elasticsearch data
backup:
	@echo "Creating backup of Elasticsearch data..."
	@mkdir -p backups
	docker run --rm \
		-v dmarc_esdata:/data \
		-v $(PWD)/backups:/backup \
		alpine tar czf /backup/elasticsearch-$(shell date +%Y%m%d-%H%M%S).tar.gz -C /data .
	@echo "Backup created in ./backups/"

# Restore Elasticsearch data from backup
restore:
	@echo "Available backups:"
	@ls -la backups/elasticsearch-*.tar.gz 2>/dev/null || echo "No backups found"
	@read -p "Enter backup filename: " backup; \
	if [ -f "backups/$$backup" ]; then \
		echo "Restoring from $$backup..."; \
		docker compose stop elasticsearch; \
		docker run --rm \
			-v dmarc_esdata:/data \
			-v $(PWD)/backups:/backup \
			alpine sh -c "rm -rf /data/* && tar xzf /backup/$$backup -C /data"; \
		docker compose start elasticsearch; \
		echo "Restore complete."; \
	else \
		echo "Backup file not found."; \
	fi

# Health check for all services
health:
	@echo "Checking Elasticsearch..."
	@curl -s http://localhost:9200/_cluster/health?pretty 2>/dev/null | jq -r '.status // "❌ Not responding"' || echo "❌ Elasticsearch not responding"
	@echo "Checking Kibana..."
	@curl -s http://localhost:5601/api/status 2>/dev/null | jq -r '.status.overall.level // "❌ Not responding"' || echo "❌ Kibana not responding"
	@echo "Checking Redis..."
	@docker exec dmarc_redis redis-cli ping 2>/dev/null || echo "❌ Redis not responding"
	@echo "Checking Nginx..."
	@curl -s http://localhost/health 2>/dev/null || echo "❌ Nginx not responding"

# Development helpers
dev-shell:
	docker exec -it dmarc_elasticsearch bash

kibana-shell:
	docker exec -it dmarc_kibana bash

parsedmarc-shell:
	docker exec -it dmarc_parsedmarc bash

# API testing helpers
test-api:
	@echo "Testing Elasticsearch API..."
	curl -X GET "http://localhost:9200/_cluster/health?pretty"

search-test:
	@echo "Testing search functionality..."
	curl -X GET "http://localhost:9200/parsedmarc-*/_search?pretty" -H "Content-Type: application/json" -d'{"query":{"match_all":{}},"size":5}'

# Update Docker images
update:
	docker compose pull
	docker compose up -d

# Development helpers
dev-setup:
	./scripts/dev.sh setup

dev-init:
	./scripts/dev.sh init

dev-validate:
	./scripts/dev.sh validate

dev-reset:
	./scripts/dev.sh reset

# API testing
test-api:
	./scripts/test-api.sh

test-api-all:
	./scripts/test-api.sh --all

generate-sample-data:
	./scripts/generate-sample-data.sh

# Production deployment
prod-check:
	./scripts/deploy.sh check

prod-prepare:
	./scripts/deploy.sh prepare

prod-deploy:
	./scripts/deploy.sh deploy

prod-status:
	./scripts/deploy.sh status

prod-logs:
	./scripts/deploy.sh logs

# Show disk usage
disk-usage:
	@echo "=== Docker Volume Usage ==="
	docker system df -v
	@echo "\n=== Elasticsearch Index Sizes ==="
	@curl -s "http://localhost:9200/_cat/indices/parsedmarc-*?v&h=index,docs.count,store.size&s=store.size:desc" 2>/dev/null || echo "Elasticsearch not available"

# Performance monitoring
monitor:
	@echo "=== System Resources ==="
	docker stats --no-stream
	@echo "\n=== Elasticsearch Cluster Stats ==="
	@curl -s "http://localhost:9200/_cluster/stats?pretty" 2>/dev/null | jq '.nodes.count, .indices.count, .indices.docs, .indices.store' || echo "Elasticsearch not available"

# Index management
list-indices:
	@curl -s "http://localhost:9200/_cat/indices/parsedmarc-*?v&s=index" 2>/dev/null || echo "Elasticsearch not available"

delete-old-indices:
	@echo "WARNING: This will delete indices older than 30 days!"
	@read -p "Are you sure? [y/N] " -n 1 -r; \
	if [[ $$REPLY =~ ^[Yy]$$ ]]; then \
		echo "\nDeleting old indices..."; \
		curl -s "http://localhost:9200/_cat/indices/parsedmarc-*?h=index" | grep -E "parsedmarc-aggregate-[0-9]{4}\.[0-9]{2}\.[0-9]{2}" | while read index; do \
			index_date=$$(echo $$index | grep -o "[0-9]{4}\.[0-9]{2}\.[0-9]{2}"); \
			if [ "$$(date -j -f "%Y.%m.%d" "$$index_date" "+%s" 2>/dev/null || echo 0)" -lt "$$(date -v-30d "+%s")" ]; then \
				echo "Deleting $$index"; \
				curl -s -X DELETE "http://localhost:9200/$$index" > /dev/null; \
			fi; \
		done; \
		echo "Cleanup complete."; \
	else \
		echo "\nCancelled."; \
	fi
