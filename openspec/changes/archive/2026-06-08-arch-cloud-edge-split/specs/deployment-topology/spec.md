## MODIFIED Requirements

### Requirement: v1 单主机部署模型

iSales v1.0 SHALL 采用**云-边双套部署**：

- **云端**：阿里云单 ECS（4-8 核 / 16-32G RAM）通过 systemd 管理 5 个服务进程（`isales-api` / `isales-engine` / `isales-scheduler` / `isales-worker` / `nginx-isales-web`）；PostgreSQL 使用阿里云 RDS PG16 托管、Redis 使用阿里云 Redis 托管（Tair 或标准版 1G），OSS bucket 托管对象存储；nginx 反代 isales-web 静态资源与 isales-api / cloud-edge gRPC 入口
- **边缘**：客户机房一台 macOS Mac mini（v1.0 通用形态；Windows 边缘由 D1 `windows-client-core` 处理）通过 launchd 管理 1 个进程 `isales-telephony`，进程内以 asyncio task 形式运行 modem-controller + audio-bridge + cloud-edge gRPC client + 本地 SQLite 离线 buffer + 边缘 telephony-api（仅服务本地查询）；USB GSM modem 直插边缘机

MUST NOT 在 v1.0 引入容器编排（Docker / K8s）。

#### Scenario: 云端 ECS 操作系统与基础依赖

- **WHEN** provision 云端 ECS
- **THEN** ECS SHALL 满足：
  - Ubuntu 22.04 LTS 或更新（amd64）
  - 系统包：`nginx` `python3.12` `python3.12-venv` `nodejs >= 20` `pkg-config` `git` `grpcio` 编译依赖
  - 用户/组 `isales:isales`（无 shell，仅作为服务运行身份）
  - 目录骨架：
    ```
    /opt/isales/
      releases/<ts>/        # 每次 install 落新目录
        isales-common/      # git checkout
        isales-api/
        isales-engine/
        isales-scheduler/
        isales-worker/
        isales-web/dist/    # vite build 产物
        venv/               # 5 服务共用 venv
        vendor/             # 阿里 ARTC SDK for Linux Python 解压目标
      current -> releases/<ts>   # 原子软链
      backups/{pg,redis}/   # 备份输出（pg/redis 是阿里云托管，备份走云控台 + 异地同步）
      logs/                 # 兜底日志（默认走 journald）
    /etc/isales/env/        # 集中化 env 文件
    ```
  - PostgreSQL 与 Redis MUST NOT 在 ECS 内自建（使用 RDS + Redis 托管）

#### Scenario: 边缘机操作系统与基础依赖

- **WHEN** provision 边缘机（macOS Mac mini，A2 时点）
- **THEN** 边缘机 SHALL 满足：
  - macOS 13+（已通过 `impl-deploy-macos` change 验证）
  - python 3.12 + venv + pyserial + 阿里 ARTC SDK for macOS Python wrapper（vendor 解压在 `~/Library/Application Support/isales/vendor/`）
  - 目录骨架（参考 `impl-deploy-macos` 既有约定）：
    ```
    ~/Library/Application Support/isales/
      releases/<ts>/isales-telephony/
      vendor/
      logs/
      sqlite/edge_buffer.db   # 离线事件 buffer
    ~/Library/LaunchAgents/com.isales.telephony.plist
    ```
  - 边缘机 MUST NOT 安装 PostgreSQL / Redis / nginx
  - Windows 边缘形态由 D1 `windows-client-core` 提供，不在本 change 范围

#### Scenario: 不引入容器化

- **WHEN** v1.0 实施
- **THEN** MUST NOT 在云端或边缘引入 docker / docker-compose / k8s；如未来需要容器化，须通过新 change 演进 `deployment-topology` spec

### Requirement: 集中化环境变量契约

每个云端服务 SHALL 通过 systemd `EnvironmentFile=/etc/isales/env/<service>.env` 注入环境变量；明文 secret MUST 仅落在 `/etc/isales/env/`（云端）或 `~/Library/Application Support/isales/env/`（边缘）下，权限 `0640 root:isales`（云端） / `0600 <user>:staff`（边缘），MUST NOT 提交到任何 git 仓库。

#### Scenario: env 文件覆盖范围

- **WHEN** 部署任一云端服务
- **THEN** `/etc/isales/env/<service>.env` 文件 SHALL 列出该服务全部环境变量；服务在没有自身 `Environment=` 默认值的情况下也能用该 EnvironmentFile 启动；服务 systemd unit 中的 `Environment=` 行 MUST NOT 包含真实 secret（只能保留默认非敏感占位）

#### Scenario: 跨服务一致性约束（云端）

- **WHEN** 部署云端整套
- **THEN** 以下变量在多个云端服务的 env 文件中 MUST 取同一值：
  - `ISALES_DATABASE_URL`：所有依赖 PG 的服务（api / engine / scheduler / worker）；值指向阿里云 RDS 内网域名
  - `ISALES_REDIS_URL`：所有依赖 Redis 的服务（api / engine / scheduler / worker）；值指向阿里云 Redis 内网域名
  - `ISALES_JWT_SECRET`：api（云端签发前端 JWT 用）
  - `ISALES_RTC_APP_ID` / `ISALES_RTC_APP_KEY`：engine（生成 RTC token 用）
  - `ISALES_OSS_*`：worker（录音 / 远程诊断包上传）

#### Scenario: 跨云-边一致性约束

- **WHEN** 部署云-边整套
- **THEN** 以下变量在云端与边缘 env 文件中 MUST 协调：
  - `ISALES_CLOUD_GRPC_ENDPOINT`（边缘 client 指向云端 engine gRPC server，含 TLS host:port）
  - `ISALES_EDGE_DEVICE_TOKEN`（云端 isales-api 签发、写入边缘 env；与 `ISALES_JWT_SECRET` 签发的前端 JWT 来源不同）
  - `ISALES_RTC_APP_ID`（云端 + 边缘共享同一 RTC 应用；AppKey 仅云端持有，边缘只拿临时 token via gRPC `RtcCredentials` 下发）

#### Scenario: env.example 与服务 README 一致性

- **WHEN** meta-repo `make deploy-check`
- **THEN** `deploy/cloud/env/<service>.env.example` 与 `deploy/edge/env/telephony.env.example` 列出的变量集合 MUST 与对应服务仓 README "环境变量" 章节列出的集合完全一致；不一致 SHALL 报错并阻断 deploy-check

### Requirement: 服务启停顺序

云端 deploy 脚本 SHALL 按依赖顺序重启服务，避免下游在上游未就绪时启动产生连接 storm；边缘 deploy 脚本 SHALL 单独处理 isales-telephony 启停。

#### Scenario: 云端重启顺序

- **WHEN** `deploy/cloud/deploy.sh` 重启服务
- **THEN** systemctl restart 顺序 MUST 为：`isales-scheduler` → `isales-worker` → `isales-engine` → `isales-api`；nginx 走 `reload` 而非 restart；engine restart 会同时重启云-边 gRPC server，导致所有边缘 gRPC client 触发 auto-reconnect（≤ 10 s 内重连）；活跃通话 SHALL 全部中断

#### Scenario: 边缘启停

- **WHEN** `deploy/edge/deploy.sh` 重启 isales-telephony
- **THEN** launchd `launchctl kickstart -k system/com.isales.telephony`；离线期间云端 dial 命令 MAY 丢失（scheduler 兜底重试）；离线期间 modem 自然挂断（无 AT 命令通道）；重连后边缘 SQLite buffer 中的 CallEvent / HardwareAlert SHALL 顺序补发

#### Scenario: engine restart 不属于 zero-downtime

- **WHEN** restart `isales-engine`
- **THEN** 当前活跃通话 SHALL 全部中断；运维 RUNBOOK MUST 标注 engine restart 须在低峰期或维护窗口执行；自动化部署在该步前 SHALL 打印警告并要求显式 `--force` 才在非维护窗口推进

### Requirement: 数据持久化与备份基线

阿里云 RDS PostgreSQL 与 Redis 托管服务 SHALL 启用至少日级别的备份与持久化（通过云控台开启）；备份策略 MUST 记入 RUNBOOK；自建脚本备份 v1.0 不强求（托管已覆盖）。

#### Scenario: 阿里云 RDS 备份

- **WHEN** RDS PostgreSQL 实例 provision
- **THEN** SHALL 启用 RDS 自动备份（默认日级 + binlog 增量），保留期 ≥ 7 天；MUST 在阿里云控台开启备份到 OSS 跨地域复制；RUNBOOK MUST 记录恢复演练步骤

#### Scenario: 阿里云 Redis 持久化

- **WHEN** Redis 实例 provision
- **THEN** SHALL 启用 RDB 快照（每日一次） + AOF 持久化（everysec）；备份保留期 ≥ 7 天

#### Scenario: 备份恢复演练义务

- **WHEN** 上线前 / 季度演练
- **THEN** RUNBOOK MUST 提供从 RDS 备份恢复到全新 RDS 实例的步骤；演练通过的标志是恢复后 `alembic current` 能跑、`SELECT count(*) FROM campaign` 与备份当时一致

### Requirement: 部署脚本幂等与可回滚

`deploy/cloud/scripts/*.sh` 与 `deploy/edge/scripts/*.sh` SHALL 为幂等脚本，重复执行不产生额外副作用；`deploy.sh` 与 `rollback.sh` 配对实现可逆部署。

#### Scenario: 脚本通用约束

- **WHEN** 执行任一 deploy 脚本
- **THEN** 脚本 MUST 以 `set -euo pipefail` 起手；MUST 支持 `--dry-run` 标志只打印将执行的命令；重复运行同一脚本（参数相同）MUST NOT 产生破坏性副作用

#### Scenario: 原子发布

- **WHEN** `deploy/cloud/scripts/install.sh` 或 `deploy/edge/scripts/install.sh` 完成新 release 构建
- **THEN** 切换 `current` 软链 MUST 通过 `ln -sfn` 原子完成；新 release 软链切换前的失败 MUST NOT 影响当前正在运行的服务

#### Scenario: rollback 不动 schema

- **WHEN** 执行 `deploy/cloud/scripts/rollback.sh <release-ts>`
- **THEN** 脚本 MUST 仅切回历史 release 软链 + 重启服务；MUST NOT 自动执行 `alembic downgrade`；DB 回滚 SHALL 由运维手工执行 RUNBOOK 中的 "schema 回滚" 步骤后再决定是否触发

## ADDED Requirements

### Requirement: 阿里云基础设施清单

云端部署 SHALL 使用阿里云作为云厂商；基础设施资源 MUST 通过阿里云控台或 Terraform / Pulumi 等 IaC 工具显式创建并记入 RUNBOOK；MUST NOT 隐含依赖未列出的服务。

#### Scenario: 必备阿里云资源

- **WHEN** v1.0 云端 provision
- **THEN** SHALL 至少开通以下资源：
  - **ECS**：1 台，4-8 核 / 16-32G RAM，Ubuntu 22.04 LTS，按量或包年付费，可访问公网
  - **RDS PostgreSQL 16**：单实例，规格按数据规模（v1.0 100-1000 seats 建议 1C2G / 50G SSD 起步），打开自动备份与跨地域备份
  - **Redis**（Tair 或标准版）：1G 起步，AOF + RDB 持久化
  - **OSS bucket**：存储通话录音 + 远程诊断包 + 开场白预渲染（A3 用）；访问权限 ACL 私有，签名 URL 暂时下发
  - **RTC 应用**：阿里实时音视频 RTC 控台创建应用，获得 `AppId` / `AppKey`；同 RTC 应用同时供云端 engine 与边缘 audio-bridge 入会使用
  - **域名 + Let's Encrypt 证书**：用于 isales-web HTTPS + isales-api HTTPS + 云-边 gRPC TLS endpoint
- 阿里云费用预算口径：纯音频 RTC ¥6 / 千分钟 / 参会者；100 seats 月度 RTC ≈ ¥1.6k；其余 ECS + RDS + Redis + OSS 量级数千 ¥ / 月

#### Scenario: 阿里云资源命名

- **WHEN** provision 阿里云资源
- **THEN** 实例命名 MUST 含 `isales-prod-` / `isales-qa-` 等环境前缀，避免与其他业务混淆；OSS bucket 命名 MUST 全局唯一（建议 `isales-{env}-{purpose}` 形如 `isales-prod-recording`）

### Requirement: 云-边网络与端口策略

云端 SHALL 仅暴露必要端口给公网；边缘机 SHALL 不暴露任何公网端口，通过出向 TLS 连接云端。

#### Scenario: 云端公网暴露端口

- **WHEN** 配置阿里云安全组
- **THEN** 入向规则 SHALL 仅允许：
  - 80 / 443（nginx 反代 isales-web + isales-api）
  - 云-边 gRPC TLS 端口（如 50051 或与 443 复用 SNI 路由，由 impl 决定）
  - 22（SSH，限制源 IP 段）
  MUST NOT 直接暴露 PG (5432) / Redis (6379) / 5 服务的本地监听端口给公网；服务间内部通过 ECS 内网 loopback / 阿里云 VPC 内网通信

#### Scenario: 边缘网络要求

- **WHEN** 边缘机部署
- **THEN** 边缘机 SHALL 能出向访问：
  - 云端 gRPC TLS endpoint（HTTP/2 over 443 或自定端口）
  - 阿里 RTC 服务（动态 UDP 端口段 / 备用 TCP 兜底）
  - OSS endpoint（远程诊断包上传 / 开场白预渲染下载，A2 范围内只为 A3 准备占位）
  边缘机 MUST NOT 监听任何公网端口；本地 telephony-api MAY 监听 loopback 端口仅供本机查询

## MODIFIED Requirements

### Requirement: 监控暴露契约

各云端服务 SHALL 提供（或在 follow-up change 中提供）`/metrics` Prometheus 端点；本 change 提供监控配置模板，不强制所有服务即时实现 `/metrics`，但 SHALL 在 RUNBOOK 中列出 TODO 清单。

#### Scenario: 监控配置模板内容

- **WHEN** 运维部署 Prometheus（云端）
- **THEN** `deploy/cloud/monitoring/prometheus.yml.example` SHALL 至少声明以下 scrape job：`isales-api` `isales-engine` `isales-scheduler` `isales-worker` `node_exporter` `postgres_exporter`；未实现 `/metrics` 的服务 target MUST 在 yaml 注释中标 `# TODO: pending /metrics implementation`；阿里云 RDS / Redis 通过阿里云监控（CloudMonitor）独立观测

#### Scenario: 最小告警集

- **WHEN** 加载 `deploy/cloud/monitoring/alert_rules.yml.example`
- **THEN** 告警 SHALL 至少覆盖：`engine:dial` 队列深度持续 5 分钟超阈值、过去 1 小时 device flagged 比例骤升、callback 失败率 > 阈值、PG 连接数 > max_connections * 0.8、云-边 gRPC 断连边缘机数 > 阈值

#### Scenario: Grafana overview dashboard

- **WHEN** 导入 `deploy/cloud/monitoring/grafana/isales-overview.json`
- **THEN** dashboard SHALL 至少展示 5 个 panel：当前在播通话数、`engine:dial` 队列深度趋势、过去 1 小时通话接通率、过去 1 小时各服务错误日志计数、当前连接的边缘机数 / 心跳健康率
