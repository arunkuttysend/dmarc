#!/bin/bash

# DMARC Analyzer - Sample Data Generator
# Generates sample DMARC data for testing and development

# Check if Elasticsearch is running
if ! curl -s "http://localhost:9200/_cluster/health" > /dev/null; then
    echo "❌ Elasticsearch is not running. Please start with: make start"
    exit 1
fi

INDEX_NAME="parsedmarc-aggregate-$(date +%Y.%m.%d)"
BASE_URL="http://localhost:9200"

echo "🔧 Generating sample DMARC data for index: $INDEX_NAME"

# Sample organizations
ORGS=("Google" "Microsoft" "Yahoo" "Proofpoint" "Barracuda" "Mimecast")

# Sample domains
DOMAINS=("example.com" "testdomain.org" "mycompany.net" "business.co" "startup.io")

# Sample source IPs
SOURCE_IPS=("203.0.113.1" "198.51.100.42" "192.0.2.123" "203.0.113.200" "198.51.100.5")

# Sample dispositions
DISPOSITIONS=("none" "quarantine" "reject")

# Sample SPF/DKIM results
SPF_RESULTS=("pass" "fail" "neutral" "softfail")
DKIM_RESULTS=("pass" "fail" "neutral")

# Function to generate random element from array
random_element() {
    local arr=("$@")
    echo "${arr[$((RANDOM % ${#arr[@]}))]}"
}

# Function to generate random timestamp (last 30 days)
random_timestamp() {
    local days_ago=$((RANDOM % 30))
    date -j -v-${days_ago}d "+%Y-%m-%dT%H:%M:%S.000Z"
}

# Function to generate a sample DMARC record
generate_record() {
    local org=$(random_element "${ORGS[@]}")
    local domain=$(random_element "${DOMAINS[@]}")
    local source_ip=$(random_element "${SOURCE_IPS[@]}")
    local disposition=$(random_element "${DISPOSITIONS[@]}")
    local spf_result=$(random_element "${SPF_RESULTS[@]}")
    local dkim_result=$(random_element "${DKIM_RESULTS[@]}")
    local count=$((RANDOM % 1000 + 1))
    local timestamp=$(random_timestamp)

    cat <<EOF
{
  "@timestamp": "$timestamp",
  "org_name": "$org",
  "email": "noreply@$org.com",
  "report_id": "$(uuidgen)",
  "date_range": {
    "begin": "$(date -j -v-1d -f "%Y-%m-%dT%H:%M:%S.000Z" "$timestamp" "+%Y-%m-%dT%H:%M:%S.000Z")",
    "end": "$timestamp"
  },
  "policy_published": {
    "domain": "$domain",
    "adkim": "r",
    "aspf": "r",
    "p": "$(random_element "none" "quarantine" "reject")",
    "sp": "none",
    "pct": 100,
    "fo": "0"
  },
  "records": [
    {
      "source_ip": "$source_ip",
      "count": $count,
      "policy_evaluated": {
        "disposition": "$disposition",
        "dkim": "$dkim_result",
        "spf": "$spf_result"
      },
      "identifiers": {
        "header_from": "$domain"
      },
      "auth_results": {
        "spf": [
          {
            "domain": "$domain",
            "result": "$spf_result"
          }
        ],
        "dkim": [
          {
            "domain": "$domain",
            "result": "$dkim_result",
            "selector": "default"
          }
        ]
      }
    }
  ]
}
EOF
}

# Generate and index sample records
echo "📊 Generating sample records..."

for i in {1..50}; do
    echo "Creating record $i/50..."

    RECORD=$(generate_record)

    curl -s -X POST "$BASE_URL/$INDEX_NAME/_doc" \
        -H "Content-Type: application/json" \
        -d "$RECORD" > /dev/null

    if [ $? -eq 0 ]; then
        echo "✅ Record $i indexed successfully"
    else
        echo "❌ Failed to index record $i"
    fi
done

echo ""
echo "🎉 Sample data generation complete!"
echo ""
echo "📈 You can now:"
echo "  • View data in Kibana: http://localhost:5601"
echo "  • Test APIs with: ./scripts/test-api.sh"
echo "  • Run searches with: make test-api"
echo ""

# Show basic stats
echo "📊 Current index stats:"
curl -s "$BASE_URL/_cat/indices/$INDEX_NAME?v&h=index,docs.count,store.size"
