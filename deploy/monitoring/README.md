# Monitoring

Templates for Prometheus + Grafana on the iSales single-host deployment.
**Not installed by `provision.sh`** — operator's existing monitoring stack
wins. This directory is configuration the operator copies to wherever
their Prometheus / Grafana lives.

## Inventory

| File | Purpose |
|------|---------|
| `prometheus.yml.example` | Scrape jobs for 5 services + node_exporter + postgres_exporter |
| `alert_rules.yml.example` | 4 baseline alerts: dial-queue backlog, device-flagged rate, callback failure rate, PG connection pressure |
| `grafana/isales-overview.json` | 4-panel overview dashboard (in-flight / queue depth / connect rate / per-service error log count) |

## Suggested install (operator side)

On the Prometheus host (Ubuntu 22.04 example):

```bash
sudo apt install -y prometheus prometheus-node-exporter
sudo apt install -y prometheus-postgres-exporter   # optional, for PG metrics
sudo cp deploy/monitoring/prometheus.yml.example   /etc/prometheus/prometheus.yml
sudo cp deploy/monitoring/alert_rules.yml.example  /etc/prometheus/alert_rules.yml
sudo systemctl restart prometheus
```

For Grafana, import `grafana/isales-overview.json` via the UI (Dashboards → Import).

## Status of `/metrics` endpoints

Service `/metrics` Prometheus endpoints are **not yet implemented across all
services** (see TODO comments in `prometheus.yml.example`). The intent of this
change (impl-deploy) is to freeze the *contract* — paths, port numbers, alert
expressions — so each service can land its `/metrics` independently in
follow-up changes without churning the monitoring config.

| Service                    | Port (HTTP)  | `/metrics` |
|----------------------------|--------------|------------|
| isales-api                 | 8000         | TODO       |
| isales-telephony-api       | 8001         | TODO       |
| isales-engine              | 8002         | TODO       |
| isales-scheduler           | 8003         | TODO       |
| isales-worker              | 8004         | TODO       |

When a service ships `/metrics`, remove the `# TODO` comment in
`prometheus.yml.example` and reload Prometheus.

## Validation

```bash
# Syntax check the alert rules
promtool check rules deploy/monitoring/alert_rules.yml.example

# Validate the dashboard JSON is parseable
jq . deploy/monitoring/grafana/isales-overview.json > /dev/null
```

## Out of scope for this change

- Loki / ELK log aggregation — v1 uses journald + logrotate
- Synthetic checks / blackbox_exporter
- PagerDuty / Slack receiver wiring (Alertmanager config)
- Multi-host federated Prometheus
