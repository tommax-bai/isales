## ADDED Requirements

### Requirement: v1 单主机部署模型

iSales v1 SHALL 部署在单台 Linux 主机上：7 个服务进程通过 systemd 管理（`isales-api` / `isales-engine` / `isales-scheduler` / `isales-worker` / `isales-telephony-api` / `isales-modem-controller` / `nginx-isales-web`），PostgreSQL 与 Redis 作为同主机系统服务，nginx 反向代理 isales-web 静态资源。MUST NOT 在 v1 引入容器编排（Docker / K8s）。

#### Scenario: 主机操作系统与基础依赖

- **WHEN** provision 新主机
- **THEN** 主机 SHALL 满足：
  - Ubuntu 22.04 LTS 或更新（amd64）
  - 系统包：`postgresql-15` `redis-server` `nginx` `python3.12` `python3.12-venv` `nodejs >= 20` `libudev-dev` `libasound2-dev` `pkg-config` `git`
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
        isales-telephony/
        isales-web/dist/    # vite build 产物
        venv/               # 7 服务共用 venv
      current -> releases/<ts>   # 原子软链
      backups/{pg,redis}/        # 备份输出
      logs/                      # 兜底日志（默认走 journald）
    /etc/isales/env/             # 集中化 env 文件
    ```

#### Scenario: 不引入容器化

- **WHEN** v1 实施
- **THEN** MUST NOT 在 v1 引入 docker / docker-compose / k8s 形式的运行时部署；如未来需要容器化，须通过新 change 演进 `deployment-topology` spec

### Requirement: 集中化环境变量契约

每个服务 SHALL 通过 systemd `EnvironmentFile=/etc/isales/env/<service>.env` 注入环境变量；明文 secret MUST 仅落在 `/etc/isales/env/` 下，权限 `0640 root:isales`，MUST NOT 提交到任何 git 仓库。

#### Scenario: env 文件覆盖范围

- **WHEN** 部署任一服务
- **THEN** `/etc/isales/env/<service>.env` 文件 SHALL 列出该服务全部环境变量；服务在没有自身 `Environment=` 默认值的情况下也能用该 EnvironmentFile 启动；服务 systemd unit 中的 `Environment=` 行 MUST NOT 包含真实 secret（只能保留默认非敏感占位）

#### Scenario: 跨服务一致性约束

- **WHEN** 部署整套
- **THEN** 以下变量在多个服务的 env 文件中 MUST 取同一值：
  - `ISALES_DATABASE_URL`：所有依赖 PG 的服务（api / engine / scheduler / worker / telephony-api）
  - `ISALES_REDIS_URL`：所有依赖 Redis 的服务（api / engine / scheduler / worker）
  - `ISALES_JWT_SECRET`：api 与 telephony-api（telephony-api 验证 api 签发的 JWT）

#### Scenario: env.example 与服务 README 一致性

- **WHEN** meta-repo `make deploy-check`
- **THEN** `deploy/env/<service>.env.example` 列出的变量集合 MUST 与对应服务仓 README "环境变量" 章节列出的集合完全一致；不一致 SHALL 报错并阻断 deploy-check

### Requirement: 服务启停顺序

`deploy/scripts/deploy.sh` 在 install + migrate 完成后 SHALL 按依赖顺序重启服务，避免下游在上游未就绪时启动产生连接 storm。

#### Scenario: 重启顺序

- **WHEN** `deploy.sh` 重启服务
- **THEN** systemctl restart 顺序 MUST 为：`isales-telephony-api` → `isales-scheduler` → `isales-worker` → `isales-engine` → `isales-api`；nginx 走 `reload` 而非 restart；`isales-modem-controller` 因与硬件耦合 MUST 单独 restart 且默认仅在 `--include-modem` 标志下重启

#### Scenario: engine restart 不属于 zero-downtime

- **WHEN** restart `isales-engine`
- **THEN** 当前活跃通话 SHALL 全部中断；运维 RUNBOOK MUST 标注 engine restart 须在低峰期或维护窗口执行；自动化部署在该步前 SHALL 打印警告并要求显式 `--force` 才在非维护窗口推进

### Requirement: 数据持久化与备份基线

PostgreSQL 与 Redis SHALL 启用至少日级别的备份与持久化，避免单主机故障导致数据丢失。

#### Scenario: PostgreSQL 备份

- **WHEN** 每日 02:30
- **THEN** cron SHALL 触发 `pg_dump --format=custom isales | gzip > /opt/isales/backups/pg/YYYY-MM-DD.sql.gz`，保留最近 14 天，过期自动删除；备份脚本 MUST 在失败时（pg_dump 非 0 退出）写 syslog 告警

#### Scenario: Redis 持久化

- **WHEN** provision 阶段
- **THEN** `provision.sh` MUST 写入 `/etc/redis/redis.conf.d/isales.conf` 启用 `appendonly yes` + `appendfsync everysec`；每日 02:30 cron SHALL 通过 `redis-cli --rdb` 拉取一致 RDB 快照到 `/opt/isales/backups/redis/YYYY-MM-DD.rdb.gz`，保留 14 天（用 redis-cli 而非直接读 `appendonly.aof`，避免文件权限与 Redis 7 multipart AOF 目录的兼容问题）

#### Scenario: 备份恢复演练义务

- **WHEN** 上线前 / 季度演练
- **THEN** RUNBOOK MUST 提供从 `pg_dump` 文件恢复到全新 PG 实例的步骤；演练通过的标志是恢复后 `alembic current` 能跑、`SELECT count(*) FROM campaign` 与备份当时一致

### Requirement: 监控暴露契约

各服务 SHALL 提供（或在 follow-up change 中提供）`/metrics` Prometheus 端点；本 change 提供监控配置模板，不强制所有服务即时实现 `/metrics`，但 SHALL 在 RUNBOOK 中列出 TODO 清单。

#### Scenario: 监控配置模板内容

- **WHEN** 运维部署 Prometheus
- **THEN** `deploy/monitoring/prometheus.yml.example` SHALL 至少声明以下 scrape job：`isales-api` `isales-engine` `isales-scheduler` `isales-worker` `isales-telephony-api` `node_exporter` `postgres_exporter`；未实现 `/metrics` 的服务 target MUST 在 yaml 注释中标 `# TODO: pending /metrics implementation`

#### Scenario: 最小告警集

- **WHEN** 加载 `deploy/monitoring/alert_rules.yml.example`
- **THEN** 告警 SHALL 至少覆盖：`engine:dial` 队列深度持续 5 分钟超阈值、过去 1 小时 device flagged 比例骤升、callback 失败率 > 阈值、PG 连接数 > max_connections * 0.8

#### Scenario: Grafana overview dashboard

- **WHEN** 导入 `deploy/monitoring/grafana/isales-overview.json`
- **THEN** dashboard SHALL 至少展示 4 个 panel：当前在播通话数、`engine:dial` 队列深度趋势、过去 1 小时通话接通率、过去 1 小时各服务错误日志计数

### Requirement: 部署脚本幂等与可回滚

所有 `deploy/scripts/*.sh` SHALL 为幂等脚本，重复执行不产生额外副作用；`deploy.sh` 与 `rollback.sh` 配对实现可逆部署。

#### Scenario: 脚本通用约束

- **WHEN** 执行任一 deploy 脚本
- **THEN** 脚本 MUST 以 `set -euo pipefail` 起手；MUST 支持 `--dry-run` 标志只打印将执行的命令；重复运行同一脚本（参数相同）MUST NOT 产生破坏性副作用

#### Scenario: 原子发布

- **WHEN** `install.sh` 完成新 release 构建
- **THEN** 切换 `/opt/isales/current` 软链 MUST 通过 `ln -sfn` 原子完成；新 release 软链切换前的失败 MUST NOT 影响当前正在运行的服务

#### Scenario: rollback 不动 schema

- **WHEN** 执行 `rollback.sh <release-ts>`
- **THEN** 脚本 MUST 仅切回历史 release 软链 + 重启服务；MUST NOT 自动执行 `alembic downgrade`；DB 回滚 SHALL 由运维手工执行 RUNBOOK 中的"schema 回滚"步骤后再决定是否触发
