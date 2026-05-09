# macOS deployment

iSales v1 在 **macOS 14+ Sonoma (Apple Silicon)** 上的单主机部署模型，作为门店 / 现场拨号工作站的并行平台。Linux 仍是主线（见 `../README.md`），本节只描述 macOS 与 Linux 的差异；目录骨架、env 文件、备份保留策略等共享部分在主 README。

> 决策出处见 `openspec/changes/impl-deploy-macos/design.md`。Apple Silicon-only、macOS 14+、`/opt/isales` + `/etc/isales` 路径与 Linux 一致是已经在 propose 阶段拍板的硬约束。

## 部署模型

```
┌─────────────────── macOS 14+ Apple Silicon 单主机 ────────────────────┐
│                                                                       │
│  launchd 进程（/Library/LaunchDaemons/）：                            │
│    com.isales.api               (FastAPI HTTP + WebSocket)            │
│    com.isales.engine            (实时通话引擎)                        │
│    com.isales.scheduler         (线索调度)                            │
│    com.isales.worker            (Celery 异步后处理)                   │
│    com.isales.telephony-api     (FastAPI device/SIM CRUD)             │
│    com.isales.modem-controller  (USB GSM modem 守护进程)              │
│    com.isales.backup            (StartCalendarInterval 02:30 daily)   │
│                                                                       │
│  brew services（$BREW_PREFIX = /opt/homebrew）：                      │
│    postgresql@15                                                      │
│    redis             (AOF appendonly yes / appendfsync everysec)      │
│    nginx             (反代 + isales-web 静态资源)                     │
│                                                                       │
│  目录布局（与 Linux 完全一致）：                                      │
│    /opt/isales/{releases,current,backups/{pg,redis},logs}             │
│    /etc/isales/env/{api,engine,scheduler,worker,                      │
│                     telephony-api,modem-controller}.env               │
│    /var/run/isales/                                                   │
└───────────────────────────────────────────────────────────────────────┘
```

## 主机依赖

| 类别 | 要求 |
|------|------|
| OS | macOS 14 (Sonoma) 或更新 |
| 架构 | **仅 Apple Silicon** (`uname -m == arm64`) |
| Homebrew | 装在 `/opt/homebrew/`（Apple Silicon 默认路径） |
| Python | `python@3.12` (brew) |
| Node | `node@20` (brew) |
| 系统包 | `postgresql@15` `redis` `nginx` `pkg-config` `git` |
| 用户 | 系统账户 `_isales:_isales`（UID 298，shell `/usr/bin/false`，`IsHidden 1`） |

provision.sh 会用 `dscl` + `brew install` 把上述依赖落齐。Intel Mac 与 macOS 13- 会被 `require_macos` 直接拒绝。

## 快速开始

```bash
# 1. 安装 Homebrew（如未装）—— 一次性，需用普通用户身份
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# 2. 主机 provision（一次性；brew install + 创建 _isales 用户 + 目录骨架 + PG/Redis init）
sudo bash deploy/macos/scripts/provision.sh

# 3. 编辑集中化 env，填入真实 secret
sudoedit /etc/isales/env/api.env
# ... 其他 5 个 service env 同理

# 4. 安装新 release（git clone + venv + npm build + 渲染 launchd plist）
sudo bash deploy/macos/scripts/install.sh v0.1.0

# 5. 数据库迁移
sudo bash deploy/macos/scripts/migrate.sh

# 6. 切 current 软链 + launchctl kickstart 6 个服务
sudo bash deploy/macos/scripts/deploy.sh <release-ts>
```

## 与 Linux 的关键差异速查

| 关注点 | Linux | macOS |
|--------|-------|-------|
| 服务管理 | `systemctl restart isales-api.service` | `launchctl kickstart -k system/com.isales.api` |
| 服务状态 | `systemctl is-active <svc>` | `launchctl print system/<label>` 解析 `state = running` |
| 日志查询 | `journalctl -u isales-api -n 50` | `log show --predicate 'subsystem == "com.isales.api"' --last 5m` |
| Env 注入 | systemd `EnvironmentFile=/etc/isales/env/<svc>.env` | install.sh 用 `plistlib` 内联展开到 `<EnvironmentVariables>` 字典 |
| 包管理 | `apt-get install` | `brew install`（必须以非-root 身份；脚本通过 `sudo -u "$SUDO_USER"` 反向） |
| nginx | `nginx -t && systemctl reload nginx` | `nginx -t && brew services reload nginx` |
| 备份触发 | `cron`（`/etc/cron.d/isales-backup`） | launchd `com.isales.backup` (StartCalendarInterval 02:30) |
| USB 监听 | pyudev (Linux netlink) | `pyserial.tools.list_ports` 1 Hz 轮询 + diff |
| 音频后端 | ALSA (`pyalsaaudio`) | Core Audio (`sounddevice` / PortAudio) |

## launchd 内联 env 的语义

launchd 没有 systemd 的 `EnvironmentFile=` 等价物。每次 `install.sh` 运行时会把 `/etc/isales/env/<svc>.env` 的 KV 解析后**内联**写到 `/Library/LaunchDaemons/com.isales.<svc>.plist` 的 `<key>EnvironmentVariables</key>` 字典里。

含义：
- 编辑 `/etc/isales/env/*.env` 后**必须**重跑 `install.sh`（或 `bootout` + `bootstrap` 该 plist）才能让新值生效。Linux 的"改 env 后 systemctl restart 即可"在 macOS 不成立。
- plist 是机密写入对象（包含 PG 密码 / JWT secret），install.sh 安装时用 `chmod 0644 root:wheel`，但内容仍可被 root 与本机管理员读取——这与 systemd EnvironmentFile 模式等价。

详见 design.md Decision 3。

## 故障排查 cheatsheet

见主 `RUNBOOK.md` § "macOS 部署 (Apple Silicon, macOS 14+)"。
