# Production deployment

iSales v1 走**单主机 + systemd** 部署模型：7 个服务进程通过 systemd 管理，PostgreSQL 与 Redis 作为同主机系统服务，nginx 反代 isales-web 静态资源。本目录提供把 7 个服务装配到一台 Linux 主机所需的全部脚本、模板与文档。

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
sudo bash deploy/scripts/provision.sh

# 2. 编辑集中化 env，填入真实 secret
sudoedit /etc/isales/env/api.env
# ... 其他 5 个 service env 同理

# 3. 安装新 release
sudo -u isales bash deploy/scripts/install.sh v0.1.0

# 4. 数据库迁移
sudo -u isales bash deploy/scripts/migrate.sh

# 5. 切换 current 软链 + restart
sudo bash deploy/scripts/deploy.sh <release-ts>
```

## 子目录索引

| 目录/文件 | 用途 |
|-----------|------|
| `env/*.env.example` | 每个服务的环境变量模板（含一致性约束注释） |
| `scripts/provision.sh` | 主机一次性 provision（apt 包 + 用户 + 目录 + Redis AOF） |
| `scripts/install.sh` | 拉 7 仓 + 建 venv + 构建 web，落 `/opt/isales/releases/<ts>/` |
| `scripts/migrate.sh` | `alembic upgrade head` |
| `scripts/deploy.sh` | 切 current 软链 + 按依赖顺序 restart |
| `scripts/rollback.sh` | 切回历史 release（不动 schema） |
| `scripts/backup_pg.sh` | 每日 PG `pg_dump` |
| `scripts/backup_redis.sh` | 每日 Redis AOF 复制 |
| `cron/isales-backup.cron` | 备份 cron 配置 |
| `monitoring/` | Prometheus / Grafana 配置模板（不强制即时实现 /metrics） |
| `RUNBOOK.md` | 首次部署、发版、回滚、备份恢复、故障排查 |

## 不属于 v1 的范围

- 容器化（Docker / docker-compose / K8s）
- 多主机 / 灰度 / 蓝绿
- TLS 终结（v1 假设内网 HTTP）
- Prometheus / Grafana 自动安装（仅提供配置模板）
- alembic downgrade 自动化
- CI/CD 自动部署（人工 ssh 触发）
