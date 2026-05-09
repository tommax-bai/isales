## Context

stage 1–7 + impl-modem-controller 都已交付，每个服务仓库都有自己的 systemd unit + deploy/ 目录，但 meta-repo (`isales/`) 没有顶层装配。下面是当前已有的运维基线（盘点后的事实，不是要新做的）：

| 仓库 | 现有 deploy 资产 |
|------|------------------|
| isales-api | `deploy/isales-api.service`（uvicorn, 单 worker 因 WS） |
| isales-engine | `deploy/isales-engine.service` |
| isales-scheduler | `deploy/isales-scheduler.service` |
| isales-worker | `deploy/isales-worker.service`（celery worker + beat） |
| isales-telephony | `deploy/isales-telephony-api.service` + `deploy/isales-modem-controller.service` + `deploy/99-isales-modem.rules` + `deploy/install-modem-controller.sh` |
| isales-web | `deploy/nginx.conf` |
| isales-common | 无（pip 包） |
| meta-repo `isales/` | 空白；Makefile 只有 `test-all` `spec-validate` |

每个服务 unit 都假设：`User=isales:isales` / `ExecStart=/opt/isales/venv/bin/<entry>` / `Environment=ISALES_DATABASE_URL=postgresql+asyncpg://isales:isales@localhost:5432/isales`（默认走 localhost；secret 留 override.conf 占位）。已经隐含了"单主机 + systemd + 共享 venv"的部署模型；meta-repo 缺的就是把它们装配起来的脚本与文档。

stakeholders：开发者（产出 stage 8 的能力交付清单）、未来运维（首个真实主机部署 + 之后的发版与故障排查）。

## Goals / Non-Goals

**Goals:**

- 在一台干净的 Ubuntu 22.04 主机上，按 RUNBOOK 一步步执行可以让 7 个服务全部跑起来并对外可用
- 把 v1 单主机 + systemd 部署模型的运维契约（env 布局 / 启停顺序 / 备份 / 监控 / 回滚）固化为 `deployment-topology` spec
- 提供日级 PG/Redis 备份的最小基线
- 提供 Prometheus / Grafana 配置模板（不强制即时实现 `/metrics`，列 TODO）
- 给出一套幂等、可 dry-run、可回滚的脚本

**Non-Goals:**

- 任何 stage 8 E2E hardening（100 路压测、engine 重启 graceful drain、callback 503 重试压测、max_duration 强制挂断验证）—— 单独 change
- 容器化 / docker-compose 形式的运行时部署
- 多主机 / 灰度 / 蓝绿 / 容灾
- CI/CD 自动化：本 change 提供脚本，触发由人工 ssh 执行；GitHub Actions 部署集成留 follow-up
- 真实硬件 USB modem 在 VM 部署的演练（与 stage 6 真硬件验收捆绑，独立验证）
- 在 provision.sh 中安装 Prometheus / Grafana / node_exporter / postgres_exporter（避免与运维既有监控冲突，仅提供配置模板）
- alembic downgrade 自动化（schema 回滚为高风险动作，rollback.sh 不触碰）

## Decisions

### Decision 1: systemd-on-host 而非 docker-compose

**选择**：v1 维持各服务现有 systemd unit 的部署模型，meta-repo 不引入容器化。

**理由**：
- 7 个服务的 systemd unit 已经写好并验收通过，全部假设本机 PG/Redis、共享 venv、`User=isales`。把 v1 切成 docker-compose 等于推翻已有验收
- modem-controller 需要直接读 `/dev/ttyUSB*` 与 udev 事件，容器化要么 `--privileged` 要么 host PID/dev mount，得不偿失
- 单主机意味着 PG/Redis 与服务在同进程空间内通信，零 docker 网络层开销
- 后续如果 engine 需要横向扩展再考虑容器化，作为新 change 演进

**替代方案**：docker-compose for v1。被否决：与现有 systemd unit 冲突，modem-controller 痛点大。

### Decision 2: 集中化 env 文件而非 systemd `Environment=`

**选择**：每个服务通过 `EnvironmentFile=/etc/isales/env/<service>.env` 注入；服务自带的 systemd unit 中 `Environment=` 行只保留非敏感默认（如 `localhost` 连接串），真实 secret 全部落 `/etc/isales/env/`。

**理由**：
- 现有 unit 文件里 secret 注释说 "Override the env in /etc/systemd/system/isales-api.service.d/override.conf"——本 change 把这套约定固化并提供模板
- 集中目录便于权限收敛（`0640 root:isales`）、备份、轮换、shellcheck/diff 审计
- 避免服务 unit 文件因为 secret 改动而频繁变化（unit 文件由各服务仓维护，env 由部署侧维护）

**替代方案**：每服务一个 `override.conf`。被否决：路径分散、容易遗漏一致性约束（如 `ISALES_JWT_SECRET` 需 api / telephony-api 一致）。

### Decision 3: 启停顺序硬编码在 deploy.sh，而非靠 systemd `After=`

**选择**：`deploy.sh` 显式按 `telephony-api → scheduler → worker → engine → api` 顺序 `systemctl restart`，nginx 走 `reload`，modem-controller 默认不 restart 须 `--include-modem`。

**理由**：
- systemd `After=` 只控制启动顺序，不控制 restart 顺序；deploy 时通常是 7 个 unit 都已 enabled 的状态，按依赖逐个 restart 更可控
- 把"engine restart = 活跃通话全断"显式化在 deploy.sh，配 `--force` 阻止运维误操作
- modem-controller 与硬件耦合（断 USB、AT 命令竞态），单独标志位避免被 deploy 顺手杀掉

**替代方案**：写到 systemd `Requires=` / `BindsTo=` 链。被否决：v1 服务关系是异步 (Redis Pub/Sub) 不是硬依赖；硬绑会导致一个服务挂全链塌。

### Decision 4: rollback.sh 不动 schema

**选择**：`rollback.sh` 只切 `/opt/isales/current` 软链 + 重启；DB schema 回滚由人工跑 RUNBOOK 中的步骤决定。

**理由**：
- alembic downgrade 风险高（数据丢失），自动化反而危险
- v1 大多数 schema 变更是兼容（加列），rollback 到老 release 仍能跑——大部分时候 DB 不需要回滚
- 留人工 step + RUNBOOK 决定回滚 vs forward-fix；脚本不替运维做选择

**替代方案**：rollback.sh 跑 alembic downgrade。被否决：风险与自动化收益不匹配。

### Decision 5: 监控只提供模板，不强制安装

**选择**：本 change 提供 `prometheus.yml.example` / `alert_rules.yml.example` / Grafana dashboard JSON 与一份说明 README；`provision.sh` 不安装 Prometheus / Grafana / 任何 exporter。未实现 `/metrics` 的服务 target 在 yml 标注 TODO。

**理由**：
- 运维侧通常已经有自己的监控系统（公司 Prometheus / 第三方 SaaS / 阿里云 ARMS 等），强行装本机 Prometheus 容易冲突
- 模板 + dashboard JSON 让监控接入"可参考但不强制"
- 各服务 `/metrics` 实现进度参差（engine 与 worker 有部分指标，api / scheduler / telephony 还没），先 freeze 接入契约不阻塞监控配置工作

**替代方案**：在 provision.sh 中 apt install 全套监控栈。被否决：与运维既有栈冲突的概率高。

### Decision 6: install.sh 用原子软链发布

**选择**：每次 install 落 `/opt/isales/releases/<ts>/`，最后通过 `ln -sfn` 切换 `/opt/isales/current` 软链；service unit 的 `ExecStart` 写绝对路径但走 `/opt/isales/current/venv/bin/<entry>`，软链切换后 `systemctl restart` 即生效。

**理由**：
- 原子切换 + 历史 release 保留 N 份让 rollback 是 O(1) 操作（切软链就好）
- 失败 install 不污染 current（软链切换是最后一步）
- 与 capistrano / shipit 风格的部署模型一致，运维直觉

**替代方案**：直接 `git pull` 在 `/opt/isales/`。被否决：rollback 困难、并发部署期间状态不可预测、build 失败会污染 current。

### Decision 7: 脚本语言全部用 bash

**选择**：所有 `deploy/scripts/*.sh` 用 bash，不用 Python / ansible / nix。

**理由**：
- v1 单主机 + 一次性脚本场景，bash + GNU 工具足够
- 无新依赖（脚本本身只依赖 systemd / git / pg_dump / redis-cli / curl / shellcheck）
- 后期若需要多主机、再升级到 ansible playbook 作为新 change 演进

**替代方案**：ansible / pyinfra。被否决：单主机一次性部署不需要、引入新工具学习成本。

## Risks / Trade-offs

- [集中化 `/etc/isales/env/` 中 secret 明文] → 风险：root 或 isales 用户被攻破即所有 secret 泄露。Mitigation：`0640 root:isales`，文件不进 git；后续 change 引入 systemd `LoadCredential` / vault 集成。

- [软链原子切换前 `pip install` 失败留半成品 release 目录] → 风险：磁盘占用 / 误识别。Mitigation：install.sh 在脚本退出前用 trap 清理失败的 release 目录；保留最近 N 份完成态 release。

- [engine restart 断活跃通话] → 风险：日间发版直接断客户。Mitigation：spec 强制低峰期 + `--force` 闸门；stage 8 单独 change 做 graceful drain。

- [v1 单主机 = 单点故障] → 风险：主机故障所有服务挂。Mitigation：本 change 不解决；上线前主机选型 + 备份恢复演练；多主机/HA 留新 change 演进。

- [监控接入是 TODO] → 风险：上线初期没监控就压测 / 灰度有盲区。Mitigation：RUNBOOK 强调监控接入是上线前的硬阻塞项；作为 stage 8 的额外 change 推进。

- [shellcheck 通过 ≠ 脚本无 bug] → 风险：脚本边界条件未覆盖。Mitigation：本 change 不在 CI 跑端到端 VM 演练；归档前在一台干净 Ubuntu VM 上手工跑一遍 provision → install → deploy → rollback；RUNBOOK 写明这是 release-gate。

- [deploy/env/<service>.env.example 与各服务 README env 列表脱节] → 风险：运维按模板配 env 但服务实际读不到。Mitigation：`make deploy-check` 跑一致性校验；本 change 接受首次 check 报错时同步修齐 README，作为本 change 的子任务。

## Migration Plan

本 change 不涉及 runtime 数据迁移；交付即生效。验收路径：

1. PR 全部 land 后，在一台干净 Ubuntu 22.04 VM 上手工演练：
   - `bash deploy/scripts/provision.sh`
   - 编辑 `/etc/isales/env/<service>.env` 填入 secret
   - `bash deploy/scripts/install.sh v0.1.0`（克隆 7 仓 + 建 venv + 构建 web）
   - `bash deploy/scripts/migrate.sh`
   - `bash deploy/scripts/deploy.sh`
   - 浏览器访问 nginx → 跑通登录 + 创建 campaign
2. 演练 `rollback.sh <prev-ts>` 回到上一个 release，确认服务正常
3. 验证 cron 备份生成、Prometheus 模板能被 promtool 校验（`promtool check rules deploy/monitoring/alert_rules.yml.example`）

回滚策略：本 change 是 meta-repo 加文件，rollback = git revert 该 PR；不影响任何运行中的服务。

## Open Questions

- nginx 是否需要 TLS 终结？v1 RUNBOOK 默认走 HTTP（内网管理后台）；如需要 HTTPS 留 follow-up（要么 certbot 要么前置 LB）。
- log 采集策略：v1 走 journald（systemd 默认）+ logrotate，不上 Loki / ELK；如需要集中日志看后续灰度反馈。
- 各服务 `/metrics` 何时补齐：本 change 标 TODO，但需要在 stage 8 hardening change 中明确每个服务的指标清单。
