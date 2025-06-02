// DMARC Analyzer Frontend - Flask API Integration
class DMARCAnalyzer {
  constructor() {
    this.apiBaseUrl = this.detectApiUrl();
    this.socket = null;
    this.charts = {};
    this.init();
  }

  detectApiUrl() {
    // Detect if running through nginx proxy or direct access
    const protocol = window.location.protocol;
    const host = window.location.host;

    // If on port 80 (nginx), use /api/ (proxied)
    // If on port 5000 (direct), use direct API
    if (host.includes(':5000')) {
      return `${protocol}//${host}`;
    } else {
      return `${protocol}//${host}`;
    }
  }

  async init() {
    this.initWebSocket();
    await this.loadDashboard();
    this.setupEventListeners();
    this.startPeriodicUpdates();
  }

  initWebSocket() {
    try {
      // Connect to Flask-SocketIO
      const socketUrl = this.apiBaseUrl.replace('http:', 'ws:').replace('https:', 'wss:');
      this.socket = io(this.apiBaseUrl, {
        transports: ['websocket', 'polling']
      });

      this.socket.on('connect', () => {
        console.log('Connected to WebSocket');
        this.socket.emit('subscribe_updates');
        this.showMessage('Connected to live updates', 'success');
      });

      this.socket.on('disconnect', () => {
        console.log('Disconnected from WebSocket');
        this.showMessage('Disconnected from live updates', 'error');
      });

      this.socket.on('live_update', (data) => {
        this.handleLiveUpdate(data);
      });

      this.socket.on('status', (data) => {
        console.log('Status update:', data.message);
      });

    } catch (error) {
      console.error('WebSocket connection failed:', error);
    }
  }

  async apiRequest(endpoint, options = {}) {
    const url = `${this.apiBaseUrl}/api${endpoint}`;

    try {
      const response = await fetch(url, {
        headers: {
          'Content-Type': 'application/json',
          ...options.headers
        },
        ...options
      });

      if (!response.ok) {
        throw new Error(`HTTP ${response.status}: ${response.statusText}`);
      }

      return await response.json();
    } catch (error) {
      console.error(`API request failed for ${endpoint}:`, error);
      throw error;
    }
  }

  async loadDashboard() {
    this.showLoading();

    try {
      // Load all dashboard data in parallel
      const [health, stats, organizations, dispositions, timeline] = await Promise.all([
        this.apiRequest('/health'),
        this.apiRequest('/stats'),
        this.apiRequest('/aggregations/organizations?size=10'),
        this.apiRequest('/aggregations/dispositions'),
        this.apiRequest('/aggregations/timeline?interval=day')
      ]);

      this.updateHealthStatus(health);
      this.updateStatistics(stats);
      this.updateOrganizationsChart(organizations);
      this.updateDispositionsChart(dispositions);
      this.updateTimelineChart(timeline);

      this.hideLoading();
      this.showMessage('Dashboard loaded successfully', 'success');

    } catch (error) {
      this.hideLoading();
      this.showMessage(`Failed to load dashboard: ${error.message}`, 'error');
    }
  }

  updateHealthStatus(health) {
    const healthElement = document.getElementById('health-status');
    if (!healthElement) return;

    const esStatus = health.services?.elasticsearch?.status || 'unknown';
    const redisStatus = health.services?.redis?.status || 'unknown';

    healthElement.innerHTML = `
            <div class="health-item">
                <span class="health-label">Elasticsearch:</span>
                <span class="health-status ${esStatus}">${esStatus}</span>
            </div>
            <div class="health-item">
                <span class="health-label">Redis:</span>
                <span class="health-status ${redisStatus}">${redisStatus}</span>
            </div>
            <div class="health-item">
                <span class="health-label">Last Update:</span>
                <span class="health-time">${new Date(health.timestamp).toLocaleString()}</span>
            </div>
        `;
  }

  updateStatistics(stats) {
    // Update stat cards
    this.updateStatCard('total-reports', stats.total_reports || 0);
    this.updateStatCard('total-indices', stats.total_indices || 0);
    this.updateStatCard('data-size', `${stats.total_size_kb || 0} KB`);
    this.updateStatCard('last-updated', new Date().toLocaleString());
  }

  updateStatCard(id, value) {
    const element = document.getElementById(id);
    if (element) {
      element.textContent = value;
    }
  }

  updateOrganizationsChart(data) {
    const ctx = document.getElementById('organizationsChart');
    if (!ctx) return;

    if (this.charts.organizations) {
      this.charts.organizations.destroy();
    }

    const organizations = data.organizations || [];

    this.charts.organizations = new Chart(ctx, {
      type: 'doughnut',
      data: {
        labels: organizations.map(org => org.organization),
        datasets: [{
          data: organizations.map(org => org.reports),
          backgroundColor: [
            '#667eea', '#764ba2', '#f093fb', '#f5576c', '#4facfe',
            '#43e97b', '#fa709a', '#feca57', '#ff6b6b', '#4ecdc4'
          ]
        }]
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        plugins: {
          legend: {
            position: 'bottom'
          },
          title: {
            display: true,
            text: 'Reports by Organization'
          }
        }
      }
    });
  }

  updateDispositionsChart(data) {
    const ctx = document.getElementById('dispositionsChart');
    if (!ctx) return;

    if (this.charts.dispositions) {
      this.charts.dispositions.destroy();
    }

    const dispositions = data.dispositions || [];

    this.charts.dispositions = new Chart(ctx, {
      type: 'bar',
      data: {
        labels: dispositions.map(d => d.disposition),
        datasets: [{
          label: 'Count',
          data: dispositions.map(d => d.count),
          backgroundColor: ['#48bb78', '#ed8936', '#e53e3e', '#9f7aea']
        }]
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        plugins: {
          title: {
            display: true,
            text: 'DMARC Dispositions'
          }
        },
        scales: {
          y: {
            beginAtZero: true
          }
        }
      }
    });
  }

  updateTimelineChart(data) {
    const ctx = document.getElementById('timelineChart');
    if (!ctx) return;

    if (this.charts.timeline) {
      this.charts.timeline.destroy();
    }

    const timeline = data.timeline || [];

    this.charts.timeline = new Chart(ctx, {
      type: 'line',
      data: {
        labels: timeline.map(t => t.date),
        datasets: [{
          label: 'Reports per Day',
          data: timeline.map(t => t.count),
          borderColor: '#667eea',
          backgroundColor: 'rgba(102, 126, 234, 0.1)',
          fill: true,
          tension: 0.4
        }]
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        plugins: {
          title: {
            display: true,
            text: 'Reports Timeline'
          }
        },
        scales: {
          y: {
            beginAtZero: true
          }
        }
      }
    });
  }

  handleLiveUpdate(update) {
    console.log('Live update received:', update);

    switch (update.type) {
      case 'new_report':
        this.handleNewReport(update.data);
        break;
      case 'simulated_report':
        this.handleSimulatedReport(update.data);
        break;
      default:
        console.log('Unknown update type:', update.type);
    }
  }

  handleNewReport(report) {
    this.showMessage(`New report from ${report.org_name} for ${report.domain}`, 'success');
    // Refresh stats after new report
    this.refreshStats();
  }

  handleSimulatedReport(report) {
    this.showMessage(`Simulated report: ${report.org_name} - ${report.disposition}`, 'info');
  }

  async refreshStats() {
    try {
      const stats = await this.apiRequest('/stats');
      this.updateStatistics(stats);
    } catch (error) {
      console.error('Failed to refresh stats:', error);
    }
  }

  setupEventListeners() {
    // Refresh button
    const refreshBtn = document.getElementById('refresh-btn');
    if (refreshBtn) {
      refreshBtn.addEventListener('click', () => this.loadDashboard());
    }

    // API endpoint testing
    this.setupApiTesting();
  }

  setupApiTesting() {
    const endpoints = [
      { method: 'GET', path: '/health', desc: 'Service health check' },
      { method: 'GET', path: '/stats', desc: 'Statistics overview' },
      { method: 'GET', path: '/reports', desc: 'DMARC reports list' },
      { method: 'GET', path: '/aggregations/organizations', desc: 'Top organizations' },
      { method: 'GET', path: '/aggregations/dispositions', desc: 'Disposition stats' },
      { method: 'GET', path: '/aggregations/timeline', desc: 'Timeline data' }
    ];

    const apiSection = document.querySelector('.api-section .api-endpoints');
    if (!apiSection) return;

    apiSection.innerHTML = '';

    endpoints.forEach(endpoint => {
      const endpointDiv = document.createElement('div');
      endpointDiv.className = 'endpoint';
      endpointDiv.innerHTML = `
                <div class="endpoint-method">${endpoint.method}</div>
                <div class="endpoint-path">/api${endpoint.path}</div>
                <div class="endpoint-desc">${endpoint.desc}</div>
            `;

      endpointDiv.addEventListener('click', () => this.testEndpoint(endpoint));
      apiSection.appendChild(endpointDiv);
    });
  }

  async testEndpoint(endpoint) {
    const resultDiv = document.getElementById('api-results');
    if (!resultDiv) return;

    try {
      this.showMessage(`Testing ${endpoint.path}...`, 'info');
      const result = await this.apiRequest(endpoint.path);

      resultDiv.innerHTML = `
                <h4>Response from ${endpoint.path}:</h4>
                <pre>${JSON.stringify(result, null, 2)}</pre>
            `;

      this.showMessage(`${endpoint.path} responded successfully`, 'success');

    } catch (error) {
      resultDiv.innerHTML = `
                <h4>Error from ${endpoint.path}:</h4>
                <pre class="error">${error.message}</pre>
            `;

      this.showMessage(`${endpoint.path} failed: ${error.message}`, 'error');
    }
  }

  startPeriodicUpdates() {
    // Refresh dashboard every 5 minutes
    setInterval(() => {
      this.refreshStats();
    }, 5 * 60 * 1000);
  }

  showLoading() {
    const loadingDiv = document.getElementById('loading');
    if (loadingDiv) {
      loadingDiv.style.display = 'block';
    }
  }

  hideLoading() {
    const loadingDiv = document.getElementById('loading');
    if (loadingDiv) {
      loadingDiv.style.display = 'none';
    }
  }

  showMessage(message, type = 'info') {
    const messageDiv = document.createElement('div');
    messageDiv.className = `message ${type}`;
    messageDiv.textContent = message;

    // Add to message container or create one
    let container = document.getElementById('messages');
    if (!container) {
      container = document.createElement('div');
      container.id = 'messages';
      container.style.cssText = `
                position: fixed;
                top: 20px;
                right: 20px;
                z-index: 1000;
                max-width: 400px;
            `;
      document.body.appendChild(container);
    }

    container.appendChild(messageDiv);

    // Auto-remove after 5 seconds
    setTimeout(() => {
      if (messageDiv.parentNode) {
        messageDiv.parentNode.removeChild(messageDiv);
      }
    }, 5000);
  }
}

// Initialize when DOM is loaded
document.addEventListener('DOMContentLoaded', () => {
  window.dmarcAnalyzer = new DMARCAnalyzer();
});
