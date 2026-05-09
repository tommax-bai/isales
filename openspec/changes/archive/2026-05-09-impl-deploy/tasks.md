> 实施仓库：本 change 几乎全部改动落在 meta-repo (`isales/`)；个别 PR 触及 `isales-{api,engine,scheduler,worker,telephony,web}/README.md` 同步 env 列表。
> 11 个 PR 顺序合入；最后一项为人工 VM 演练，作为归档前 release-gate（不阻塞前置 PR）。
>
> 路径前缀：未注明仓库时默认指 meta-repo (`isales/`)。

## 1. deploy/ 顶层骨架与 README（PR #1）

- [x] 1.1 新增 `deploy/README.md`：v1 单主机部署模型说明、目录骨架（`/opt/isales/{releases,current,backups,logs}` + `/etc/isales/env/`）、主机依赖列表（OS / apt 包 / Python / Node 版本）、与 `architecture` spec 的对照
- [x] 1.2 新增 `deploy/.gitignore`：忽略 `env/*.env`（只允许 `*.env.example` 进 git）；补一句注释解释原因
- [x] 1.3 主仓 `README.md` 顶部加一节 "Production deployment"，指向 `deploy/README.md` 与 `deploy/RUNBOOK.md`（RUNBOOK 文件 PR #10 才落，此处先指向占位）
- [x] 1.4 验证：`openspec validate impl-deploy` 仍通过

## 2. 集中化 env 模板（PR #2）

- [x] 2.1 新增 `deploy/env/api.env.example`：列 isales-api 全部 env（`ISALES_DATABASE_URL` / `ISALES_REDIS_URL` / `ISALES_JWT_SECRET` / `ISALES_ADMIN_USER` / `ISALES_ADMIN_PASSWORD_HASH` / 日志级别等）；secret 用 `<change-me>` 占位；变量集合 MUST 与 `isales-api/README.md` 列表一致
- [x] 2.2 新增 `deploy/env/engine.env.example`：参照 isales-engine README
- [x] 2.3 新增 `deploy/env/scheduler.env.example`：参照 isales-scheduler README
- [x] 2.4 新增 `deploy/env/worker.env.example`：参照 isales-worker README
- [x] 2.5 新增 `deploy/env/telephony-api.env.example`：参照 isales-telephony README，标 `ISALES_JWT_SECRET` 须与 api 一致
- [x] 2.6 新增 `deploy/env/modem-controller.env.example`：参照 isales-telephony README（IPC socket 路径、设备发现策略等）
- [x] 2.7 各服务仓 README 校对：扫描 #2.1–#2.6 涉及的 5 个服务 README env 表 vs 代码 `os.environ.get` / pydantic `alias=`：api / engine / scheduler / worker / telephony 当前 README 列表与代码完全一致，无需改动 README。**已知不一致（不在本 change 修）**：worker README 标注 `ISALES_FERNET_KEY` MUST match isales-api，但 isales-api 当前不读 `ISALES_FERNET_KEY`（callback_config.signing_secret 加解密链路在 api 侧未对接）—— 列为 follow-up，不阻塞 deploy 模板。

## 3. provision.sh（PR #3）

- [x] 3.1 新增 `deploy/scripts/_lib.sh`：通用工具——`log_info` / `log_warn` / `die` / `confirm`（带 `--dry-run` 短路）/ `require_cmd`
- [x] 3.2 新增 `deploy/scripts/provision.sh`：`set -euo pipefail` + `--dry-run`；apt 安装系统包；创建 `isales:isales` 系统用户（`useradd -r -s /usr/sbin/nologin`）；创建 `/opt/isales/{releases,backups/{pg,redis},logs}` 与 `/etc/isales/env/`（`0750 root:isales`）
- [x] 3.3 provision.sh 写 `/etc/redis/redis.conf.d/isales.conf`：`appendonly yes` + `appendfsync everysec`；写完 reload redis-server
- [x] 3.4 provision.sh 初始化 PG：创建 `isales` 数据库与角色（密码从首组随机 secret 生成 → 写入 `/etc/isales/env/api.env` 等）；幂等检查 `psql -c '\l'` 已存在则跳过
- [x] 3.5 provision.sh 安装 udev rules：`cp isales-telephony/deploy/99-isales-modem.rules /etc/udev/rules.d/` + `udevadm control --reload-rules`（仅当 `--with-modem` 标志，单纯 v1 演练机可跳过）
- [x] 3.6 provision.sh 重复执行幂等检查：每个 step 用 `id -u` / `[[ -d ]]` / `pg_role_exists` / `[[ -f /etc/isales/env/X.env ]]` 守护；secret 仅在 env 文件不存在时生成；shellcheck + `bash -n` 清洁
- [ ] 3.7 验证：在干净 Ubuntu 22.04 容器/VM 上跑 provision.sh 两次，第二次输出全部是 "already exists, skipped" — DEFERRED 到 PR #11 release-gate 演练（开发机 macOS 无法直接跑 Ubuntu apt + systemctl）

## 4. install.sh + migrate.sh（PR #4）

- [x] 4.1 新增 `deploy/scripts/install.sh <git-ref>`：`set -euo pipefail` + `--dry-run`；root 入口，内部 `sudo -u isales` 切换执行 /opt/isales/ 操作
- [x] 4.2 install.sh 在 `/opt/isales/releases/$(date +%Y%m%d-%H%M%S)/` 下 `git clone` 7 仓（已存在则 `git fetch && git checkout <ref>`）
- [x] 4.3 install.sh 建 venv（`python3.12 -m venv venv`）、`pip install -e isales-common`、再依次 `pip install -e isales-{api,engine,scheduler,worker,telephony}`（注：未发现 `[prod]` extra，使用直接 `pip install -e`）
- [x] 4.4 install.sh `cd isales-web && npm ci && npm run build`，产物在 `<release>/isales-web/dist/`
- [x] 4.5 install.sh trap ERR 清理失败的 release 目录；MUST NOT 切 current 软链（切链由 deploy.sh 完成）
- [x] 4.6 install.sh 把 6 个 service unit 与 nginx.conf 同步到系统目录（`/etc/systemd/system/` 与 `/etc/nginx/sites-available/isales`）；`systemctl daemon-reload`；nginx root 通过 `/var/www/isales-web` 软链至 dist
- [x] 4.7 install.sh 通过 `rewrite_unit` sed pipeline 统一三种历史不一致路径到 `/opt/isales/current/venv/bin/...` 与 `/opt/isales/current/isales-X`：（a）共享 venv `/opt/isales/venv/bin/X`、（b）per-svc venv `/opt/isales-X/.venv/bin/X`、（c）per-svc WorkingDirectory `/opt/isales-X`。本 PR 因此发现 stage-2/3 的服务 unit 路径漂移；不在本 change 修源仓 unit，只在 install.sh 装配期改写
- [x] 4.8 install.sh 给每个 unit 写 drop-in `EnvironmentFile=/etc/isales/env/<service>.env` 到 `/etc/systemd/system/<unit>.d/env.conf`；先写空 `EnvironmentFile=` 清除 unit 自带的 legacy 路径（engine/scheduler/worker/modem-controller 均 ship 了 `/etc/isales/<name>.env` 旧路径）
- [x] 4.9 新增 `deploy/scripts/migrate.sh`：在 `/opt/isales/current/` 下运行 `venv/bin/alembic -c isales-common/alembic.ini upgrade head`；`--dry-run` 改成 `alembic history -i`；幂等；从 `/etc/isales/env/api.env` 加载 ISALES_DATABASE_URL
- [ ] 4.10 验证：在 PR #3 已 provision 的 VM 上跑 install.sh + migrate.sh，目录结构与软链候选都符合预期；alembic upgrade head 跑通 — DEFERRED 到 PR #11 release-gate

## 5. deploy.sh（PR #5）

- [x] 5.1 新增 `deploy/scripts/deploy.sh <release-ts>`：先校验 `/opt/isales/releases/<ts>/` 存在且 `venv/bin/python` 可执行；`--dry-run` / `--force` / `--include-modem`
- [x] 5.2 deploy.sh 切 current 软链：`ln -sfn /opt/isales/releases/<ts> /opt/isales/current`
- [x] 5.3 deploy.sh 检测当前是否在低峰期（默认按 22:00–08:00 判断，可被 `--force` 跳过）；非低峰且无 `--force` MUST 退出并提示 engine restart 会断活跃通话
- [x] 5.4 deploy.sh 按顺序 `systemctl restart isales-telephony-api isales-scheduler isales-worker isales-engine isales-api`；每步后跑 `systemctl is-active`，失败 abort 并打印 `journalctl -u <service> -n 50`
- [x] 5.5 deploy.sh `nginx -t && systemctl reload nginx`
- [x] 5.6 deploy.sh 仅当 `--include-modem` 才 `systemctl restart isales-modem-controller`；默认跳过并打印 "skipped (硬件耦合)"
- [x] 5.7 deploy.sh 末尾汇总：列出每个 service 的 active state 与 PID
- [ ] 5.8 验证：在 PR #4 已 install 的 VM 上跑 deploy.sh — DEFERRED 到 PR #11 release-gate

## 6. rollback.sh（PR #6）

- [x] 6.1 新增 `deploy/scripts/rollback.sh <release-ts>`：`set -euo pipefail` + `--dry-run`
- [x] 6.2 rollback.sh 校验 `<release-ts>` 存在且不是当前；切 current 软链回 `<release-ts>`；按 deploy.sh 同样的顺序 restart；额外的 confirm() prompt 与 `--force` 闸门
- [x] 6.3 rollback.sh MUST NOT 跑 `alembic downgrade`；末尾打印 "DB schema unchanged. If schema rollback needed, see RUNBOOK §rollback-schema"
- [x] 6.4 rollback.sh 提供 `--list` 列出 `/opt/isales/releases/` 下所有 release（按 mtime 倒序，含 git describe ref + 当前 release 标记）
- [ ] 6.5 验证：在 PR #5 跑过 deploy.sh 后，伪造一个老 release 然后跑 rollback.sh — DEFERRED 到 PR #11 release-gate

## 7. 备份脚本与 cron（PR #7）

- [x] 7.1 新增 `deploy/scripts/backup_pg.sh`：从 `/etc/isales/env/api.env` 读 `ISALES_DATABASE_URL`，剥 `+asyncpg` 走 libpq；`pg_dump --format=custom | gzip > .sql.gz`；retain 14；失败 logger 写 syslog
- [x] 7.2 新增 `deploy/scripts/backup_redis.sh`：用 `redis-cli --rdb` 拉一致 RDB 快照（**与原 spec/proposal 中"复制 appendonly.aof"的措辞偏离**——AOF 文件归 redis 用户所有 + Redis 7 multipart AOF 目录布局兼容差，redis-cli 路径更稳健；spec scenario "Redis 持久化" 已同步更新）；retain 14；失败 logger 写 syslog
- [x] 7.3 新增 `deploy/cron/isales-backup.cron`：`30 2 * * * isales /opt/isales/current/deploy/scripts/backup_pg.sh && .../backup_redis.sh`；install.sh `step_cron` 已经把 cron 文件 cp 到 `/etc/cron.d/`
- [ ] 7.4 验证：手工触发两个脚本 — DEFERRED 到 PR #11 release-gate（macOS 开发机无 Linux logger / 无生产 PG/Redis 路径）

## 8. 监控配置模板（PR #8）

- [x] 8.1 新增 `deploy/monitoring/prometheus.yml.example`：scrape 覆盖 api / engine / scheduler / worker / telephony-api / node + postgres exporter + self；未实现 `/metrics` 的 target 用 yaml 注释标 `# TODO: pending /metrics implementation`
- [x] 8.2 新增 `deploy/monitoring/alert_rules.yml.example`：4 条最小告警（dial 队列堆积 / device flagged 比例 / callback 失败率 / PG 连接数）
- [x] 8.3 新增 `deploy/monitoring/grafana/isales-overview.json`：4-panel overview dashboard（在播 / 队列深度 / 接通率 / 服务错误日志计数）
- [x] 8.4 新增 `deploy/monitoring/README.md`：运维侧 Prometheus + Grafana + exporters 安装方式 + `/metrics` 实现进度表
- [x] 8.5 验证：`jq . isales-overview.json > /dev/null` 通过；YAML `safe_load` 双文件通过；`promtool check rules` DEFERRED 到 PR #11（开发机无 promtool）

## 9. deploy-check Make target（PR #9）

- [x] 9.1 主仓 `Makefile` 加 `deploy-check` target
- [x] 9.2 `deploy-check` 跑 `shellcheck -x` on 8 个脚本
- [x] 9.3 新增 `deploy/scripts/check_env_consistency.py`：解析每个 `deploy/env/*.env.example`（含注释行）的 var 集合，与对应服务仓 README "Environment" / pipe-table 章节列出的 var 集合 diff；不一致 exit 1 并打印缺失/多余项；telephony 4 列表格按 api / modem 列过滤
- [x] 9.4 `deploy-check` 调用 #9.3
- [x] 9.5 主仓 README 加一节 "校验 deploy/ 脚本与 env 一致性"，与 `make test-all` 并列
- [x] 9.6 验证：`make deploy-check` 通过 — shellcheck 8 脚本零警告，env 一致性检查 6 服务通过

## 10. RUNBOOK（PR #10）

- [x] 10.1 新增 `deploy/RUNBOOK.md`：6 大章节
- [x] 10.2 §1 首次部署 step-by-step：clone → provision.sh → 编辑 env → install.sh → migrate.sh → deploy.sh --force --include-modem → smoke test
- [x] 10.3 §2 日常发版：`install.sh new-tag` → `migrate.sh` → `deploy.sh new-ts`；标注 engine restart 风险与低峰期窗口；modem-controller 默认不重启
- [x] 10.4 §3 回滚流程：`rollback.sh --list` / `rollback.sh prev-ts`；§3.1 schema 回滚（含 forward-fix vs downgrade 决策与 pg_dump 兜底）
- [x] 10.5 §4 备份恢复演练：§4.1 PG 用 `pg_restore` 到独立 db + alembic_version + campaign count 验收；§4.2 Redis 用 RDB 替换 dump.rdb 后 dbsize 验收；强调"季度演练"
- [x] 10.6 §5 故障排查 cheatsheet：9 项 symptom→first-step→next-step 表 + §5.1 一行命令片段
- [x] 10.7 §6 上线前 hard-gate 清单：7 项硬阻塞条件
- [x] 10.8 主仓 README "Production deployment" 节链接更新到具体章节锚点

## 11. VM 端到端演练（release-gate）

- [ ] 11.1 准备一台干净 Ubuntu 22.04 LTS VM（4 core / 8G / 30G）
- [ ] 11.2 跑完整序列：clone meta-repo + 服务仓 → `provision.sh` → 编辑 `/etc/isales/env/*.env` 填 secret → `install.sh v0.1.0` → `migrate.sh` → `deploy.sh <ts>`
- [ ] 11.3 浏览器访问 nginx，登录 isales-web、创建 campaign、导入 lead、确认全链路无 5xx（mock provider 即可，无须真硬件）
- [ ] 11.4 演练 rollback：`install.sh v0.1.0-1`（伪造改动）→ `deploy.sh new-ts` → `rollback.sh prev-ts`，确认服务恢复到旧版本
- [ ] 11.5 演练备份恢复：触发 `backup_pg.sh` → 启另一个 PG 实例 → 从备份恢复 → 验证 `SELECT count(*) FROM campaign` 一致
- [ ] 11.6 把演练 log + 截图归到 archive 时的 PR 描述；正式归档前必须完成
- [ ] 11.7 演练发现的脚本 bug 单独开 follow-up PR 修；本演练不卡死后续无关 change
