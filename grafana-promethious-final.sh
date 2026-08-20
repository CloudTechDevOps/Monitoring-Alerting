#!/bin/bash
set -e

echo "===================================================="
echo " Starting Idempotent Monitoring Stack Installation"
echo "===================================================="

# Helper function to check if a binary exists
is_installed() {
    command -v "$1" >/dev/null 2>&1
}

# ============ 1. System Prep ============
sudo dpkg --configure -a
sudo apt-get -f install
sudo apt update && sudo apt upgrade -y
sudo useradd --no-create-home --shell /bin/false prometheus || true
sudo useradd --no-create-home --shell /bin/false node_exporter || true
sudo mkdir -p /etc/prometheus /var/lib/prometheus /etc/alertmanager /var/lib/alertmanager

# ============ 2. Install Prometheus ============
if ! is_installed prometheus; then
    echo "[*] Installing Prometheus..."
    cd /tmp
    wget -nc https://github.com/prometheus/prometheus/releases/download/v2.55.1/prometheus-2.55.1.linux-amd64.tar.gz
    tar -xvf prometheus-2.55.1.linux-amd64.tar.gz
    cd prometheus-2.55.1.linux-amd64
    sudo cp prometheus promtool /usr/local/bin/
    sudo cp -r consoles/ console_libraries/ /etc/prometheus/
    sudo chown prometheus:prometheus /usr/local/bin/prometheus /usr/local/bin/promtool
else
    echo "[-] Prometheus binary found. Skipping download."
fi

# ============ 3. Install Alertmanager ============
if ! is_installed alertmanager; then
    echo "[*] Installing Alertmanager..."
    cd /tmp
    wget -nc https://github.com/prometheus/alertmanager/releases/download/v0.27.0/alertmanager-0.27.0.linux-amd64.tar.gz
    tar -xvf alertmanager-0.27.0.linux-amd64.tar.gz
    cd alertmanager-0.27.0.linux-amd64
    sudo cp alertmanager amtool /usr/local/bin/
else
    echo "[-] Alertmanager binary found. Skipping download."
fi

# ============ 4. Install Node Exporter ============
if ! is_installed node_exporter; then
    echo "[*] Installing Node Exporter..."
    cd /tmp
    wget -nc https://github.com/prometheus/node_exporter/releases/download/v1.8.2/node_exporter-1.8.2.linux-amd64.tar.gz
    tar -xvf node_exporter-1.8.2.linux-amd64.tar.gz
    cd node_exporter-1.8.2.linux-amd64
    sudo cp node_exporter /usr/local/bin/
else
    echo "[-] Node Exporter binary found. Skipping download."
fi

# ============ 5. Install Grafana ============
if ! is_installed grafana-server; then
    echo "[*] Installing Grafana..."
    sudo apt-get install -y apt-transport-https wget gnupg
    sudo mkdir -p /etc/apt/keyrings
    sudo wget -q -O /etc/apt/keyrings/grafana.asc https://apt.grafana.com/gpg-full.key
    echo "deb [signed-by=/etc/apt/keyrings/grafana.asc] https://apt.grafana.com stable main" | sudo tee /etc/apt/sources.list.d/grafana.list
    sudo apt-get update
    sudo apt-get install -y grafana
else
    echo "[-] Grafana already installed. Skipping."
fi

# ============ 6. APPLY CONFIGURATIONS (Always Overwrites to Ensure Consistency) ============
echo "[*] Applying Configuration Files..."

# Prometheus Rules
sudo tee /etc/prometheus/alert.rules.yml >/dev/null <<'EOF'
groups:
  - name: example-alerts
    rules:
      - alert: InstanceDown
        expr: up == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Instance {{ $labels.instance }} is down"
          description: "Prometheus target {{ $labels.instance }} has been unreachable for more than 1 minute."

      - alert: HighCPUUsage
        expr: 100 - (avg by(instance) (irate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 40
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "High CPU usage detected on {{ $labels.instance }}"
          description: "CPU usage > 40% for more than 2 minutes. VALUE = {{ $value }}%"

      - alert: UnauthorizedRequests
        expr: increase(http_requests_total{status=~"401|403"}[5m]) > 0
        for: 1m
        labels:
          severity: warning
        annotations:
          summary: "Unauthorized requests on {{ $labels.instance }}"
          description: "Detected unauthorized (401/403) requests in the past 5 minutes."

      - alert: HighDiskUsage
        expr: (1 - (node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"} / node_filesystem_size_bytes{fstype!~"tmpfs|overlay"})) * 100 > 80
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "High Disk Usage on {{ $labels.instance }}"
          description: "Disk usage is above 80% for more than 2 minutes. VALUE = {{ $value }}%"
EOF

# Alertmanager Config (PagerDuty)
sudo tee /etc/alertmanager/alertmanager.yml >/dev/null <<'EOF'
route:
  receiver: pagerduty
  group_by:
    - alertname
    - instance
  group_wait: 10s
  group_interval: 10s
  repeat_interval: 1h

receivers:
  - name: pagerduty
    pagerduty_configs:
      - routing_key: "3629451952984f0ec07fad6fd572e0fa"
        severity: "critical"
EOF

# Main Prometheus Config (EC2 SD)
sudo tee /etc/prometheus/prometheus.yml >/dev/null <<'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

alerting:
  alertmanagers:
    - static_configs:
        - targets: ["localhost:9093"]
    - ec2_sd_configs:
        - region: us-east-1
          port: 9093
          filters:
            - name: "tag:Name"
              values: ["node-server"]
      relabel_configs:
        - source_labels: [__meta_ec2_private_ip]
          regex: (.*)
          target_label: __address__
          replacement: "$1:9093"

rule_files:
  - "alert.rules.yml"

scrape_configs:
  - job_name: "prometheus"
    static_configs:
      - targets: ["localhost:9100"]

  - job_name: "ec2-node-exporters"
    ec2_sd_configs:
      - region: us-east-1
        port: 9100
        filters:
          - name: "tag:Name"
            values: ["node-server"]
    relabel_configs:
      - source_labels: [__meta_ec2_private_ip]
        regex: (.*)
        target_label: __address__
        replacement: "$1:9100"
EOF

# Set Permissions
sudo chown -R prometheus:prometheus /etc/prometheus /var/lib/prometheus /etc/alertmanager /var/lib/alertmanager

# ============ 7. SYSTEMD SERVICES (Created if missing) ============

# Prometheus Service
if [ ! -f /etc/systemd/system/prometheus.service ]; then
sudo tee /etc/systemd/system/prometheus.service >/dev/null <<'EOF'
[Unit]
Description=Prometheus
Wants=network-online.target
After=network-online.target
[Service]
User=prometheus
ExecStart=/usr/local/bin/prometheus --config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/var/lib/prometheus/ --web.console.templates=/etc/prometheus/consoles --web.console.libraries=/etc/prometheus/console_libraries
Restart=always
[Install]
WantedBy=multi-user.target
EOF
fi

# Alertmanager Service
if [ ! -f /etc/systemd/system/alertmanager.service ]; then
sudo tee /etc/systemd/system/alertmanager.service >/dev/null <<'EOF'
[Unit]
Description=Alertmanager
After=network.target
[Service]
User=prometheus
ExecStart=/usr/local/bin/alertmanager --config.file=/etc/alertmanager/alertmanager.yml --storage.path=/var/lib/alertmanager/
Restart=always
[Install]
WantedBy=multi-user.target
EOF
fi

# Node Exporter Service
if [ ! -f /etc/systemd/system/node_exporter.service ]; then
sudo tee /etc/systemd/system/node_exporter.service >/dev/null <<'EOF'
[Unit]
Description=Node Exporter
Wants=network-online.target
After=network-online.target
[Service]
User=node_exporter
ExecStart=/usr/local/bin/node_exporter
Restart=always
[Install]
WantedBy=multi-user.target
EOF
fi

# ============ 8. Finalize ============
sudo systemctl daemon-reload
sudo systemctl enable --now prometheus grafana-server alertmanager node_exporter

# Restart to apply config changes
sudo systemctl restart prometheus alertmanager node_exporter

echo "===================================================="
echo " Installation/Update Completed ✅"
echo "===================================================="
