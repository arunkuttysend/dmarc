#!/bin/bash

# DMARC Analyzer - API Testing Script
# This script provides various API testing functions

BASE_URL="http://localhost:9200"
INDEX_PATTERN="parsedmarc-*"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Helper function to check if Elasticsearch is running
check_elasticsearch() {
    if ! curl -s "$BASE_URL/_cluster/health" > /dev/null; then
        echo -e "${RED}❌ Elasticsearch is not running at $BASE_URL${NC}"
        echo "Please start the services with: make start"
        exit 1
    fi
    echo -e "${GREEN}✅ Elasticsearch is running${NC}"
}

# Get cluster health
cluster_health() {
    echo -e "${YELLOW}=== Cluster Health ===${NC}"
    curl -s "$BASE_URL/_cluster/health?pretty" | jq '.'
}

# List all indices
list_indices() {
    echo -e "${YELLOW}=== Available Indices ===${NC}"
    curl -s "$BASE_URL/_cat/indices/$INDEX_PATTERN?v&h=index,docs.count,store.size&s=index"
}

# Get basic stats
basic_stats() {
    echo -e "${YELLOW}=== Basic Statistics ===${NC}"
    curl -s "$BASE_URL/$INDEX_PATTERN/_stats" | jq '{
        total_docs: .indices | to_entries | map(.value.primaries.docs.count) | add,
        total_size: .indices | to_entries | map(.value.primaries.store.size_in_bytes) | add,
        indices_count: .indices | length
    }'
}

# Search all records (limited)
search_all() {
    echo -e "${YELLOW}=== Sample Records ===${NC}"
    curl -s "$BASE_URL/$INDEX_PATTERN/_search?pretty" \
        -H "Content-Type: application/json" \
        -d '{
            "query": {"match_all": {}},
            "size": 5,
            "sort": [{"@timestamp": {"order": "desc"}}]
        }' | jq '.hits.hits[]._source | {
            org_name: .org_name,
            report_id: .report_id,
            timestamp: .["@timestamp"],
            record_count: (.records | length)
        }'
}

# Aggregate by disposition
disposition_stats() {
    echo -e "${YELLOW}=== DMARC Disposition Statistics ===${NC}"
    curl -s "$BASE_URL/$INDEX_PATTERN/_search?pretty" \
        -H "Content-Type: application/json" \
        -d '{
            "size": 0,
            "aggs": {
                "disposition_counts": {
                    "terms": {
                        "field": "records.row.policy_evaluated.disposition.keyword",
                        "size": 10
                    }
                }
            }
        }' | jq '.aggregations.disposition_counts.buckets[] | {
            disposition: .key,
            count: .doc_count
        }'
}

# Aggregate by source country (if GeoIP is available)
source_countries() {
    echo -e "${YELLOW}=== Top Source Countries ===${NC}"
    curl -s "$BASE_URL/$INDEX_PATTERN/_search?pretty" \
        -H "Content-Type: application/json" \
        -d '{
            "size": 0,
            "aggs": {
                "source_countries": {
                    "terms": {
                        "field": "records.row.source_ip_geoip.country_name.keyword",
                        "size": 10
                    }
                }
            }
        }' | jq '.aggregations.source_countries.buckets[]? | {
            country: .key,
            count: .doc_count
        }' 2>/dev/null || echo "GeoIP data not available"
}

# Time series data (last 7 days)
time_series() {
    echo -e "${YELLOW}=== Messages Over Time (Last 7 Days) ===${NC}"
    curl -s "$BASE_URL/$INDEX_PATTERN/_search?pretty" \
        -H "Content-Type: application/json" \
        -d '{
            "size": 0,
            "query": {
                "range": {
                    "@timestamp": {
                        "gte": "now-7d/d",
                        "lte": "now/d"
                    }
                }
            },
            "aggs": {
                "messages_over_time": {
                    "date_histogram": {
                        "field": "@timestamp",
                        "interval": "1d",
                        "format": "yyyy-MM-dd"
                    }
                }
            }
        }' | jq '.aggregations.messages_over_time.buckets[] | {
            date: .key_as_string,
            count: .doc_count
        }'
}

# Top reporting organizations
top_orgs() {
    echo -e "${YELLOW}=== Top Reporting Organizations ===${NC}"
    curl -s "$BASE_URL/$INDEX_PATTERN/_search?pretty" \
        -H "Content-Type: application/json" \
        -d '{
            "size": 0,
            "aggs": {
                "top_orgs": {
                    "terms": {
                        "field": "org_name.keyword",
                        "size": 10
                    }
                }
            }
        }' | jq '.aggregations.top_orgs.buckets[] | {
            organization: .key,
            reports: .doc_count
        }'
}

# SPF/DKIM alignment analysis
alignment_analysis() {
    echo -e "${YELLOW}=== SPF/DKIM Alignment Analysis ===${NC}"
    curl -s "$BASE_URL/$INDEX_PATTERN/_search?pretty" \
        -H "Content-Type: application/json" \
        -d '{
            "size": 0,
            "aggs": {
                "spf_alignment": {
                    "terms": {
                        "field": "records.row.policy_evaluated.spf.keyword"
                    }
                },
                "dkim_alignment": {
                    "terms": {
                        "field": "records.row.policy_evaluated.dkim.keyword"
                    }
                }
            }
        }' | jq '{
            spf_results: .aggregations.spf_alignment.buckets,
            dkim_results: .aggregations.dkim_alignment.buckets
        }'
}

# Search for specific domain
search_domain() {
    if [ -z "$1" ]; then
        echo "Usage: search_domain <domain>"
        return 1
    fi

    echo -e "${YELLOW}=== Records for Domain: $1 ===${NC}"
    curl -s "$BASE_URL/$INDEX_PATTERN/_search?pretty" \
        -H "Content-Type: application/json" \
        -d "{
            \"query\": {
                \"bool\": {
                    \"should\": [
                        {\"match\": {\"records.identifiers.header_from\": \"$1\"}},
                        {\"match\": {\"policy_published.domain\": \"$1\"}}
                    ]
                }
            },
            \"size\": 10
        }" | jq '.hits.hits[]._source | {
            org_name: .org_name,
            domain: .policy_published.domain,
            timestamp: .["@timestamp"],
            record_count: (.records | length)
        }'
}

# Interactive menu
show_menu() {
    echo -e "${GREEN}DMARC Analyzer - API Testing Menu${NC}"
    echo "=================================="
    echo "1. Cluster Health"
    echo "2. List Indices"
    echo "3. Basic Statistics"
    echo "4. Sample Records"
    echo "5. Disposition Statistics"
    echo "6. Source Countries"
    echo "7. Time Series (7 days)"
    echo "8. Top Organizations"
    echo "9. SPF/DKIM Alignment"
    echo "10. Search Domain"
    echo "11. Run All Tests"
    echo "0. Exit"
    echo
}

# Run all tests
run_all_tests() {
    check_elasticsearch
    cluster_health
    echo
    list_indices
    echo
    basic_stats
    echo
    search_all
    echo
    disposition_stats
    echo
    source_countries
    echo
    time_series
    echo
    top_orgs
    echo
    alignment_analysis
}

# Main script logic
if [ "$1" = "--all" ]; then
    run_all_tests
    exit 0
elif [ "$1" = "--domain" ] && [ -n "$2" ]; then
    check_elasticsearch
    search_domain "$2"
    exit 0
elif [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    echo "Usage: $0 [--all] [--domain <domain>] [--help]"
    echo "  --all             Run all tests"
    echo "  --domain <domain> Search for specific domain"
    echo "  --help            Show this help"
    echo "  (no args)         Interactive menu"
    exit 0
fi

# Interactive mode
check_elasticsearch

while true; do
    show_menu
    read -p "Select option (0-11): " choice
    echo

    case $choice in
        1) cluster_health ;;
        2) list_indices ;;
        3) basic_stats ;;
        4) search_all ;;
        5) disposition_stats ;;
        6) source_countries ;;
        7) time_series ;;
        8) top_orgs ;;
        9) alignment_analysis ;;
        10)
            read -p "Enter domain to search: " domain
            search_domain "$domain"
            ;;
        11) run_all_tests ;;
        0) echo "Goodbye!"; exit 0 ;;
        *) echo -e "${RED}Invalid option. Please try again.${NC}" ;;
    esac

    echo
    read -p "Press Enter to continue..."
    echo
done
