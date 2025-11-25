#!/bin/bash
set -e
echo "=============================="
echo " Installing Promethous-grafana-Alertmanager--Node Exporter"
echo "=============================="

# ============ 1. Update System ============
sudo apt update && sudo apt upgrade -y

# ============ 2. Install Prometheus ============
sudo useradd --no-create-home --shell /bin/false prometheus || true
sudo mkdir -p /etc/prometheus /var/lib/prometheus
sudo chown prometheus:prometheus /etc/prometheus /var/lib/prometheus

cd /tmp
curl -LO https://github.com/prometheus/prometheus/releases/download/v2.55.1/prometheus-2.55.1.linux-amd64.tar.gz
tar -xvf prometheus-2.55.1.linux-amd64.tar.gz
cd prometheus-2.55.1.linux-amd64

sudo cp prometheus promtool /usr/local/bin/
sudo chown prometheus:prometheus /usr/local/bin/prometheus /usr/local/bin/promtool

sudo cp -r consoles/ console_libraries/ /etc/prometheus/
sudo cp prometheus.yml /etc/prometheus/prometheus.yml
sudo chown -R prometheus:prometheus /etc/prometheus/*

sudo tee /etc/systemd/system/prometheus.service >/dev/null <<'EOF'
[Unit]
Description=Prometheus
Wants=network-online.target
After=network-online.target

[Service]
User=prometheus
ExecStart=/usr/local/bin/prometheus \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/var/lib/prometheus/ \
  --web.console.templates=/etc/prometheus/consoles \
  --web.console.libraries=/etc/prometheus/console_libraries
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reexec
sudo systemctl enable --now prometheus

# ============ 3. Install Grafana ============
sudo apt-get install -y software-properties-common
sudo add-apt-repository -y "deb https://packages.grafana.com/oss/deb stable main"
wget -q -O - https://packages.grafana.com/gpg.key | sudo apt-key add -
sudo apt update
sudo apt install grafana -y
sudo systemctl enable --now grafana-server

# ============ 4. Install Alertmanager ============
cd /tmp
curl -LO https://github.com/prometheus/alertmanager/releases/download/v0.27.0/alertmanager-0.27.0.linux-amd64.tar.gz
tar -xvf alertmanager-0.27.0.linux-amd64.tar.gz
cd alertmanager-0.27.0.linux-amd64

sudo cp alertmanager amtool /usr/local/bin/
sudo mkdir -p /etc/alertmanager /var/lib/alertmanager
sudo cp alertmanager.yml /etc/alertmanager/
sudo chown -R prometheus:prometheus /etc/alertmanager /var/lib/alertmanager

sudo tee /etc/systemd/system/alertmanager.service >/dev/null <<'EOF'
[Unit]
Description=Alertmanager
After=network.target

[Service]
User=prometheus
ExecStart=/usr/local/bin/alertmanager \
  --config.file=/etc/alertmanager/alertmanager.yml \
  --storage.path=/var/lib/alertmanager/
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reexec
sudo systemctl enable --now alertmanager

# ============ 5. Configure Prometheus Alerts ============
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
        expr: (1 - (node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"} 
              / node_filesystem_size_bytes{fstype!~"tmpfs|overlay"})) * 100 > 80
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "High Disk Usage on {{ $labels.instance }}"
          description: "Disk usage is above 80% for more than 2 minutes. VALUE = {{ $value }}%"
EOF

# ============ 6. PagerDuty Integration ============
sudo tee /etc/alertmanager/alertmanager.yml >/dev/null <<'EOF'
route:
  receiver: pagerduty
  group_wait: 10s
  group_interval: 10s
  repeat_interval: 1h

receivers:
  - name: pagerduty
    pagerduty_configs:
      - routing_key: "4bf6bcd8cb9b4607d047c4b6c2d333d6" #add key pagerduty 
        severity: "critical"
EOF

sudo systemctl restart alertmanager

# ============ 7. Install Node Exporter ============
sudo useradd --no-create-home --shell /bin/false node_exporter || true
cd /tmp
curl -LO https://github.com/prometheus/node_exporter/releases/download/v1.8.2/node_exporter-1.8.2.linux-amd64.tar.gz
tar -xvf node_exporter-1.8.2.linux-amd64.tar.gz
cd node_exporter-1.8.2.linux-amd64
sudo cp node_exporter /usr/local/bin/
sudo chown node_exporter:node_exporter /usr/local/bin/node_exporter

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

sudo systemctl daemon-reexec
sudo systemctl enable --now node_exporter

# ============ 8. Prometheus Config ============
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

sudo systemctl restart prometheus

# Final system update
sudo apt update && sudo apt upgrade -y


echo "=============================="
echo " Installation Completed ✅"
echo "=============================="

