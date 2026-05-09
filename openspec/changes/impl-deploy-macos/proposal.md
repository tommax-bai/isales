## Why

iSales v1 当前明确假设 **Linux 单主机**：`architecture` spec § "v1 单主机部署" 写明 Linux + systemd；`deployment-topology` spec § "v1 单主机部署模型" 写明 Ubuntu 22.04 + apt + systemd；modem-controller 走 `pyudev` + ALSA。

需要把生产部署能力扩展到 **macOS 14+ Sonoma on Apple Silicon**，作为门店 / 现场拨号工作站（Mac mini / Mac Studio 插 USB GSM modem）。**Linux 仍是主线**，本 change 是新增并行平台支持，不替换。

最关键的两块差异在 modem-controller 硬件层：
- **USB 设备发现 / 插拔事件**：`pyudev` 是 Linux 内核 udev 的 Python 绑定，macOS 没有 udev → 改用 IOKit (`pyobjc-framework-IOKit`)
- **音频管道**：`ALSA` 是 Linux 内核 audio API，macOS 没有 ALSA → 改用 Core Audio (`sounddevice` + PortAudio)

其他层差异较小（systemd → launchd、apt → brew、`/dev/ttyUSB*` → `/dev/cu.usbmodem*`），但仍需要平行的部署 / 服务管理脚本。

核心架构选择：**单仓 + 平台抽象层**（不是三仓 fork）。业务代码 0 改动；platform-specific 代码用 ABC 隔离；ABC 设计**为未来 Windows 平台扩展预留位子**（错误类型 / 事件调度模型 / 命名约定不绑死 Linux + macOS 二元）。这样长期维护成本只增加 ~1.3x（vs 三仓 fork 的 ~3x）。

## What Changes

### 平台抽象层（isales-telephony 仓核心改动）

- **新增 `modem_controller/platforms/` 包**：抽离 USB 设备监听到 `UsbDeviceWatcher` ABC
  - `base.py`：`UsbDeviceWatcher` ABC + `UsbAddEvent` / `UsbRemoveEvent` / `UsbDeviceWatcherError` 平台中立类型；事件投递走异步队列（asyncio.Queue），不绑死 Linux epoll 模型
  - `linux_udev.py`：当前 `udev_watcher.py` 内容迁入，零行为变化
  - `macos_iokit.py`：新实现，用 `pyobjc-framework-IOKit` 订阅 `IOServiceMatching("IOUSBHostDevice")` notification port，等价 udev `add` / `remove` 事件
  - `__init__.py`：按 `sys.platform` 选实现；`darwin` → IOKit、`linux` → udev、其他平台 → raise `UsbDeviceWatcherError(platform=…)`
- **新增 `modem_controller/audio/` 包**：抽离 PCM 双向管道到 `AudioPipe` ABC
  - `base.py`：`AudioPipe` ABC + `AudioPipeError`、`AudioFormat`(8kHz/16kHz/sample_width) 中立类型
  - `linux_alsa.py`：现有实现迁入
  - `macos_coreaudio.py`：新实现，用 `sounddevice`（PortAudio 后端，macOS 自动走 Core Audio）实现 8kHz↔16kHz 重采样 + 双向流
- **设备节点路径**：`/dev/ttyUSB0` 与 `/dev/cu.usbmodem*` 的差异由 `pyserial.tools.list_ports.comports()` 统一抽象（pyserial 已跨平台）；调用方不再硬编码路径前缀

### macOS 部署树（meta-repo 改动）

- **`deploy/macos/`**（与现有 `deploy/scripts/` 平行；Linux 路径改名为 `deploy/linux/scripts/`，向后兼容软链保留 `deploy/scripts/` -> `linux/scripts/` 一个发版周期）：
  - `provision.sh`：`brew install postgresql@15 redis nginx python@3.12 node@20 pkg-config`；用 `dscl` + `sysadminctl` 创建 `_isales` 系统账户（macOS 系统账户用 `_` 前缀且 UID < 500）；初始化 PG / Redis；写入 `/etc/isales/env/`（macOS 也用 `/etc/`，与 Linux 一致）
  - `install.sh`：clone 7 仓 + venv（python3.12 from `/opt/homebrew/bin/python3.12`，**仅 Apple Silicon**）+ pip install + npm build + 把 plist 文件部署到 `/Library/LaunchDaemons/`，原子软链 `/opt/isales/current` 用 `ln -sfn`
  - `deploy.sh`：`launchctl bootout system/com.isales.X && launchctl bootstrap system /Library/LaunchDaemons/com.isales.X.plist`，按依赖顺序与 Linux 版一致
  - `rollback.sh`：与 Linux 版结构一致，命令换 launchctl
  - `backup_pg.sh` / `backup_redis.sh`：几乎不动；`logger -t isales-backup` 在 macOS 上写 unified logging，可通过 `log show --predicate 'subsystem == "isales-backup"'` 查询
  - `migrate.sh`：完全复用，alembic 跨平台
- **`deploy/macos/plist/`**：6 份 launchd plist，对应 6 个服务 unit。**因为 launchd 不支持 EnvironmentFile=**，install.sh 在装配期把 `/etc/isales/env/<service>.env` 内联展开到 plist 的 `<EnvironmentVariables>`；env 改了要重写 plist + launchctl bootout/bootstrap，在 RUNBOOK 里说明
- **`deploy/macos/launchd-jobs/`**：备份用 launchd `StartCalendarInterval` plist 替代 cron

### 平台条件依赖（isales-telephony pyproject.toml）

```toml
[project.optional-dependencies]
linux = ["pyudev>=0.24"]
macos = [
    "pyobjc-framework-IOKit>=10.0; platform_system=='Darwin'",
    "pyobjc-core>=10.0; platform_system=='Darwin'",
    "sounddevice>=0.4.6",
]
```

各平台 install 脚本各装各的 extras：Linux `pip install -e ".[linux]"` / macOS `pip install -e ".[macos]"`。

### CI 矩阵

GitHub Actions 加 `runs-on: macos-14` job 并行跑 isales-telephony 的 macOS-only 测试集（`pytest -m macos`）；其他仓维持仅 Linux CI。`isales-telephony/tests/macos/` 子目录用 `@pytest.mark.skipif(sys.platform != "darwin", reason="macos only")` 标记。

### 真硬件验收（关闭条件）

本 change MUST 在一台 Mac mini M2 / M4 或 Mac Studio M2 上插 1 枚 USB GSM modem，端到端打通至少 3 轮真实对话（与 Linux stage 6 验收等价），且 **Core Audio 端到端时延基线 ≤ 200ms**——超出阻塞合并，必须排查到达标。

### deploy-check 扩展

`Makefile` `deploy-check` target 在 macOS 上跑时也校验 `deploy/macos/scripts/*.sh` 通过 shellcheck；`check_env_consistency.py` 不动（env 模板与 platform 无关）。

## Capabilities

### New Capabilities

无新 capability。

### Modified Capabilities

- `architecture`：v1 部署模型从 "Linux 单主机" → "Linux 或 macOS 14+ Apple Silicon 单主机"；进程隔离 requirement 加上 launchd plist 平行选项；不影响"7 仓库微服务架构 / 数据存储统一 / 仓库职责边界"等其他 requirement
- `deployment-topology`（impl-deploy 已归档，base spec 已存在）：
  - "v1 单主机部署模型" requirement：主机依赖列表与目录骨架平行列出 macOS 选项（brew 包、`/Library/LaunchDaemons/`、`/opt/homebrew/var/db/redis`）
  - "服务启停顺序" requirement：launchctl 命令版与 systemctl 命令版并列，restart 顺序不变
  - "集中化环境变量契约"：launchd 不支持 EnvironmentFile=；macOS 路径用"在 install 期内联展开到 plist"替代，跨服务一致性约束（DATABASE_URL / REDIS_URL / JWT_SECRET）不变
  - "数据持久化与备份基线"：PG / Redis 备份脚本路径与命令在 macOS 上略有差异（unified logging 替代 syslog）；retention / 时间窗口不变
  - "部署脚本幂等与可回滚"：要求扩展到 `deploy/macos/scripts/*.sh`
- `device-hardware`：modem-controller 的 USB 监听与音频管道契约从 "udev / ALSA" 扩展为 "udev/ALSA on Linux 或 IOKit/Core Audio on macOS"；新增 platform-abstraction requirement，要求通过 ABC 调用平台实现，业务代码 MUST NOT 硬编码 `pyudev` / `alsa` 直接 import；engine ↔ modem-controller IPC 协议不变（Unix socket + JSON）

## Impact

- **isales-telephony 仓**：核心改动落地仓
  - 新增 `modem_controller/platforms/` 包（4 文件）+ `modem_controller/audio/` 包（4 文件）
  - 现有 `udev_watcher.py` 内容下沉到 `platforms/linux_udev.py`，外部 import 路径加一层间接
  - `pyproject.toml` 加 `[project.optional-dependencies]` linux/macos extras
  - 新增 `tests/macos/` 子目录：~15 个 macOS-only 集成测试（IOKit watcher add/remove + Core Audio mock 双向 PCM + 时延基线测试）
  - 测试基线变化：Linux 仓 115 → 保持 115（无回归；pyudev 路径包装为 ABC 实现，不改行为）；macOS 上跑会有 ~15 个新增测试 + 部分跳过（仅 Linux 路径）
- **isales-common 仓**：可能加 `utils/platform.py` 提供统一的 platform 检测助手（避免每个仓重复写）
- **meta-repo (`isales/`)**：
  - 现有 `deploy/scripts/` 重命名为 `deploy/linux/scripts/`，原路径保留软链一个发版周期
  - 新增 `deploy/macos/{provision,install,deploy,rollback,backup_pg,backup_redis,migrate}.sh`
  - 新增 `deploy/macos/plist/com.isales.{api,engine,scheduler,worker,telephony-api,modem-controller}.plist`
  - 新增 `deploy/macos/launchd-jobs/com.isales.backup.plist`
  - 新增 `deploy/macos/README.md`；`deploy/RUNBOOK.md` 加 `## §macOS 章节`（条件块 `<details>` 折叠，不另起 RUNBOOK）
  - `deploy/scripts/_lib.sh` 抽出共享部分到 `deploy/common/_lib.sh`，Linux 与 macOS 脚本都 source
- **依赖链**：impl-deploy 已归档（先决条件已满足）；本 change 后续可与 stage 8 hardening change 并行
- **新增运行时依赖**：`pyobjc-framework-IOKit`、`pyobjc-core`、`sounddevice`（仅 macOS 平台启用，平台条件依赖）
- **超出本 change 范围**：
  - Windows 支持（独立 change，工程量预估 10–14 周；本 change ABC 设计为 Windows 预留位子但**不实现** Windows backend）
  - Mac 多主机 / 灰度（与 Linux v1 对齐，单主机起步）
  - macOS 容器化部署（v1 仍 launchd-on-host 模型）
  - macOS 上 stage 8 端到端 hardening 重跑（用本 change 验收过的 macOS 主机另起 hardening change）
  - Intel Mac 兼容（仅 Apple Silicon；Intel Mac 已停产 4 年，brew 路径分叉是负担）
  - macOS 13 / 12 兼容（仅 14+ Sonoma；IOKit USB notification 在 14 上更稳）
- **PR 规模**：~12 PR（与 impl-deploy 同量级，单 change 内拆分；耦合度高，拆多 change 反而难追踪）
- **工程量估算**：~5–7 周一人全职。最大不确定性在 modem-controller IOKit 监听稳定性（USB 重连边界、AT 串口与 macOS modem manager 冲突）与 Core Audio 时延基线达标
