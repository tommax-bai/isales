## Why

Stage 1–7 + impl-modem-controller 已交付；prep-stage8-cleanup 也已归档。每个服务仓库都有自己的 systemd unit 与 deploy 文档（`isales-{api,engine,scheduler,worker}/deploy/*.service`、`isales-telephony/deploy/{telephony-api,modem-controller}.service` + udev rules、`isales-web/deploy/nginx.conf`），但**没有任何顶层装配**：没有一键 provision、没有集中 env 管理、没有备份/监控基线、没有部署 runbook。

这意味着即便 stage 8 端到端联调跑通，也无法把系统真正部署到一台 Linux 主机上线。本 change 不做任何新功能、不动任何 runtime spec；仅在 meta-repo (`isales/`) 增加把 7 个服务装配起来的脚本、模板、文档，以及 PG/Redis 的备份和 Prometheus 监控的最小基线，让 stage 8 真实压测和灰度上线有可执行的部署流程。

## What Changes

- **顶层 production 拓扑文档**：在 meta-repo 加 `deploy/README.md`，说明 v1 单主机 systemd 部署模型（7 个 systemd unit + 本地 PG/Redis + nginx serving isales-web；不引入容器编排）；列出主机依赖（Ubuntu 22.04+、libudev、libasound2-dev、postgresql-15、redis-server、nginx、python3.12、node22）。

- **集中化 env 模板**：`deploy/env/` 下提供 `<service>.env.example`（api / engine / scheduler / worker / telephony-api / modem-controller 各一份），列出该服务全部环境变量与默认值；systemd `EnvironmentFile=/etc/isales/env/<service>.env` 由 install 脚本写入对应服务的 unit override；明确 `ISALES_JWT_SECRET` 须在 api / telephony-api 之间共用、`ISALES_DATABASE_URL` 与 `ISALES_REDIS_URL` 须 7 个服务一致。

- **provision + install + deploy + rollback 脚本**：
  - `deploy/scripts/provision.sh`：apt 安装系统依赖、创建 `isales` 用户与 `/opt/isales` 目录骨架、初始化 PG 用户与库、写入 udev rules、生成首组随机 secret 到 `/etc/isales/env/`
  - `deploy/scripts/install.sh <release-tag>`：clone/pull 7 个仓到 `/opt/isales/releases/<ts>/`、建 venv 并 `pip install -e isales-common` 后逐个 service 安装、`isales-web` 跑 `npm ci && npm run build` 输出到 `dist/`、原子地把 `/opt/isales/current` 软链到新 release、把 systemd unit + nginx.conf 同步到 `/etc/systemd/system/` 与 `/etc/nginx/sites-available/isales`
  - `deploy/scripts/migrate.sh`：`alembic upgrade head`（用 isales-common），与 install 解耦，便于回滚时跳过
  - `deploy/scripts/deploy.sh`：install + migrate + `systemctl reload nginx` + 按依赖顺序 `systemctl restart`（telephony-api → scheduler → worker → engine → api，modem-controller 单独 restart 因其与硬件耦合）
  - `deploy/scripts/rollback.sh <release-ts>`：把 `/opt/isales/current` 软链回历史 release、不动 DB（DB 回滚由 alembic 单独处理，rollback 默认不滚 schema）、按相同顺序 restart
  - 所有脚本 `set -euo pipefail`、幂等、含 dry-run

- **PG 备份 + Redis 持久化基线**：
  - `deploy/scripts/backup_pg.sh`：每日 `pg_dump` gzip 输出到 `/opt/isales/backups/pg/YYYY-MM-DD.sql.gz`，保留 14 天
  - `deploy/scripts/backup_redis.sh`：把 Redis AOF 从 `/var/lib/redis/appendonly.aof` 复制到 `/opt/isales/backups/redis/YYYY-MM-DD.aof.gz`
  - `deploy/cron/isales-backup.cron`：每日 02:30 触发上述两个脚本
  - `deploy/scripts/provision.sh` 顺手把 `redis.conf` 的 `appendonly yes` + `appendfsync everysec` 写入 `/etc/redis/redis.conf.d/isales.conf`

- **Prometheus 监控基线**：
  - `deploy/monitoring/prometheus.yml.example`：scrape targets 配置（api / engine / scheduler / worker / telephony-api 的 `/metrics` 端点 + node_exporter + postgres_exporter）；本 change 不强制要求所有服务已经实现 /metrics，未实现的 target 在 README 里标 TODO
  - `deploy/monitoring/alert_rules.yml.example`：最小告警集（engine 队列堆积 > 阈值、device flagged 比例骤升、callback 失败率 > 阈值、PG 连接数 > 80%）
  - `deploy/monitoring/grafana/isales-overview.json`：单一 overview dashboard（在播通话数 / 队列深度 / 通话接通率），导出为 Grafana JSON
  - `deploy/monitoring/README.md`：说明 Prometheus + Grafana + node_exporter + postgres_exporter 的安装方式（本 change 只提供配置模板，运维侧自行 apt 安装；不在 provision.sh 中强制安装监控栈，避免与运维既有监控冲突）

- **顶层 deploy runbook**：`deploy/RUNBOOK.md`，覆盖：首次部署 step-by-step、日常发版（含 zero-downtime 注意事项：engine restart 会断活跃通话，须在低峰期）、回滚流程、备份恢复演练、常见故障排查（PG 连不上 / Redis OOM / modem-controller 断 USB / engine 队列堆积）。

- **meta-repo 入口更新**：`README.md` 顶部加一节 "Production deployment"，指向 `deploy/RUNBOOK.md`；`Makefile` 加 `deploy-check` target（运行 shellcheck on `deploy/scripts/*.sh` + 校验所有 `*.env.example` 与各服务 README 列出的 env 一致）。

## Capabilities

### New Capabilities

- `deployment-topology`：v1 单主机 systemd 部署模型的运维契约——主机依赖、目录布局、集中化 env 文件契约、systemd 启停顺序、备份与持久化基线、监控暴露规约。`architecture` spec 已声明"单主机部署"作为高层选择；本 spec 把对应的可执行运维契约固化下来，供后续 stage 8 联调与未来灰度方案演进时参考。

### Modified Capabilities

无 spec 改动。各服务现有 spec 不动。

## Impact

- **改动范围**：基本只在 meta-repo (`isales/`) 加文件；7 个服务仓零代码改动。
  - 新增：`deploy/{README.md, RUNBOOK.md, env/*.env.example, scripts/*.sh, cron/*, monitoring/*}`
  - 修改：`README.md`（加 Production deployment 节）、`Makefile`（加 `deploy-check` target）
- **服务仓侧的轻量动作（可选，本 change 不强求）**：若有服务的 README 列的 env 与 `deploy/env/<service>.env.example` 不一致，是 `deploy-check` 报错的修复方向；本 change 在归档清单里挂为 follow-up。
- **不引入新依赖**：所有脚本用 bash + 标准 GNU 工具；监控配置只是模板，Prometheus / Grafana / node_exporter / postgres_exporter 的安装由运维自行处理。
- **不引入容器化**：v1 仍走 systemd-on-host 模型（与各服务现有 unit 一致）；docker-compose 形式的部署不在本 change 范围。
- **测试预期**：本 change 无单测；`make deploy-check` 跑 shellcheck + env 一致性校验；脚本本身的端到端验证留作 follow-up（在一台干净 Ubuntu 22.04 VM 上跑 provision → install → deploy 走通）。
- **超出本 change 范围**：
  - Stage 8 E2E hardening（100 路压测、engine 重启 graceful drain、callback 503 重试压测、max_duration 强制挂断验证）—— 单独 change
  - 多主机 / 灰度发布 / 蓝绿
  - K8s / 容器化部署
  - 真硬件 USB modem 在 VM 部署的演练（与 stage 6 的真硬件验收捆绑）
  - CI/CD 自动化部署（本 change 仅提供脚本，触发由人工 ssh 执行；GitHub Actions 集成 follow-up）
