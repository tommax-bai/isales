# Cloud monitoring templates (A2 cloud-edge)

Prometheus + Grafana + alert rules templates for the A2 cloud-edge topology. Templates only — `deploy/cloud/scripts/install.sh` does NOT install a metrics stack. Pick one of:

- Aliyun ARMS / CloudMonitor 托管，把 scrape targets 配进去
- 自建 Prometheus + Grafana（小流量推荐：跑在同 ECS 上，systemd 起两个服务）
- 转 push 模型，用 OpenTelemetry collector → ARMS

## 与单主机 monitoring 的差异

`deploy/monitoring/` 是 v1 single-host 模板（modem-controller / telephony-api 也在指标范围里）。本目录的差异：

- 去掉 `isales-telephony-api` / `isales-modem-controller` scrape job（迁移到 edge，由 edge 自己上报或不上报）
- 新增 `isales-engine` 的 cloud-edge 专属指标：
  - `isales_cloud_edge_stream_count{device_id}`
  - `isales_cloud_edge_heartbeat_seconds_since_last{device_id}`
  - `isales_cloud_edge_stream_disconnected_total{device_id}`
  - `isales_artc_session_count`
  - `isales_artc_push_audio_buffer_full_total{call_id}`
  - `isales_engine_pipeline_first_tts_seconds_bucket{stage}`
- 新增 `isales-worker` 边缘 watchdog 指标：
  - `isales_edge_offline_total{device_id}`
  - `isales_hardware_alert_total{kind}`
- alert rules 锚定 design.md Decision 4 latency budget（800 ms P95）

## 引入步骤

1. 在 ECS 上装 Prometheus / Grafana / node_exporter（apt 或 docker，自选）
2. 把 `prometheus.yml.example` 复制到 `/etc/prometheus/prometheus.yml` 并改 `__ISALES_DOMAIN__` 类占位（本文件没用占位，仅 nginx 用）
3. `alert_rules.yml.example` 复制到 `/etc/prometheus/alert_rules.yml`
4. Grafana 导入 `grafana/isales-cloud-edge.json`
5. 配置 Alertmanager 接 钉钉 / 飞书 webhook（运营商关心 edge offline / latency budget）

## 边缘机指标（暂不汇）

A2 范围内**不把边缘机内部指标**集中聚合（modem PCM 缓冲、SQLite buffer 深度等）。这些归 D2 `hardware-observability` 处理。本 change 只在 cloud 端记 "edge offline 次数 + heartbeat 间隔"，由 engine 自然生产。
