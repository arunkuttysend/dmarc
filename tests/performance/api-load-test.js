# Performance tests using k6
import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate } from 'k6/metrics';

// Test configuration
export const options = {
  stages: [
    { duration: '2m', target: 10 }, // Ramp up to 10 users
    { duration: '5m', target: 10 }, // Stay at 10 users
    { duration: '2m', target: 20 }, // Ramp up to 20 users
    { duration: '5m', target: 20 }, // Stay at 20 users
    { duration: '2m', target: 0 },  // Ramp down to 0 users
  ],
  thresholds: {
    http_req_duration: ['p(95)<500'], // 95% of requests must complete below 500ms
    http_req_failed: ['rate<0.02'],   // Error rate must be below 2%
  },
};

// Custom metrics
const errorRate = new Rate('errors');

const BASE_URL = __ENV.API_BASE_URL || 'http://localhost:5000';

export default function () {
  // Test health endpoint
  let healthResponse = http.get(`${BASE_URL}/api/health`);
  check(healthResponse, {
    'health check status is 200': (r) => r.status === 200,
    'health check response time < 200ms': (r) => r.timings.duration < 200,
  }) || errorRate.add(1);

  sleep(1);

  // Test statistics endpoint
  let statsResponse = http.get(`${BASE_URL}/api/stats`);
  check(statsResponse, {
    'stats status is 200': (r) => r.status === 200,
    'stats response time < 1000ms': (r) => r.timings.duration < 1000,
    'stats has required fields': (r) => {
      const data = JSON.parse(r.body);
      return data.total_reports !== undefined && data.total_indices !== undefined;
    },
  }) || errorRate.add(1);

  sleep(1);

  // Test reports endpoint
  let reportsResponse = http.get(`${BASE_URL}/api/reports?page=1&size=20`);
  check(reportsResponse, {
    'reports status is 200': (r) => r.status === 200,
    'reports response time < 2000ms': (r) => r.timings.duration < 2000,
    'reports has pagination': (r) => {
      const data = JSON.parse(r.body);
      return data.page !== undefined && data.total !== undefined;
    },
  }) || errorRate.add(1);

  sleep(1);

  // Test organizations aggregation
  let orgsResponse = http.get(`${BASE_URL}/api/aggregations/organizations?size=10`);
  check(orgsResponse, {
    'organizations status is 200': (r) => r.status === 200,
    'organizations response time < 1500ms': (r) => r.timings.duration < 1500,
  }) || errorRate.add(1);

  sleep(1);

  // Test dispositions aggregation
  let dispositionsResponse = http.get(`${BASE_URL}/api/aggregations/dispositions`);
  check(dispositionsResponse, {
    'dispositions status is 200': (r) => r.status === 200,
    'dispositions response time < 1500ms': (r) => r.timings.duration < 1500,
  }) || errorRate.add(1);

  sleep(2);
}
