## MODIFIED Requirements

### Requirement: Windows 客户端依赖与打包

Windows 客户端 SHALL 通过 PyInstaller 打包为可移植目录（onedir），含 Python 运行时 + 所有 PyPI 依赖 + DingRTC SDK Windows native binary；最终产物 SHALL 在干净的 Windows 10 21H2+ / Windows 11 PC 上解压即可运行（无需用户单独装 Python 或 VC 运行时）。

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
  - 阿里 DingRTC 3.x SDK for Windows native binary（vendor）+ 项目内 pybind11 binding（`dingrtc_pywrap.pyd`，由 build.ps1 CMake 阶段产出，详见 `openspec/changes/archive/2026-06-27-engine-rtc-dingrtc-migration/`）
- macOS / Linux 平台 MUST NOT 强制安装上述 Windows-specific 包（通过 pyproject `extras` 或 platform marker 隔离）

#### Scenario: PyInstaller 打包配置

- **WHEN** 执行 `deploy/edge/windows/build.sh` 或等价构建脚本
- **THEN** PyInstaller SHALL：
  - 模式：`onedir`（不用 `onefile`，避免每次启动解压 200-500 ms 延迟 + AV 误报）
  - 入口：`isales_telephony/main_windows.py`
  - 显式包含 DingRTC SDK Windows native `.dll` 文件（`binaries` 节）
  - 显式包含 tray icon `.ico` 资源（`datas` 节）
  - 隐藏导入：`dingrtc_pywrap`（项目内 pybind11 模块名，详见 `openspec/changes/archive/2026-06-27-engine-rtc-dingrtc-migration/`）、`PySide6.QtCore` 等运行时 import 模块
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

- **macOS 商用形态**：**不存在** — 商用唯一形态是 Windows + 真 GSM modem + 真 Aliyun RTC（由 `arch-cloud-edge-split` + `engine-rtc-dingrtc-migration` 联合交付）
- **macOS QA / PoC 形态（既有，`impl-deploy-macos`）**：launchd plist 部署 + `MacosRtcSession` 同进程 loopback mock + 真 GSM modem（如有）；保留作 CI / unit-test / 早期 PoC 演练
- **macOS dev/QA 真 Aliyun RTC 形态（本 Requirement 新增）**：PyObjC binding + 真 Aliyun RTC + 真 cloud engine + dev-no-modem（mac 装不了 GSM modem 驱动）

本形态 **MUST NOT** 作为 v1.0 MVP 验收路径，**MUST NOT** 进入商用 PyInstaller / Windows build / cloud deploy / RUNBOOK-cloud，**MUST NOT** 被任何客户机环境使用。

#### Scenario: dev/QA 真 Aliyun RTC 形态启动路径

- **WHEN** dev 同学需要在 mac 工作机上做真 RTC 策略 / 工程闭环演练
- **THEN** 启动方式 SHALL 是：
  1. 解压 `DingRTC_macOS_SDK_3_9_0` 到 `~/codes/vendor/DingRTC_macOS_SDK_3_9_0/`（vendor 不进 git）
  2. `pip install -e '.[dev,macos,macos-artc]'`（`macos` extras = sounddevice for modem-controller，`macos-artc` extras = pyobjc-core + pyobjc-framework-Cocoa for audio_bridge）
  3. `isales-telephony-edge --cloud-endpoint 121.89.85.150:50051 --edge-token-file <jwt> --dev-no-modem --dev-channel <demo-id> --dev-uid mac-dev-01`
- 启动后 edge 通过 PyObjC 加载 `DingRTC.framework` → `MacosDingRtcPyObjCSession` 真 join Aliyun RTC 房间 → cloud engine 看到 edge 是真 RTC peer → 拨真手机时 mac 上听到 AI 开场白

#### Scenario: 与 Windows 商用契约的边界

- **WHEN** v1.0 MVP 验收 / 客户预演 / 任何对外演示
- **THEN** SHALL **NOT** 使用 macOS dev/QA 形态；唯一验收路径仍是 Windows 商用形态（Windows frozen exe + 真 Aliyun RTC + 真 GSM modem + 拨真手机 → 听到 AI 开场白）
- macOS dev/QA 形态测出的**绝对延迟数字**（mic → engine → speaker latency P95）SHALL **NOT** 直接外推到 Windows 商用——mac 上没有 modem 8 kHz ↔ RTC 16 kHz 重采样 + USB 串口 PCM 段，audio I/O 由 DingRTC SDK 接 mac default device 而非 modem PCM 串口
- 策略机制行为（barge-in 触发逻辑 / VAD 阈值 / 垫词 / handoff / goal partial）SHALL **可以**外推到 Windows 商用，因为策略层在 cloud engine 上跑，不依赖 edge 平台

#### Scenario: 商用打包与构建路径完全隔离

- **WHEN** 跑 Windows 商用 PyInstaller 构建（`deploy/edge/windows/build.ps1`）/ cloud Linux image 构建
- **THEN** PyInstaller spec / cloud image **MUST NOT** 收 `pyobjc-core` / `pyobjc-framework-Cocoa` / `macos_dingrtc_pyobjc.py` / `DingRTC.framework` / `--dev-no-modem` 相关 CLI 代码路径
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
