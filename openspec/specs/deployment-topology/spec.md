# deployment-topology Specification

## Purpose
TBD - created by archiving change impl-deploy. Update Purpose after archive.
## Requirements
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

### Requirement: Windows 边缘形态

v1.0 边缘机 platform option SHALL 包括 Windows 10 21H2+ / Windows 11（x64），作为商用主形态；macOS Mac mini 形态保留为 PoC / 内部 QA 场景。Windows 边缘进程 SHALL 以单 PyInstaller frozen exe + asyncio + Qt 主循环（qasync）形态运行，通过 Windows 启动注册表 Run 项实现"登录即启 tray app"。

本 Requirement 补充 A2 `arch-cloud-edge-split` 中「边缘机部署」要求，把 Windows 与 macOS 作为并列 platform option 落地。

#### Scenario: Windows 系统要求

- **WHEN** v1.0 客户员工部署边缘客户端
- **THEN** PC SHALL 满足：
  - Windows 10 21H2 或更新（x64）/ Windows 11（x64）
  - 至少 4 GB RAM / 200 MB 可用磁盘（含 PyInstaller frozen 包 + DingRTC SDK DLL）
  - 至少 1 个可用 USB 端口（接 GSM modem）
  - 网络可访问云端 gRPC TLS endpoint + 阿里 RTC UDP 端口
  - **不要求** Python 运行时已安装（PyInstaller 包自带）
  - **不要求** 管理员权限（注册表写 HKCU，AppData 写 user 目录）
  - **不支持** Windows ARM64 / Windows Server / Windows 10 LTSC（v1.0 范围外）

#### Scenario: Windows 安装路径约定

- **WHEN** 部署 Windows 客户端（A2 时点：手工解压 + 脚本写注册表；D3 后用 MSI 安装包）
- **THEN** 文件 SHALL 落在以下位置：
  ```
  C:\Users\<user>\AppData\Local\Programs\isales\
    isales-telephony.exe        # PyInstaller frozen 主程序
    _internal\                  # PyInstaller _MEIPASS 等价（Python 运行时 + 依赖）
    vendor\
      dingrtc-windows\         # DingRTC 3.x SDK Windows native binary（.dll）+ 项目内 pybind11 binding
    icons\
      tray.ico
    env.example.txt             # 空 env 模板

  C:\Users\<user>\AppData\Roaming\isales\
    env\
      telephony.env             # 用户 token + cloud endpoint 配置（含 EDGE_DEVICE_TOKEN）
    sqlite\
      edge_buffer.db            # 离线事件 buffer（A2 已定义）
    logs\
      telephony.log
  ```
- `AppData\Local\Programs` 装程序、`AppData\Roaming` 装用户配置，符合 Windows 标准约定；MUST NOT 把可写文件（env / sqlite / log）混到 `Local\Programs` 目录（与未来 D3 MSI 安装目录权限模型冲突）

#### Scenario: Windows 进程托管（启动注册表 Run 项）

- **WHEN** Windows 客户端部署
- **THEN** SHALL 写入 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`，名为 `ISales`，值指向 `isales-telephony.exe` 完整路径；MUST 使用 HKCU 而非 HKLM（不需要管理员权限 + 多用户 PC 各自独立配置）；用户登录后 tray app SHALL 自动启动；MUST NOT 引入 Windows Service 形态（v1.0 范围；服务化形态如有需要由 D3 评估）

#### Scenario: 单进程异步架构

- **WHEN** Windows 客户端运行
- **THEN** isales-telephony SHALL 以**单一进程** + qasync（融合 Qt event loop 与 asyncio）形态运行；进程内 asyncio task group 含：modem-controller / audio-bridge / cloud-edge gRPC client / 本地 SQLite buffer / 本地 telephony-api HTTP loopback；进程内 Qt 端含：pystray tray icon（daemon thread）/ PySide6 诊断小窗 / PySide6 激活码对话框；**MUST NOT** 拆为多进程或引入 IPC（同一进程内 asyncio Queue 即可）

#### Scenario: Tray UX 二态

- **WHEN** Windows 客户端运行
- **THEN** tray icon SHALL 展现二态：
  - **绿色**：cloud-edge gRPC 已连接 + 至少一个 modem 处于 `idle` 状态
  - **红色**：cloud-edge 断线 ≥ 30 s 或所有 modem `offline`
- D1 范围 MUST NOT 引入三态色 / 桌面通知 / 详细告警类型（这些归 D2 `hardware-observability`）；右键菜单 SHALL 至少含 "打开诊断窗口" / "重新激活" / "查看日志" / "退出" 四项

#### Scenario: 激活码注册流程

- **WHEN** Windows 客户端首次启动且检测到 `%APPDATA%\isales\env\telephony.env` 不存在或缺少 `ISALES_EDGE_DEVICE_TOKEN`
- **THEN** SHALL 弹出 PySide6 激活码对话框，要求用户粘贴激活码（A2 阶段激活码 = 云端签发的静态 EDGE_DEVICE_TOKEN 字符串）+ 可选的 cloud endpoint（含合理默认值）；用户提交后 SHALL：
  1. 校验激活码格式（非空 / 长度合理 / 字符集）
  2. 写入 `%APPDATA%\isales\env\telephony.env`（含 `ISALES_EDGE_DEVICE_TOKEN` 与 `ISALES_CLOUD_GRPC_ENDPOINT`），文件权限交由 Windows ACL 默认（user-owned）
  3. 重启 cloud-edge gRPC client task（无需重启整个进程）
  4. 连接成功 SHALL 关闭对话框 + tray icon 转绿；连接失败 SHALL 在对话框显示错误 + 允许用户重输

#### Scenario: 激活码失效与重新激活

- **WHEN** 已激活的客户端 gRPC server 端验证失败（如 token 在云端被吊销 / 边缘机被换 token）
- **THEN** tray icon SHALL 转红 + 弹通知 "激活失败，请检查激活码"；右键菜单 "重新激活" SHALL 弹出激活码对话框，允许覆盖现有 token；MUST NOT 在 token 无效时静默重试（避免误导用户）

#### Scenario: macOS 边缘形态保留

- **WHEN** v1.0 部署
- **THEN** macOS Mac mini 形态（由 `impl-deploy-macos` 已 ship 的 launchd plist 部署套件）SHALL 继续作为支持选项，主要用于：(a) iSales 内部 QA / PoC 环境（A2 主形态）/ (b) 个别企业客户机房集中部署需求；商用主推 Windows，但 macOS 路径 MUST NOT 被本 change 移除

#### Scenario: cloud-edge full daemon 拨通真号端到端实测

- **WHEN** Windows edge daemon 起在 dev box 上 + ECS engine 已部署 + provider_credential DB 装载 + RTC AppKey 已在 engine.env + PG 含 campaign + lead (phone=+8613301035545 / status=new) 种子
- **THEN** scheduler tick 取数 → engine push DialRequest Redis 队列 → engine consume + RtcTelephonyClient join DingRTC channel + DialCommand 通过 cloud-edge gRPC 到 edge → edge SIM7600G-H 实拨 `ATD+8613301035545;` → modem 上报 `CONNECT` → 双方加入同 channel → engine 调 volcengine TTS 生成 PCM → edge 接收 PCM 通过 SerialPcm 推向 modem → 接听端 (dev 自己手机) 听到 AI 开场白 → 挂断后 engine 落 call_record + transcript[0] 含 AI 文本；SHALL 在两份 STATE.md (cloud + windows-edge) 记录 MVP gate 通过证据 (call_record.id / duration_s / transcript[0] / "AI 开场白是否听到 yes/no"，必须 yes 才算通过)

### Requirement: Windows 客户端依赖与打包

Windows 客户端 SHALL 通过 PyInstaller 打包为可移植目录（onedir），含 Python 运行时 + 所有 PyPI 依赖 + ARTC SDK Windows native binary；最终产物 SHALL 在干净的 Windows 10 21H2+ / Windows 11 PC 上解压即可运行（无需用户单独装 Python 或 VC 运行时）。

#### Scenario: Windows-specific 依赖

- **WHEN** 边缘 Windows 客户端打包
- **THEN** 依赖 SHALL 至少包含：
  - `pystray`（tray icon）
  - `PySide6`（Qt UI，LGPL 商用友好）
  - `qasync`（Qt + asyncio 融合）
  - `sounddevice`（PortAudio Python bindings → WASAPI）
  - `pyserial`（COM 端口枚举与 IO，已是既有依赖）
  - `pywin32`（注册表 + Windows 启动项写入）
  - `grpcio` / `grpcio-tools` / `protobuf`（与 A2 cloud-edge gRPC client 一致）
  - 阿里 ARTC SDK for Windows native binary（vendor）+ 项目内 pybind11 binding（`aliyun_artc_pywrap.pyd`，由 build.ps1 CMake 阶段产出，详见 `openspec/changes/windows-artc-pybind11/`）
- macOS / Linux 平台 MUST NOT 强制安装上述 Windows-specific 包（通过 pyproject `extras` 或 platform marker 隔离）

#### Scenario: PyInstaller 打包配置

- **WHEN** 执行 `deploy/edge/windows/build.sh` 或等价构建脚本
- **THEN** PyInstaller SHALL：
  - 模式：`onedir`（不用 `onefile`，避免每次启动解压 200-500 ms 延迟 + AV 误报）
  - 入口：`isales_telephony/main_windows.py`
  - 显式包含 ARTC SDK Windows native `.dll` 文件（`binaries` 节）
  - 显式包含 tray icon `.ico` 资源（`datas` 节）
  - 隐藏导入：`aliyun_artc_pywrap`（项目内 pybind11 模块名，详见 `openspec/changes/windows-artc-pybind11/`）、`PySide6.QtCore` 等运行时 import 模块
  - 输出目录：`dist/isales-telephony/`（`isales-telephony.exe` + `_internal/`）
  - 不强求代码签名（D3 处理 EV Authenticode）

#### Scenario: 部署脚本

- **WHEN** 用户首次部署 Windows 客户端
- **THEN** `deploy/edge/windows/install.ps1`（PowerShell 脚本）SHALL：
  1. 解压发布 zip 到 `%LOCALAPPDATA%\Programs\isales\`
  2. 写入 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` 启动项
  3. 创建 `%APPDATA%\isales\{env,sqlite,logs}\` 目录
  4. **不**写入 env 文件中的 token（由 tray app 首次启动的激活码对话框完成）
  5. 启动 `isales-telephony.exe`
- 卸载脚本 `deploy/edge/windows/uninstall.ps1`：删除注册表 Run 项 + 删除 `%LOCALAPPDATA%\Programs\isales\` + 保留 `%APPDATA%\isales\` 以备重装（卸载彻底清理留给 D3）

#### Scenario: 网络要求（与 A2 一致）

- **WHEN** Windows 边缘机部署
- **THEN** SHALL 能出向访问：
  - 云端 cloud-edge gRPC TLS endpoint
  - 阿里 RTC PaaS 媒体面（动态 UDP 端口段，备用 TCP）
  - OSS endpoint（远程诊断包上传 / 开场白预渲染下载占位）
- MUST NOT 监听任何公网端口；本地 telephony-api MAY 监听 `127.0.0.1` 任一端口仅供本机查询；Windows 防火墙规则 MAY 由 install.ps1 自动配置出向规则

### Requirement: macOS dev/QA 形态走真 Aliyun RTC + 真 cloud engine（dev-only，与 Windows 商用并列）

iSales 边缘进程在 macOS 上 SHALL 提供 **dev/QA 形态**：通过项目内 PyObjC binding 接入真 Aliyun RTC SDK，与既有 cloud engine（`121.89.85.150` 上 Linux Python wrapper SDK）通过真 Aliyun RTC PaaS 互通；与 Windows 商用形态走真 Aliyun RTC + 真 GSM modem 并列，**但不**作为 v1.0 MVP 验收路径。

本形态服务于开发同学在 mac 工作机上做策略层 + 工程层的真 RTC 闭环演练，与 Windows 商用 edge **等同地** join 真 RTC 房间，复用既有 A2 控制面（cloud-edge gRPC bidi）+ 数据面（真 Aliyun RTC），dev 测出的策略机制行为（barge-in / VAD / 垫词 / handoff / goal partial）可外推到 Windows 商用。

形态对比（macOS 上当前有三种）：

- **macOS 商用形态**：**不存在** — 商用唯一形态是 Windows + 真 GSM modem + 真 Aliyun RTC（由 `arch-cloud-edge-split` + `windows-artc-pybind11` 联合交付）
- **macOS QA / PoC 形态（既有，`impl-deploy-macos`）**：launchd plist 部署 + `MacosRtcSession` 同进程 loopback mock + 真 GSM modem（如有）；保留作 CI / unit-test / 早期 PoC 演练
- **macOS dev/QA 真 Aliyun RTC 形态（本 Requirement 新增）**：PyObjC binding + 真 Aliyun RTC + 真 cloud engine + dev-no-modem（mac 装不了 GSM modem 驱动）

本形态 **MUST NOT** 作为 v1.0 MVP 验收路径，**MUST NOT** 进入商用 PyInstaller / Windows build / cloud deploy / RUNBOOK-cloud，**MUST NOT** 被任何客户机环境使用。

#### Scenario: dev/QA 真 Aliyun RTC 形态启动路径

- **WHEN** dev 同学需要在 mac 工作机上做真 RTC 策略 / 工程闭环演练
- **THEN** 启动方式 SHALL 是：
  1. 解压 `AliRTCSdk_7.8.10000-SNAPSHOT.zip` 到 `~/codes/vendor/AliRTCSdk_macos/`（vendor 不进 git）
  2. `pip install -e '.[dev,macos,macos-artc]'`（`macos` extras = sounddevice for modem-controller，`macos-artc` extras = pyobjc-core + pyobjc-framework-Cocoa for audio_bridge）
  3. `isales-telephony-edge --cloud-endpoint 121.89.85.150:50051 --edge-token-file <jwt> --dev-no-modem --dev-channel <demo-id> --dev-uid mac-dev-01`
- 启动后 edge 通过 PyObjC 加载 `AliRTCSdk.framework` → `MacosArtcPyObjCSession` 真 join Aliyun RTC 房间 → cloud engine 看到 edge 是真 RTC peer → 拨真手机时 mac 上听到 AI 开场白

#### Scenario: 与 Windows 商用契约的边界

- **WHEN** v1.0 MVP 验收 / 客户预演 / 任何对外演示
- **THEN** SHALL **NOT** 使用 macOS dev/QA 形态；唯一验收路径仍是 Windows 商用形态（Windows frozen exe + 真 Aliyun RTC + 真 GSM modem + 拨真手机 → 听到 AI 开场白）
- macOS dev/QA 形态测出的**绝对延迟数字**（mic → engine → speaker latency P95）SHALL **NOT** 直接外推到 Windows 商用——mac 上没有 modem 8 kHz ↔ RTC 16 kHz 重采样 + USB 串口 PCM 段，audio I/O 由 ARTC SDK 接 mac default device 而非 modem PCM 串口
- 策略机制行为（barge-in 触发逻辑 / VAD 阈值 / 垫词 / handoff / goal partial）SHALL **可以**外推到 Windows 商用，因为策略层在 cloud engine 上跑，不依赖 edge 平台

#### Scenario: 商用打包与构建路径完全隔离

- **WHEN** 跑 Windows 商用 PyInstaller 构建（`deploy/edge/windows/build.ps1`）/ cloud Linux image 构建
- **THEN** PyInstaller spec / cloud image **MUST NOT** 收 `pyobjc-core` / `pyobjc-framework-Cocoa` / `macos_artc_pyobjc.py` / `AliRTCSdk.framework` / `--dev-no-modem` 相关 CLI 代码路径
- `pyobjc-core` / `pyobjc-framework-Cocoa` SHALL 仅在 `isales-telephony` pyproject `[project.optional-dependencies].macos-artc` 中声明；商用构建装 base + Windows-specific extras，不装 `[macos-artc]`
- macOS PyInstaller frozen exe 商用打包 SHALL **不**在本 Requirement 范围（PyObjC + framework 打包路径复杂；dev 直接 `.venv` 跑）

#### Scenario: RUNBOOK 文档位置与边界

- **WHEN** dev 同学查找如何启用 macOS dev/QA 真 Aliyun RTC 形态
- **THEN** 文档 SHALL 位于 `isales-telephony/deploy/edge/macos/RUNBOOK.md`（**不**在 `deploy/RUNBOOK-cloud.md` / `deploy/edge/windows/STATE.md` 中）
- 文档 SHALL 包含：vendor SDK 下载与解压 / framework search path 配置 / 一行启动命令 / dev 演练 step-by-step（拨真手机 / barge-in 实测 / log 查看 / latency 测量）/ 与 Windows 商用契约的边界声明 / 已知 macOS SDK 行为差异（SNAPSHOT 版本）

#### Scenario: mac 装不了 GSM modem 驱动的物理约束接入

- **WHEN** mac 上不存在 GSM modem 驱动 / 物理无法插 USB GSM modem
- **THEN** dev/QA 形态 SHALL 通过 `--dev-no-modem` CLI flag（device-hardware spec § "macOS dev-no-modem orchestrator 路径" 定义）跳过真 modem 链路；cloud 主动 `Cloud2Edge.dial` 时 edge 直接走"已接通" CallSession + audio_bridge.join 真 Aliyun RTC
- 即使有人在 mac 上配出 GSM modem 路径（极少见的硬件场景），dev/QA 形态 SHALL 仍优先使用 `--dev-no-modem` flag，**不**鼓励 mac 上真接 GSM modem（不是商用形态）

#### Scenario: 既有 macOS QA / PoC 形态保留

- **WHEN** 本 Requirement 实装上线
- **THEN** 既有 macOS QA / PoC 形态（`impl-deploy-macos` launchd plist + `MacosRtcSession` mock loopback）SHALL 不被移除，作为 CI / unit-test / 早期 PoC 演练路径继续支持
- 当 PyObjC binding 模块不可用（没装 extras / 没解压 SDK）SHALL fallback 到既有 mock loopback 形态（device-hardware spec § "平台默认路由 darwin → PyObjC binding，fallback to mock" 定义）

### Requirement: 云端 admin web SPA 部署形态（v1.0 IP-direct + nginx）

iSales cloud-side SHALL 部署 `isales-web` Vue 3 SPA 作为统一 admin / boss
console 入口；nginx 作为 SPA 静态服务 + `isales-api` HTTP / WebSocket
反向代理。本 Requirement 与既有 "v1.0 IP-direct" 部署形态并列，**不**改动
isales-api / isales-engine / 其它后端服务的 bind / 监听 / 协议；nginx
仅充当透明 reverse proxy + 静态文件 server。

本 Requirement 反转 `deploy/cloud/STATE.md` 2026-05-17 起的 "nginx deferred"
注脚——nginx 在 v1.0 IP-direct 形态下**作为必装组件**部署。

#### Scenario: nginx 1.x 安装 + listen 80

- **WHEN** cloud-side 首次部署或常规发版
- **THEN** ECS SHALL 装 nginx 1.20+（Aliyun Cloud Linux 3 默认仓库 `dnf
  install nginx`），systemctl enable 常驻
- **THEN** nginx SHALL `listen 80`；**MUST NOT** 在 v1.0 IP-direct 形态启用
  `listen 443 ssl`（HTTPS / TLS 留 v1.x 域名 + 备案路径）
- **WHEN** Aliyun 安全组未开放 80/TCP inbound
- **THEN** 部署 SHALL 在控制台新增规则：协议 TCP，端口 80/80，授权对象
  `0.0.0.0/0`，策略允许（C2 多租户阶段再收紧到白名单 / WAF）

#### Scenario: SPA 静态部署路径 + 权限

- **WHEN** `isales-web/dist/` build artifact 部署到 cloud
- **THEN** SHALL 落到 `/var/www/isales-web/`；目录 owner `nginx:nginx`，
  目录 755 / 文件 644
- **THEN** SHALL 跑 `chcon -R -t httpd_sys_content_t /var/www/isales-web/`
  设置 SELinux context（Aliyun Cloud Linux 3 默认 enforcing）
- **MUST NOT** 把 dist 落 `/opt/isales/current/isales-web/`（与
  sub-repos 路径混淆，权限模型冲突）

#### Scenario: nginx 反代契约 (/api → :8000, /ws → :8000/ws)

- **WHEN** 浏览器请求 `http://121.89.85.150/api/<path>`
- **THEN** nginx SHALL `proxy_pass http://127.0.0.1:8000/<path>`，透传
  `Host` / `X-Real-IP` / `X-Forwarded-For` / `X-Forwarded-Proto`
- **WHEN** 浏览器升级 `ws://121.89.85.150/ws/<path>`
- **THEN** nginx SHALL 反代到 `http://127.0.0.1:8000/ws/<path>`，带
  `Upgrade: websocket` + `Connection: upgrade` 头；`proxy_read_timeout`
  SHALL ≥ 300 秒（Monitor / live-status 类长连接不被默认 60s 杀）
- nginx 配置 SHALL 设 `proxy_connect_timeout 5s`（API 重启 / 故障时 5 秒
  内 fast-fail，不挂浏览器请求）

#### Scenario: SPA fallback for HTML5 history 路由

- **WHEN** 浏览器请求 `http://121.89.85.150/<view>`（如 `/campaigns/3/edit`）
- **THEN** nginx SHALL `try_files $uri $uri/ /index.html`，让 Vue Router
  HTML5 history 模式所有路由都 serve index.html；浏览器 JS 接管路由

#### Scenario: 同源 — 避免 CORS

- **WHEN** 浏览器从 nginx 拿 SPA 并调 `/api/<path>`
- **THEN** Origin = `http://121.89.85.150`，Target = 同源（nginx 反代），
  SHALL **不需要** isales-api 配置 CORS Allow-Origin
- 即：本部署形态下 isales-api **MUST NOT** 引入 `fastapi.middleware.cors`
  / 任何跨域中间件（v1.0 单源场景，CORS 反而是攻击面）

#### Scenario: isales-api / engine 仍 0.0.0.0:8000 / :50051 公开监听

- **WHEN** nginx 上线后
- **THEN** isales-api **仍** bind `0.0.0.0:8000`（不收紧到 127.0.0.1）；
  isales-engine **仍** bind `0.0.0.0:50051`
- **Why**: (a) :50051 是 edge gRPC 入口，必须公网可达；(b) :8000 保留公网作
  Swagger / nginx 配错的 fallback 通道；(c) v1.0 IP-direct 阶段统一 IP 公开
  策略，C2 阶段一次性收紧

#### Scenario: 部署文档同步更新

- **WHEN** 本 Requirement 实装
- **THEN** `deploy/cloud/STATE.md` SHALL 在同一 commit 内删除 "nginx
  deferred" 注脚，改记 "nginx 1.x active port 80"，新增子节 "isales-web 部署
  工件" 含 `/var/www/isales-web/` 路径 + scp 命令模板
- **THEN** `deploy/RUNBOOK-cloud.md` SHALL 在 "首次部署" + "常规发版" +
  "故障速查" 三节分别增加 nginx + SPA 相关内容
- **MUST**：本 Requirement 实装后任何后续 dev session 启动时跑 `STATE.md §
  Bootstrap` 4 命令 SHALL 看到 nginx active + :80 LISTEN，**否则**视为
  部署 drift

#### Scenario: v1.0 不引入 HTTPS / 域名

- **WHEN** v1.0 任何 admin / dev / QA 操作
- **THEN** 浏览器 SHALL 走 `http://121.89.85.150/`，**不**做 TLS 终结
- JWT token 在网络上 SHALL 是**明文**（v1.0 已知 trade-off）；
  Mitigation：本 Requirement 不引入 HTTPS，但 v1.x 路径已锁——同一个 nginx
  容器加 `listen 443 ssl` + Let's Encrypt 证书 + 备案域名即可升级，不动
  服务架构

#### Scenario: 回滚路径

- **WHEN** nginx / SPA 部署后发现严重问题需要回滚
- **THEN** 步骤 SHALL 是：(a) `systemctl stop nginx && systemctl disable
  nginx`；(b) `rm -rf /var/www/isales-web/`；(c) Aliyun console 关 80
  inbound；(d) `STATE.md` 同 commit 改回 "nginx deferred"
- 回滚耗时 SHALL ≤ 5 分钟；isales-api / engine / 其它服务 SHALL 完全不
  受影响

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

### Requirement: 三端 DingRTC 3.9.0 vendor SDK 落点与下载源

iSales 三端（cloud Linux engine / Windows edge / macOS edge）SHALL 统一使用 **DingRTC 3.9.0** vendor SDK（来源 `dingrtc.oss-cn-zhangjiakou.aliyuncs.com`，2025-04-15 release），取代既往三端使用的 ApsaraVideo Live 产品线下 ARTC SDK；三端 SDK MUST 同 minor 同 patch 以保证 vendor 互通契约。

#### Scenario: 三端 vendor SDK 下载源与落点

- **WHEN** 部署 / 开发环境装载 vendor SDK
- **THEN** SHALL 按下表从 DingRTC OSS 拉取：

  | 接入点 | SDK 文件 | CDN 直链 | 解压目标 |
  |---|---|---|---|
  | Cloud Linux engine | `DingRTC_Linux_SDK_3_9_0.zip` (C++) | `https://dingrtc.oss-cn-zhangjiakou.aliyuncs.com/sdk/linux/3.9.0/DingRTC_Linux_SDK_3_9_0.zip` | `/opt/isales/vendor/DingRTC_Linux_SDK_3_9_0/` |
  | Windows edge | `DingRTC_Windows_SDK_3_9_0.zip` (`DingRTC.dll`) | `https://dingrtc.oss-cn-zhangjiakou.aliyuncs.com/sdk/windows/3.9.0/DingRTC_Windows_SDK_3_9_0.zip` | `C:\Users\<user>\codes\vendor\DingRTC_Windows_SDK_3_9_0\` |
  | macOS edge | `DingRTC_macOS_SDK_3_9_0.zip` (`DingRTC.framework`) | `https://dingrtc.oss-cn-zhangjiakou.aliyuncs.com/sdk/mac/3.9.0/DingRTC_macOS_SDK_3_9_0.zip` | `~/codes/vendor/DingRTC_macOS_SDK_3_9_0/` |

- vendor 二进制 / 头文件 / 文档 SHALL **NOT** 进任何 git 仓库；三端解压路径 SHALL 在 `.gitignore` 覆盖
- 解压路径 SHALL 通过环境变量 override：`ISALES_DINGRTC_LINUX_SDK_PATH` / `ISALES_DINGRTC_WINDOWS_SDK_PATH` / `ISALES_MACOS_DINGRTC_FRAMEWORK_PATH`

#### Scenario: cloud-side install script 自动化下载

- **WHEN** 跑 `deploy/cloud/scripts/install.sh` 或等价部署脚本
- **THEN** SHALL 包含 `install-dingrtc-sdk` 步骤（取代既有 `install-artc-sdk`）：从 DingRTC OSS 拉取 `DingRTC_Linux_SDK_3_9_0.zip` → 校验 sha256（值 SHALL 在 `deploy/cloud/STATE.md` § "DingRTC SDK vendor" 钉死）→ 解压到 `/opt/isales/vendor/DingRTC_Linux_SDK_3_9_0/`
- 装载 pybind11 binding 编译依赖：`apt install build-essential cmake python3-dev` + `pip install pybind11`；编译 `isales-engine/isales_engine/transport/dingrtc/` → 产 `dingrtc_pywrap.so`

#### Scenario: Windows PyInstaller 打包路径

- **WHEN** 跑 `isales-telephony/deploy/edge/windows/build.ps1` PyInstaller 构建
- **THEN** PyInstaller spec SHALL：
  - `binaries` 段显式包含 `DingRTC.dll`（取代 `AliVCSDK_ARTC.dll` / `AliRTCSdk.dll`）
  - `binaries` 段显式包含项目内 pybind11 binding 产物 `dingrtc_pywrap.pyd`（取代 `aliyun_artc_pywrap.pyd`）
  - `hiddenimports` 段包含 `dingrtc_pywrap`（取代 `aliyun_artc_pywrap`）
- vendor 路径文档（`STATE.md`）SHALL 同 PR 更新；MUST NOT 同时保留两套 SDK（构建结果含两套 dll → 互通行为不确定）

#### Scenario: macOS dev/QA 启动指令

- **WHEN** dev 同学在 mac 工作机上启动真 RTC dev/QA 形态
- **THEN** 启动步骤 SHALL 改为：
  1. 解压 `DingRTC_macOS_SDK_3_9_0.zip` 到 `~/codes/vendor/DingRTC_macOS_SDK_3_9_0/`（vendor 不进 git）
  2. `pip install -e '.[dev,macos,macos-artc]'`（extras 名 `macos-artc` 保持向后兼容）
  3. `isales-telephony-edge --cloud-endpoint 121.89.85.150:50051 --edge-token-file <jwt> --dev-no-modem --dev-channel <demo-id> --dev-uid mac-dev-01`
- 启动后 edge 通过 PyObjC 加载 `DingRTC.framework` → `MacosDingRtcPyObjCSession` 真 join DingRTC 3.x 房间 → cloud engine 看到 edge 是真 DingRTC peer

#### Scenario: 三端 SDK 版本一致性 lint

- **WHEN** CI / `make spec-validate` / 任何 PR 提交
- **THEN** SHALL 跨 5 个数据源对账 DingRTC SDK 版本号（`isales-engine` pyproject + `isales-telephony` pyproject + `deploy/cloud/STATE.md` + `isales-telephony/deploy/edge/windows/STATE.md` + `isales-telephony/deploy/edge/macos/RUNBOOK.md`）；版本不一致 SHALL 阻断 PR 合并
- 任何升 DingRTC minor / patch SHALL 三端同 PR；MUST NOT 单端升

#### Scenario: 既有 ApsaraVideo Live ARTC SDK 路径清理

- **WHEN** 本变更落地
- **THEN** `deploy/cloud/STATE.md` § "ARTC SDK vendor" SHALL 重命名为 "DingRTC SDK vendor"；既有 `AliRTCSDK_Linux-7.10.2` vendor 路径 / OSS URL / 解压指令 SHALL 全部替换为 DingRTC 等价值
- `isales-telephony/deploy/edge/windows/STATE.md` 既有 `AliVCSDK_ARTC-7.6.0` 路径 + dll 名 SHALL 同步更新
- `isales-telephony/deploy/edge/macos/RUNBOOK.md` 既有 `AliRTCSdk_macos/AliRTCSdk.framework` 路径 + env var 名 SHALL 同步更新
- `deploy/RUNBOOK-cloud.md` cloud-side SDK 装载步骤 SHALL 同步更新
- ECS 上既有 vendor 路径（`/opt/isales/current/vendor/aliyun-artc-linux-python/` 或类似）SHALL 在新 SDK 上线后人工清理（避免磁盘占用）

#### Scenario: vendor 下载域名识别

- **WHEN** 任何 dev / ops 引用 RTC SDK 下载页
- **THEN** SHALL 通过下载域名识别产品线归属：
  - `dingrtc.oss-cn-zhangjiakou.aliyuncs.com` = **DingRTC 3.x（RTC PaaS）** ← iSales 唯一使用
  - `alivc-demo-cms.alicdn.com/versionProduct/sdk/` = **ApsaraVideo Live（视频直播）下的 ARTC SDK** ← MUST NOT 使用（与 DingRTC 房间不互通）
  - `help-static-aliyun-doc.aliyuncs.com` = **AliRTC 2.x（已淘汰）** ← MUST NOT 使用
- 文档引用 vendor 链接 SHALL 标注产品线归属，避免下次再选错（[[feedback_isolate_with_vendor_sample]]）

