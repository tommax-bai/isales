# RUNBOOK — cloud-edge cloud side

本 RUNBOOK 覆盖 A2 `arch-cloud-edge-split` 落地的 5 服务云端（api / engine / scheduler / worker / web nginx）从零到一的运维流程。**边缘 Mac mini 部分见 `RUNBOOK-edge.md`。**

> 与 `deploy/cloud/` 配套；与 `RUNBOOK.md`（v1 single-host）平行。架构基线见
> `openspec/specs/architecture/spec.md` 与 `openspec/specs/deployment-topology/spec.md`。

## 目录

1. [阿里云资源开通](#1-阿里云资源开通)
2. [公网入口（v1.0 IP 直连 / v1.x 域名）](#2-公网入口v10ip-直连v1x域名--tls)
3. [首次部署](#3-首次部署)
4. [常规发版](#4-常规发版)
5. [回滚](#5-回滚)
6. [RDS / Redis / OSS 备份恢复演练](#6-rds--redis--oss-备份恢复演练)
7. [cloud-edge 调试](#7-cloud-edge-调试)
8. [监控与告警](#8-监控与告警)
9. [Schema rollback 例外流程](#9-schema-rollback-例外流程)
10. [应急速查](#10-应急速查)

---

## 1. 阿里云资源开通

**首次开通清单**（Sprint 0 期间一次性，与 impl 并行不阻塞）：

| 资源 | 规格 | 说明 |
|------|------|------|
| ECS | 4C16G / Ubuntu 22.04 LTS / 100 GB SSD | v1.0 单实例够用；按量付费 → 1 月稳定后转包年包月 |
| VPC + 安全组 | 同地域 | 入站 443/TCP、50051/TCP、22/TCP（仅运维 IP）；出站全开 |
| RDS PostgreSQL | 16 / 2C4G / 100 GB | 内网连接；备份保留 7 天；`shared_preload_libraries=pg_stat_statements` |
| Redis | Tair 标准 1G 或 Redis 标准 1G | 内网连接；AOF 持久化 |
| OSS | 私有 bucket `isales-prod` | 录音 / 开场白预渲染 / ARTC SDK vendor 包 |
| RTC 应用 | 阿里云 RTC console | 拿 `AppId` / `AppKey`，工单确认计费套餐（见 PoC §9 三题工单稿） |
| 域名 + ICP | **v1.0 不需要**；v1.x 切换到 §2.2 时再申请 | v1.0 用 IP 直连 `121.89.85.150`，详见 `deploy/cloud/STATE.md § "v1.0 deployment posture"` |

**ARTC SDK 上传 OSS**（一次性）：

```bash
# 本地解压验证 SDK
unzip -l ~/codes/vendor/AliRTCSDK_Linux-7.10.2.zip | head -20

# 打成约定的 tarball 结构 lib/ python/
mkdir -p /tmp/artc/aliyun-artc-linux-python-7.10.2/{lib,python}
cp ~/codes/vendor/AliRTCSDK_Linux-7.10.2/lib/*.so          /tmp/artc/aliyun-artc-linux-python-7.10.2/lib/
cp -R ~/codes/vendor/AliRTCSDK_Linux-7.10.2/python/*       /tmp/artc/aliyun-artc-linux-python-7.10.2/python/
tar -C /tmp/artc -czf /tmp/artc-linux-7.10.2.tgz aliyun-artc-linux-python-7.10.2

# 推到 OSS 私有 bucket
ossutil cp /tmp/artc-linux-7.10.2.tgz \
  oss://isales-prod/vendor/artc/linux/aliyun-artc-linux-python-7.10.2.tgz
```

---

## 2. 公网入口（v1.0：IP 直连；v1.x：域名 + TLS）

> **v1.0 默认是 IP 直连，不经域名 / nginx / Let's Encrypt**。详见
> `deploy/cloud/STATE.md` § "v1.0 deployment posture"。本节 §2.1 是
> v1.0 的实际操作步骤；§2.2 (域名 + TLS) 留作 v1.x 切换路径，**v1.0
> 部署 SKIP 整段 §2.2**。

### 2.1 v1.0 IP 直连（默认）

边缘客户端配置 `ISALES_CLOUD_GRPC_ENDPOINT=121.89.85.150:50051` 直接连
ECS 公网 IP；isales-api / isales-web 同样直接 `121.89.85.150:443`（如启用）
/ `121.89.85.150:8080`。没有域名、没有证书申请、没有 ICP 备案、没有
nginx——engine gRPC 自己 listen `0.0.0.0:50051`：

```bash
# Aliyun 安全组放行（控制台 → ECS 实例 → 安全组 → 入方向）
# - 50051/tcp  允许来源 0.0.0.0/0（cloud-edge gRPC；如果边缘出口 IP
#              可枚举，建议收紧为白名单）
# - 8080/tcp   允许来源 0.0.0.0/0（isales-api HTTP；如果暴露后台才需要）
# - 22/tcp     允许来源 <运维 IP 段>（SSH）
# 不需要 80/443，没有 nginx
```

engine env 把 gRPC bind 从 loopback 改公网：

```ini
# /etc/isales/env/engine.env（覆盖 deploy/cloud/env/engine.env 的 127.0.0.1）
ISALES_ENGINE_CLOUD_EDGE_GRPC_BIND=0.0.0.0:50051
```

> **TLS 取舍**（v1.0 待决，部署时再定）：
> - **plain gRPC over IP**：最省事，customer-VPN / 内网部署可接受；公网部署只在试点 PoC 时勉强可用，bearer token 走 metadata 仍能验证身份，但流量明文。
> - **self-signed cert pinned at edge**：edge 客户端打包时 ship 一份固定 CA cert；server 绑 self-signed；中间人无效。需要边客户端代码读 `ISALES_CLOUD_GRPC_CA_PEM` env。
> - **sslip.io / nip.io + Let's Encrypt**：把 `121-89-85-150.sslip.io` 当域名拿免费 LE 证书，**绕过 ICP 备案**。可以视为 §2.2 的简化版。
>
> 第一个真实交付前选定，更新本节 + STATE.md 记结论。

### 2.2 v1.x 切换到注册域名 + Let's Encrypt（DEFERRED）

> **v1.0 部署不需要执行本小节**。仅在 (a) 真有多客户部署需要稳定 endpoint
> 标签、或 (b) 合规 / 品牌要求公开域名时启用。前置：完成 ICP 备案（中国
> 大陆 2-4 周）。

```bash
# 装 nginx + certbot + ossutil
sudo apt update
sudo apt install -y nginx certbot python3-certbot-nginx unzip
sudo curl -L https://gosspublic.alicdn.com/ossutil/install.sh | sudo bash

# DNS A 记录：cloud.isales.example.com -> ECS 公网 IP
# Let's Encrypt（注意 cloud-edge gRPC 用 50051 也在同证书 SAN 内）
sudo certbot certonly --webroot -w /var/www/acme \
  -d cloud.isales.example.com \
  --email ops@isales.example.com --agree-tos --no-eff-email

# certbot 自动续期已通过 systemd timer 装好
sudo systemctl status certbot.timer
```

**证书覆盖 gRPC 50051**：因为 nginx server block 与 443 共享 `server_name`，同一张证书复用。

---

## 3. 首次部署

```bash
# 装系统用户 + 目录骨架（沿用单主机的 provision.sh，cloud-edge 拓扑下也适用）
sudo bash deploy/linux/scripts/provision.sh

# 集中化 env：从 deploy/cloud/env/*.example 复制
for svc in api engine scheduler worker; do
  sudo install -m 0640 -o root -g isales \
    deploy/cloud/env/$svc.env.example /etc/isales/env/$svc.env
done
sudoedit /etc/isales/env/api.env       # 填 RDS / Redis URL / JWT_SECRET
sudoedit /etc/isales/env/engine.env    # 填 RTC AppId/AppKey / 豆包 API key
sudoedit /etc/isales/env/scheduler.env
sudoedit /etc/isales/env/worker.env    # 填 OSS AK/SK

# 必填的环境变量提示
export ISALES_DOMAIN=cloud.isales.example.com

# 安装 release（拉 6 仓 + 装 venv + 编译 web + ARTC SDK + 同步 unit + nginx）
sudo -E bash deploy/cloud/scripts/install.sh v1.0.0

# 跑首次 alembic（与单主机一致）
sudo -u isales bash deploy/linux/scripts/migrate.sh

# 激活（切 current 软链 + restart）
sudo bash deploy/cloud/scripts/install.sh --activate <release-ts>

# enable 开机自启
sudo systemctl enable isales-api isales-engine isales-scheduler isales-worker
sudo systemctl enable nginx

# 健康检查
curl -fsS https://cloud.isales.example.com/api/health
sudo journalctl -u isales-engine -n 50 | grep -i "grpc.*listening"
```

---

## 4. 常规发版

```bash
# 1. install 新版本（不动 current）
export ISALES_DOMAIN=cloud.isales.example.com
sudo -E bash deploy/cloud/scripts/install.sh v1.0.1

# 2. 跑迁移（若有）
sudo -u isales bash deploy/linux/scripts/migrate.sh

# 3. 激活
sudo bash deploy/cloud/scripts/install.sh --activate <new-release-ts>

# 4. 监控前 5 分钟
watch -n 5 'systemctl is-active isales-{api,engine,scheduler,worker} nginx'
```

发版策略：

- ECS 单实例，发版**会断开**当前 active gRPC 长连（边缘 auto-reconnect 兜底）
- 进行中通话**会丢**（v1.0 接受 30-60 s 中断窗口）
- 选**业务低峰期**做（建议夜间 02:00-04:00）

---

## 5. 回滚

```bash
# 列出可回滚 release
sudo bash deploy/cloud/scripts/rollback.sh --list

# 回滚到指定 ts（不动 schema）
sudo bash deploy/cloud/scripts/rollback.sh 20260514-220000
```

要点：

- 回滚**仅切 current 软链** + 重启 4 个 cloud 服务 + reload nginx
- ARTC SDK vendor 目录跟随 release；如新 release 缺 vendor，脚本会自动重跑 install-artc-sdk.sh
- **不动 PG schema**；若旧 release 与新 schema 不兼容，见 [§9 Schema rollback](#9-schema-rollback-例外流程)
- 边缘机不参与回滚

---

## 6. RDS / Redis / OSS 备份恢复演练

**每季度跑一次**，验证云资源备份链路。

### RDS PG 备份恢复演练

```bash
# 1. 阿里云控制台 → RDS 实例 → 备份恢复 → 创建临时实例 from 最新快照
# 2. 拿到临时实例 endpoint
# 3. ECS 上 pg_dump 校验
psql "postgresql://isales:<pw>@<temp-endpoint>:5432/isales" -c "select count(*) from leads;"
# 4. 与生产库对比，确认数据一致后销毁临时实例
```

### Redis 备份验证

阿里云 Redis 自动 RDB 备份。从控制台导出最新 RDB → 本地 `redis-cli --rdb /tmp/x.rdb` 验证可加载。

### OSS 灾备

- bucket 开启「跨地域复制」到备地域
- ARTC SDK vendor tarball 用 versioning + retention policy

---

## 7. cloud-edge 调试

### 看哪些 edge 在线

```sql
-- 在 RDS 上跑
SELECT device_id, last_heartbeat, status,
       EXTRACT(EPOCH FROM (now() - last_heartbeat)) AS seconds_since
FROM edge_device
ORDER BY last_heartbeat DESC;
```

### gRPC 流连通性

```bash
# 看 engine 是否有活跃流
sudo journalctl -u isales-engine | grep -i "edge.*stream" | tail -20

# 用 grpcurl 测试（带 token）
grpcurl -H "authorization: Bearer $EDGE_DEVICE_TOKEN" \
  cloud.isales.example.com:50051 list

# 看 nginx 50051 接收流量
sudo tail -f /var/log/nginx/access.log | grep 50051
```

#### 50051 TCP idle-timeout 配置（cloud-edge-grpc-keepalive）

外部到 ECS `:50051` 的 cloud-edge bidi stream 必须能在中间网络层（Aliyun
ECS 安全组 stateful tracking / SLB 七层 idle-cleanup / 客户机 NAT /
公司防火墙）的 idle 抑制下存活；否则 stream 在初次 `initial_metadata` 返回后
~1 ms 就被 cut（2026-05-19 实测）。OpenSpec change `cloud-edge-grpc-keepalive`
+ `isales-telephony` + `isales-engine` 双侧加 HTTP/2 keepalive
（30s 周期 / 10s ack timeout / `permit_without_calls=1` / server `max_ping_strikes=0`），
但客户端 keepalive 是**必要不充分**条件，仍需以下部署侧配置：

- **Aliyun ECS 安全组** inbound 50051 TCP：开放给业务 IP / 0.0.0.0/0 即可，
  **不**配 stateful idle-cleanup（如果 console 提供"会话保持时间"/
  "空闲断开"这种选项，应关闭或调到最长）。Aliyun console: ECS 实例 → 安全组 →
  入方向规则 → 编辑 50051 规则 → 高级设置。
- **SLB（如已 / 计划接入）**：必须七层 HTTP/2 或四层 TCP 模式，且
  idle-timeout 调到 ≥ 60 min。WAF 七层模式经常默认 ≤ 1 min 不支持 HTTP/2
  长连接，**不**适合 cloud-edge gRPC。
- **HTTP/2 keepalive 期望参数**（server 已固化代码内）：
  ```
  grpc.keepalive_time_ms                       = 30000
  grpc.keepalive_timeout_ms                    = 10000
  grpc.keepalive_permit_without_calls          = 1
  grpc.http2.max_ping_strikes                  = 0
  grpc.http2.min_time_between_pings_ms         = 10000
  grpc.http2.min_ping_interval_without_data_ms = 10000
  ```
  Client 对称参数见 `isales-telephony/transport/grpc_client.py`
  `_KEEPALIVE_CHANNEL_OPTIONS`。

**验收命令**（dev 机连真 cloud）：

```bash
.venv/bin/python scripts/cloud_edge_smoke.py \
    --endpoint <ECS_IP>:50051 \
    --token-file ~/.isales/edge-dev.jwt \
    --soak 600 --report-file /tmp/soak.json
```

合格门槛：**stream lifetime p95 ≥ 300 s**（脚本内常量
`SOAK_P95_TARGET_S`，acceptance pass 时 exit code 0；否则 3）。
如果 p95 远低于 300 s（特别是 < 5 s 即 cut），先排查上面"安全组 / SLB"
两节，再回 `cloud-edge-grpc-keepalive` change 的 design notes。

### 签发 EDGE_DEVICE_TOKEN（A2 静态长 token）

```bash
sudo -u isales /opt/isales/current/venv/bin/isales-edge-token-mint \
  --device-id "edge-01" --ttl 365d > /tmp/edge-01.token
# 把 token 安装到目标 Mac mini /etc/isales/env/edge.env
```

> A2 用静态长 token；C2 `multi-tenant` 引激活码 → 租户 JWT，token 在过渡期会改为 24h 短期 + 自动续签。

### RTC 房间手工探查

```python
# /tmp/artc-probe.py — 在 ECS 上用 vendor SDK 跑一次单边入会，看是否能收到对端 PCM
import os, sys, time
sys.path.insert(0, '/opt/isales/current/vendor/aliyun-artc-linux-python/python')
os.environ['LD_LIBRARY_PATH'] = '/opt/isales/current/vendor/aliyun-artc-linux-python/lib'
import AliRTCSDK
# ... 单边入会 + 监听 OnSubscribeAudioFrame，5 秒后退出
```

---

## 8. 监控与告警

详见 `deploy/cloud/monitoring/README.md`。

关键告警：

- `IsalesEdgeOffline` — 边缘 120s 无心跳
- `IsalesEdgeReconnectStorm` — 5 分钟内 > 5 次断线
- `IsalesArtcPushAudioBufferFull` — TTS 推流被反压
- `IsalesEnginePipelineLatencyBudget` — P95 > 800 ms

---

## 9. Schema rollback 例外流程

A2 cloud-edge 不改 alembic 流程。如确需 schema rollback：

```bash
# 1. 找到目标 release 期望的 alembic revision
cd /opt/isales/releases/<target-ts>/isales-common
alembic -c alembic.ini current

# 2. 在 RDS 上手工 downgrade（先全量备份！）
/opt/isales/current/venv/bin/alembic -c .../alembic.ini downgrade <rev>

# 3. 回滚 release symlink
sudo bash deploy/cloud/scripts/rollback.sh <target-ts>
```

**仅在确证 forward migration 不兼容旧 release 时使用**；多数 v1.0 schema 改动是 additive，可直接做 release rollback。

---

## 10. 应急速查

| 症状 | 第一动作 |
|------|---------|
| edge 全部离线 | `sudo systemctl status nginx` + `ss -tln \| grep 50051` |
| edge 一台离线 | 看 worker watchdog 日志 `journalctl -u isales-worker -n 100` |
| 通话拨通后无 AI 声 | engine 日志找 `ARTC join failed` / `LD_LIBRARY_PATH` 错误 |
| latency 超 800 ms 持续告警 | 改 engine.env `ISALES_ENGINE_PIPELINE_*` 把多角色 PK 默认 N=1 + restart engine（design.md Decision 4 降级策略）|
| RDS 连接被打满 | scheduler / engine 各自的连接池上限 → 走 `RUNBOOK.md §pg-pool` |
| nginx 502 in grpc | engine 崩了 → `systemctl restart isales-engine` + 看 core dump |
| LE 证书快过期 | `certbot renew --dry-run` 验证；timer 应自动续 |

> 注：本 RUNBOOK 假设运维已熟悉单主机 `RUNBOOK.md` 的通用部分（systemd 操作、journalctl 用法、ssh 应急访问）。本文件仅描述云-边形态独有部分。
