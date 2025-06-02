#!/bin/bash
# DMARC Analyzer - Quick Start Guide
# Run this script for a complete system overview

echo "🛡️  DMARC Analyzer System Overview"
echo "=================================="
echo ""

echo "📋 System Status:"
echo "----------------"
docker compose ps 2>/dev/null | grep -E "(dmarc_|NAME)" || echo "❌ Docker services not running"

echo ""
echo "🔗 Access Points:"
echo "----------------"
echo "📊 Dashboard:     file://$(pwd)/index.html"
echo "🔍 API:          http://localhost:9200"
echo "📈 Kibana:       http://localhost:5601"
echo "🌐 Nginx:        http://localhost:80"
echo "🗄️  Redis:        localhost:6379"

echo ""
echo "⚡ Quick Commands:"
echo "----------------"
echo "Start services:   make start"
echo "Check status:     make status"
echo "Test API:         ./scripts/test-api.sh"
echo "Generate data:    ./scripts/generate-sample-data.sh"
echo "View logs:        make logs"
echo "Stop services:    make stop"

echo ""
echo "📊 Data Summary:"
echo "---------------"
if curl -s "http://localhost:9200/_cat/indices/parsedmarc-*?format=json" > /dev/null 2>&1; then
    DOCS=$(curl -s "http://localhost:9200/_cat/indices/parsedmarc-*?format=json" | jq -r '.[].["docs.count"]' | awk '{sum+=$1} END {print sum}' 2>/dev/null || echo "0")
    INDICES=$(curl -s "http://localhost:9200/_cat/indices/parsedmarc-*?format=json" | jq length 2>/dev/null || echo "0")
    echo "✅ Reports: $DOCS"
    echo "✅ Indices: $INDICES"
    echo "✅ Status:  $(curl -s "http://localhost:9200/_cluster/health" | jq -r .status 2>/dev/null || echo "Unknown")"
else
    echo "⚠️  Elasticsearch not accessible"
fi

echo ""
echo "🚀 System Ready! Open the dashboard to get started:"
echo "   file://$(pwd)/index.html"
echo ""
