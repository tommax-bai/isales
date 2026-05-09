# Production deployment

iSales v1 支持两种**单主机**部署模型：

- **Linux + systemd**（主线，本 README 主要描述）—— 7 个服务进程通过 systemd 管理，PG / Redis / nginx 作为系统服务
- **macOS 14+ + launchd**（Apple Silicon 门店 / 现场场景）—— 详见 `deploy/macos/README.md`

两套部署的目录骨架（`/opt/isales/{releases,current,backups,logs}` + `/etc/isales/env/`）与 env 模板完全一致；区别集中在服务管理（systemd vs launchd）、包管理器（apt vs brew）与硬件 USB / 音频后端。本目录提供把 7 个服务装配到一台主机所需的全部脚本、模板与文档。

> 与 `openspec/specs/deployment-topology/spec.md` 对应。`architecture` spec 声明了"v1 单主机部署"作为高层选择；`deployment-topology` spec 把对应的可执行运维契约固化下来。

## 部署模型

```
┌─────────────────────────────── 单台 Linux 主机 ───────────────────────────────┐
│                                                                              │
│  systemd 进程：                                                              │
│    isales-api               (FastAPI HTTP + WebSocket)                       │
│    isales-engine            (实时通话引擎)                                   │
│    isales-scheduler         (线索调度)                                       │
│    isales-worker            (Celery 异步后处理)                              │
│    isales-telephony-api     (FastAPI device/SIM CRUD)                        │
│    isales-modem-controller  (USB GSM modem 守护进程)                         │
│                                                                              │
│  系统服务：                                                                  │
│    postgresql-15            (本地数据库)                                     │
│    redis-server             (Redis + AOF 持久化)                             │
│    nginx                    (反代 + isales-web 静态资源)                     │
│                                                                              │
│  目录布局：                                                                  │
│    /opt/isales/                                                              │
│      releases/<ts>/         每次 install.sh 落新目录                         │
│        isales-common/                                                        │
│        isales-{api,engine,scheduler,worker,telephony}/                       │
│        isales-web/dist/     vite build 产物                                  │
│        venv/                7 个 Python 服务共享                             │
│      current -> releases/<ts>    原子软链                                    │
│      backups/{pg,redis}/    每日备份                                         │
│      logs/                  兜底（默认走 journald）                          │
│                                                                              │
│    /etc/isales/env/         集中化 EnvironmentFile（0640 root:isales）       │
│      api.env                                                                 │
│      engine.env                                                              │
│      scheduler.env                                                           │
│      worker.env                                                              │
│      telephony-api.env                                                       │
│      modem-controller.env                                                    │
└──────────────────────────────────────────────────────────────────────────────┘
```

## 主机依赖

| 类别 | 要求 |
|------|------|
| OS | Ubuntu 22.04 LTS 或更新（amd64） |
| Python | `python3.12` + `python3.12-venv` |
| Node | Node.js >= 20（构建 isales-web） |
| 系统包 | `postgresql-15` `redis-server` `nginx` `git` `pkg-config` `libudev-dev` `libasound2-dev` |
| 用户 | 系统用户 `isales:isales`（无 shell） |

## 快速开始

首次部署完整流程见 `RUNBOOK.md`。最小命令序列：

```bash
# 1. 准备主机（一次性）
sudo bash deploy/linux/scripts/provision.sh

# 2. 编辑集中化 env，填入真实 secret
sudoedit /etc/isales/env/api.env
# ... 其他 5 个 service env 同理

# 3. 安装新 release
sudo -u isales bash deploy/linux/scripts/install.sh v0.1.0

# 4. 数据库迁移
sudo -u isales bash deploy/linux/scripts/migrate.sh

# 5. 切换 current 软链 + restart
sudo bash deploy/linux/scripts/deploy.sh <release-ts>
```

## 子目录索引

| 目录/文件 | 用途 |
|-----------|------|
| `env/*.env.example` | 每个服务的环境变量模板（含一致性约束注释） |
| `linux/scripts/provision.sh` | 主机一次性 provision（apt 包 + 用户 + 目录 + Redis AOF） |
| `linux/scripts/install.sh` | 拉 7 仓 + 建 venv + 构建 web，落 `/opt/isales/releases/<ts>/` |
| `linux/scripts/migrate.sh` | `alembic upgrade head` |
| `linux/scripts/deploy.sh` | 切 current 软链 + 按依赖顺序 restart |
| `linux/scripts/rollback.sh` | 切回历史 release（不动 schema） |
| `linux/scripts/backup_pg.sh` | 每日 PG `pg_dump` |
| `linux/scripts/backup_redis.sh` | 每日 Redis AOF 复制 |
| `cron/isales-backup.cron` | Linux 备份 cron 配置 |
| `macos/scripts/` | macOS 平行的 provision / install / migrate / deploy / rollback / backup 脚本 |
| `macos/plist/` | 6 份 launchd plist 模板（`com.isales.<svc>.plist`） |
| `macos/launchd-jobs/com.isales.backup.plist` | macOS 每日备份 launchd 计划 |
| `macos/README.md` | macOS 部署模型说明（拓扑、目录骨架、主机依赖、快速开始） |
| `common/_lib.sh` | 跨平台共用 bash 函数（log/run/parse_common_flags/write_file/...） |
| `monitoring/` | Prometheus / Grafana 配置模板（不强制即时实现 /metrics） |
| `RUNBOOK.md` | 首次部署、发版、回滚、备份恢复、故障排查（Linux 主线 + macOS 折叠节） |

## 不属于 v1 的范围

- 容器化（Docker / docker-compose / K8s）
- 多主机 / 灰度 / 蓝绿
- TLS 终结（v1 假设内网 HTTP）
- Prometheus / Grafana 自动安装（仅提供配置模板）
- alembic downgrade 自动化
- CI/CD 自动部署（人工 ssh 触发）
