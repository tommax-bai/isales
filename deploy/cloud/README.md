# Cloud-side deployment (A2 cloud-edge split)

iSales v1.0 的**云端**形态：5 个无硬件耦合的服务（api / engine / scheduler / worker / web nginx）跑在阿里云 ECS 上，边缘 Mac mini 只跑 modem-controller + audio-bridge（见 `deploy/edge/`）。本目录提供云端 ECS 的 systemd unit、nginx 配置、env.example、安装 / 回滚 / 监控脚本。

> 与 openspec change `arch-cloud-edge-split` 的 §10 任务清单一一对应；spec 锚点：
> - `architecture` §云-边双套部署
> - `deployment-topology` §云端 ECS topology
> - `service-communication` §云-边控制面 gRPC bidi

## 拓扑

```
┌───────────── 阿里云 ECS（单实例 4-8C / 16-32G）──────────────┐
│                                                            │
│  systemd 进程：                                            │
│    isales-api          (FastAPI HTTP + WebSocket, :8000)   │
│    isales-engine       (real-time + cloud-edge gRPC :50051)│
│    isales-scheduler    (lead dispatcher, :8003)            │
│    isales-worker       (async post-call, :8004)            │
│                                                            │
│  nginx：                                                   │
│    443  → isales-api + isales-web/dist                     │
│    50051→ isales-engine gRPC（TLS termination + bearer 校验）│
│                                                            │
│  托管中间件：                                              │
│    阿里云 RDS PostgreSQL 16                                │
│    阿里云 Redis Tair 1G（或标准 Redis）                    │
│    阿里云 OSS（录音 / 开场白预渲染）                       │
│    阿里 RTC PaaS（媒体面，独立计费）                       │
│                                                            │
│  目录骨架：                                                │
│    /opt/isales/                                            │
│      releases/<ts>/                                        │
│        isales-common/                                      │
│        isales-{api,engine,scheduler,worker}/               │
│        isales-web/dist/                                    │
│        venv/                  4 服务共享                   │
│          + dingrtc_pywrap*.so 项目内 pybind11 binding      │
│      current -> releases/<ts>     原子软链                 │
│      vendor/                                               │
│        DingRTC_Linux_SDK_3_9_0/   OS-level vendor SDK     │
│          api/                       C++ headers            │
│          lib/x86_64/libDingRTC.so   主 SDK 共享库          │
│      backups/                                              │
│      logs/                                                 │
│                                                            │
│    /etc/isales/env/      集中化 EnvironmentFile (0640)     │
│      api.env                                               │
│      engine.env                                            │
│      scheduler.env                                         │
│      worker.env                                            │
└────────────────────────────────────────────────────────────┘
```

## 主机依赖

| 类别 | 要求 |
|------|------|
| OS | Ubuntu 22.04 LTS（amd64） |
| Python | `python3.11` + `python3.11-venv`（DingRTC binding 用 pybind11，ABI 锁 Python 3.11；与 ECS Aliyun Cloud Linux 3 默认仓库一致） |
| Node | Node.js >= 20（构建 isales-web） |
| 系统包 | `nginx` `git` `pkg-config` `curl` `ca-certificates` `unzip` |
| 用户 | 系统用户 `isales:isales`（无 shell） |
| 出网 | 443/TCP（豆包 ASR/LLM/TTS）+ UDP（阿里 RTC，由 SDK 自管端口）+ 阿里云 RDS/Redis/OSS 内网 |
| 入网 | 443/TCP（isales-web + isales-api）+ 50051/TCP（cloud-edge gRPC bidi） |

> **与 `deploy/linux/` 的差异**：本目录用于云-边拆分形态。`deploy/linux/` 是 v1 single-host 形态（modem-controller 与服务同主机），随 A2 落地后逐步淘汰，但代码暂保留作为 reference。云端不再含 modem-controller / telephony-api。

## 快速开始

完整流程见 `../RUNBOOK-cloud.md`。最小命令序列：

```bash
# 1. 准备主机（一次性，apt 包 + 用户 + 目录）
sudo bash deploy/cloud/scripts/provision.sh                # TODO: 沿用 deploy/linux/scripts/provision.sh，差异由 _lib.sh 控制

# 2. 安装 DingRTC Linux SDK（OS-level, OSS → /opt/isales/vendor/DingRTC_Linux_SDK_*/）
sudo -u isales bash deploy/cloud/scripts/install-dingrtc-sdk.sh

# 3. 编辑集中化 env，填入真实 secret + 阿里 RTC AppId/AppKey
sudoedit /etc/isales/env/engine.env
# ... api / scheduler / worker

# 4. 安装新 release
sudo -u isales bash deploy/cloud/scripts/install.sh v1.0.0

# 5. 数据库迁移（沿用既有 alembic）
sudo -u isales bash deploy/linux/scripts/migrate.sh

# 6. 切换 current 软链 + restart
sudo bash deploy/cloud/scripts/install.sh --activate <release-ts>
```

## 子目录索引

| 路径 | 用途 |
|------|------|
| `systemd/isales-api.service` | api 服务 unit（HTTPS via nginx） |
| `systemd/isales-engine.service` | engine 服务 unit（含 cloud-edge gRPC server + DingRTC SDK 注入） |
| `systemd/isales-scheduler.service` | scheduler 服务 unit |
| `systemd/isales-worker.service` | worker 服务 unit |
| `nginx/isales.conf` | nginx 反代（443 → web/api，50051 → engine gRPC） |
| `env/api.env.example` | api EnvironmentFile 模板 |
| `env/engine.env.example` | engine 模板（含 RTC AppId/AppKey、DingRTC SDK path、gRPC bind） |
| `env/scheduler.env.example` | scheduler 模板 |
| `env/worker.env.example` | worker 模板（含 cloud-edge stream watchdog） |
| `scripts/install-dingrtc-sdk.sh` | 从 OSS 拉 DingRTC Linux SDK zip，解压到 `/opt/isales/vendor/DingRTC_Linux_SDK_*/` (OS-level, idempotent) |
| `scripts/install.sh` | 拉代码 + 装依赖 + 编译 web + 同步 unit + 切 current |
| `scripts/rollback.sh` | 切回历史 release（不动 schema） |
| `monitoring/` | Prometheus / Grafana / alert rules（含 cloud-edge 专属指标） |

## 不属于本目录的范围

- **边缘 Mac mini 部署**：`deploy/edge/`
- **数据库 / Redis / OSS 资源开通**：阿里云控制台 + `RUNBOOK-cloud.md §云资源开通`
- **多实例 / HA**：v1.0 单 cloud instance（重启允许 30-60 s 中断）；不在本 change 范围
- **TLS 证书签发**：v1.0 用 Let's Encrypt + `certbot`，详见 `RUNBOOK-cloud.md §TLS`
