## ADDED Requirements

### Requirement: macOS dev/QA 形态走真 ARTC + 真 cloud engine（dev-only，与 Windows 商用并列）

iSales 边缘进程在 macOS 上 SHALL 提供 **dev/QA 形态**：通过项目内 PyObjC binding 接入真 Aliyun ARTC SDK，与既有 cloud engine（`121.89.85.150` 上 Linux Python wrapper SDK）通过真 ARTC PaaS 互通；与 Windows 商用形态走真 ARTC + 真 GSM modem 并列，**但不**作为 v1.0 MVP 验收路径。

本形态服务于开发同学在 mac 工作机上做策略层 + 工程层的真 RTC 闭环演练，与 Windows 商用 edge **等同地** join 真 RTC 房间，复用既有 A2 控制面（cloud-edge gRPC bidi）+ 数据面（真 ARTC），dev 测出的策略机制行为（barge-in / VAD / 垫词 / handoff / goal partial）可外推到 Windows 商用。

形态对比（macOS 上当前有三种）：

- **macOS 商用形态**：**不存在** — 商用唯一形态是 Windows + 真 GSM modem + 真 ARTC（由 `arch-cloud-edge-split` + `windows-artc-pybind11` 联合交付）
- **macOS QA / PoC 形态（既有，`impl-deploy-macos`）**：launchd plist 部署 + `MacosRtcSession` 同进程 loopback mock + 真 GSM modem（如有）；保留作 CI / unit-test / 早期 PoC 演练
- **macOS dev/QA 真 ARTC 形态（本 Requirement 新增）**：PyObjC binding + 真 Aliyun ARTC + 真 cloud engine + dev-no-modem（mac 装不了 GSM modem 驱动）

本形态 **MUST NOT** 作为 v1.0 MVP 验收路径，**MUST NOT** 进入商用 PyInstaller / Windows build / cloud deploy / RUNBOOK-cloud，**MUST NOT** 被任何客户机环境使用。

#### Scenario: dev/QA 真 ARTC 形态启动路径

- **WHEN** dev 同学需要在 mac 工作机上做真 RTC 策略 / 工程闭环演练
- **THEN** 启动方式 SHALL 是：
  1. 解压 `AliRTCSdk_7.8.10000-SNAPSHOT.zip` 到 `~/codes/vendor/AliRTCSdk_macos/`（vendor 不进 git）
  2. `pip install -e '.[dev,macos,macos-artc]'`（`macos` extras = sounddevice for modem-controller，`macos-artc` extras = pyobjc-core + pyobjc-framework-Cocoa for audio_bridge）
  3. `isales-telephony-edge --cloud-endpoint 121.89.85.150:50051 --edge-token-file <jwt> --dev-no-modem --dev-channel <demo-id> --dev-uid mac-dev-01`
- 启动后 edge 通过 PyObjC 加载 `AliRTCSdk.framework` → `MacosArtcPyObjCSession` 真 join Aliyun RTC 房间 → cloud engine 看到 edge 是真 RTC peer → 拨真手机时 mac 上听到 AI 开场白

#### Scenario: 与 Windows 商用契约的边界

- **WHEN** v1.0 MVP 验收 / 客户预演 / 任何对外演示
- **THEN** SHALL **NOT** 使用 macOS dev/QA 形态；唯一验收路径仍是 Windows 商用形态（Windows frozen exe + 真 ARTC + 真 GSM modem + 拨真手机 → 听到 AI 开场白）
- macOS dev/QA 形态测出的**绝对延迟数字**（mic → engine → speaker latency P95）SHALL **NOT** 直接外推到 Windows 商用——mac 上没有 modem 8 kHz ↔ RTC 16 kHz 重采样 + USB 串口 PCM 段，audio I/O 由 ARTC SDK 接 mac default device 而非 modem PCM 串口
- 策略机制行为（barge-in 触发逻辑 / VAD 阈值 / 垫词 / handoff / goal partial）SHALL **可以**外推到 Windows 商用，因为策略层在 cloud engine 上跑，不依赖 edge 平台

#### Scenario: 商用打包与构建路径完全隔离

- **WHEN** 跑 Windows 商用 PyInstaller 构建（`deploy/edge/windows/build.ps1`）/ cloud Linux image 构建
- **THEN** PyInstaller spec / cloud image **MUST NOT** 收 `pyobjc-core` / `pyobjc-framework-Cocoa` / `macos_artc_pyobjc.py` / `AliRTCSdk.framework` / `--dev-no-modem` 相关 CLI 代码路径
- `pyobjc-core` / `pyobjc-framework-Cocoa` SHALL 仅在 `isales-telephony` pyproject `[project.optional-dependencies].macos-artc` 中声明；商用构建装 base + Windows-specific extras，不装 `[macos-artc]`
- macOS PyInstaller frozen exe 商用打包 SHALL **不**在本 Requirement 范围（PyObjC + framework 打包路径复杂；dev 直接 `.venv` 跑）

#### Scenario: RUNBOOK 文档位置与边界

- **WHEN** dev 同学查找如何启用 macOS dev/QA 真 ARTC 形态
- **THEN** 文档 SHALL 位于 `isales-telephony/deploy/edge/macos/RUNBOOK.md`（**不**在 `deploy/RUNBOOK-cloud.md` / `deploy/edge/windows/STATE.md` 中）
- 文档 SHALL 包含：vendor SDK 下载与解压 / framework search path 配置 / 一行启动命令 / dev 演练 step-by-step（拨真手机 / barge-in 实测 / log 查看 / latency 测量）/ 与 Windows 商用契约的边界声明 / 已知 macOS SDK 行为差异（SNAPSHOT 版本）

#### Scenario: mac 装不了 GSM modem 驱动的物理约束接入

- **WHEN** mac 上不存在 GSM modem 驱动 / 物理无法插 USB GSM modem
- **THEN** dev/QA 形态 SHALL 通过 `--dev-no-modem` CLI flag（device-hardware spec § "macOS dev-no-modem orchestrator 路径" 定义）跳过真 modem 链路；cloud 主动 `Cloud2Edge.dial` 时 edge 直接走"已接通" CallSession + audio_bridge.join 真 ARTC
- 即使有人在 mac 上配出 GSM modem 路径（极少见的硬件场景），dev/QA 形态 SHALL 仍优先使用 `--dev-no-modem` flag，**不**鼓励 mac 上真接 GSM modem（不是商用形态）

#### Scenario: 既有 macOS QA / PoC 形态保留

- **WHEN** 本 Requirement 实装上线
- **THEN** 既有 macOS QA / PoC 形态（`impl-deploy-macos` launchd plist + `MacosRtcSession` mock loopback）SHALL 不被移除，作为 CI / unit-test / 早期 PoC 演练路径继续支持
- 当 PyObjC binding 模块不可用（没装 extras / 没解压 SDK）SHALL fallback 到既有 mock loopback 形态（device-hardware spec § "平台默认路由 darwin → PyObjC binding，fallback to mock" 定义）
