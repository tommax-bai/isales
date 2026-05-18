## ADDED Requirements

### Requirement: macOS 边缘 ARTC SDK 通过 PyObjC binding 接入（dev / QA 形态）

边缘 isales-telephony 进程在 macOS 13+（x86_64 + Apple Silicon）上 SHALL 通过 `isales_telephony/audio_bridge/macos_artc_pyobjc.py`（项目内 PyObjC bridge）接入真 Aliyun ARTC SDK；该实装与既有 "Windows 边缘 ARTC SDK 通过 pybind11 binding 接入"（来自 `windows-artc-pybind11`）pattern 对称，**并列**于既有 Windows backend，不替代 Windows 商用路径。

本 Requirement 服务于 dev 同学在 mac 工作机上做策略层 + 工程层真 RTC 闭环演练（mac edge 与 Windows 商用 edge 等同地 join Aliyun RTC 房间，连真 cloud engine `121.89.85.150`，复用既有 A2 控制面 + 数据面）。**MUST NOT** 进入 v1.0 商用形态（仍是 Windows + 真 GSM modem + 真 ARTC，由 `arch-cloud-edge-split` + `windows-artc-pybind11` 联合交付）；**MUST NOT** 影响 A2 + windows-artc-pybind11 联合验收契约。

PyObjC binding 与既有 `MacosRtcSession` mock loopback（`isales_telephony/audio_bridge/session.py`）并存。Mock loopback 保留作 CI / unit-test 同进程 fixture，**不**被本 Requirement 替代。

#### Scenario: PyObjC + `objc.loadBundle` 加载 framework

- **WHEN** 边缘进程在 darwin 平台启动且 `pyobjc-core` 与 `pyobjc-framework-Cocoa` 已安装（通过 `[macos-artc]` optional extras）且 `AliRTCSdk.framework` 解压在约定路径
- **THEN** `MacosArtcPyObjCSession.__init__` SHALL 通过 `objc.loadBundle("AliRTCSdk", bundle_path=<framework path>)` 显式加载 framework
- framework path 默认 SHALL 为 `~/codes/vendor/AliRTCSdk_macos/AliRTCSdk.framework`；env var `ISALES_MACOS_ARTC_FRAMEWORK_PATH` SHALL 允许 override 该默认值
- framework 加载失败（路径不存在 / 不是 framework / 架构不兼容 / Obj-C class lookup 失败）SHALL 在 `__init__` 抛 `RtcError`，错误信息 SHALL 含具体诊断（缺失路径 / 缺失 class / Obj-C runtime error）

#### Scenario: PyObjC NSObject 子类作 `AliRtcEngineDelegate`，audio-only 子集

- **WHEN** binding 模块加载
- **THEN** SHALL 定义 PyObjC NSObject 子类 `_AliRtcAudioDelegate` 实施 audio-only 子集 selector：
  - `onJoinChannelResult:channel:elapsed:` — join 完成
  - `onLeaveChannelResult:` — leave 完成
  - `onError:` — SDK 错误
  - `onSubscribeAudioFrame:` — 入站 PCM 帧（per-uid before-mixing）
  - `onPushAudioFrameBufferFull:` — 出站反压
  - `onConnectionLost` / `onConnectionRecovery` — 连接事件
  - `onRemoteUserOnLineNotify:` / `onRemoteUserOffLineNotify:` — 远端 uid 事件
- **MUST NOT** 实施 video / screenshare / 完整 `AliRtcEngineDelegate` 90+ event interface（v1.0 audio-only）

#### Scenario: Cocoa thread → asyncio 跨线程桥

- **WHEN** PyObjC delegate 回调在 Cocoa main / random SDK thread 触发
- **THEN** delegate 实施 SHALL 通过 `loop.call_soon_threadsafe(handler, *args)` 投递到记录在 `__init__` 的 asyncio event loop；**MUST NOT** 在 Cocoa thread 直接调 asyncio API（`set_result` / `put_nowait` 等）
- delegate 闭包 SHALL 不持有 PyObjC 对象引用（只传值），避免跨线程释放 race
- `audio_frames()` 数据路径 SHALL 用 `asyncio.Queue` + drainer task，drainer 从 ring buffer / queue 拉帧 yield 到调用方

#### Scenario: `MacosArtcPyObjCSession` 实施 `RtcSession` ABC，形状镜像 `WindowsRtcSession`

- **WHEN** `MacosArtcPyObjCSession` 实例被使用
- **THEN** SHALL 实施 `isales_common.audio.rtc.RtcSession` ABC 的 4 个 abstract API：`join(channel, token, uid, *, send_sample_rate=16000, send_channels=1)` / `leave()` / `is_joined` property / `audio_frames()` async iterator / `push_audio(pcm, *, timestamp_ms)`
- `join()` SHALL 等 `onJoinChannelResult:` 回调（通过 `asyncio.Future`），5 秒超时抛 `RtcError`；result code 非 0 抛 `RtcError` 含 code 与 message
- `leave()` SHALL 是 idempotent：二次 leave 不抛
- `push_audio()` 失败 SHALL 翻 `RtcError`；SDK 报 buffer full SHALL 翻 `RtcPushBackpressure`
- 失败模式（`RtcError` / `RtcNotJoined` / `RtcPushBackpressure`）与 `WindowsRtcSession` 一一对齐

#### Scenario: 平台默认路由 darwin → PyObjC binding，fallback to mock

- **WHEN** `audio_bridge/__init__.py::get_default_rtc_session_class()` 在 `sys.platform == "darwin"` 下被调用
- **THEN** SHALL 优先 import `MacosArtcPyObjCSession` 并返回该类
- **WHEN** import 失败（pyobjc / framework 缺失 / SDK 不在路径）
- **THEN** SHALL 打 WARN log（含装包指引："pip install -e '.[macos-artc]' 并解压 SDK 到 ~/codes/vendor/AliRTCSdk_macos/"）并 fallback 返回 `MacosRtcSession` mock loopback；**MUST NOT** 抛硬错（fresh checkout 不应 crash）
- **MUST NOT** 引入 `ISALES_EDGE_RTC_BACKEND` 类 env var 强制覆盖 platform 选择（与本 spec L402 既有约束 "platform 选择 MUST NOT 通过环境变量强制覆盖" 一致）

#### Scenario: dev / QA 形态边界

- **WHEN** v1.0 MVP 验收 / 客户预演 / 任何对外演示
- **THEN** SHALL **NOT** 使用 macOS PyObjC binding 形态；唯一验收路径仍是 Windows 商用形态（Windows frozen exe + 真 ARTC join + 真 GSM modem + 拨真手机 → 听到 AI 开场白）
- mac PyObjC binding 测出的延迟 / barge-in / VAD / 抗噪 SHALL 作为 dev 调参参考；策略机制（barge-in / 垫词 / handoff / goal partial）行为外推有效，绝对延迟数字外推到商用前 SHALL 在 Windows 商用形态再验证一次

#### Scenario: vendor SDK 与依赖隔离

- **WHEN** 商用 Windows PyInstaller 构建 / cloud Linux deploy
- **THEN** `pyobjc-core` / `pyobjc-framework-Cocoa` / `AliRTCSdk.framework` SHALL **NOT** 被打入商用 frozen exe 或 cloud image
- `pyobjc-core` / `pyobjc-framework-Cocoa` SHALL 仅在 `isales-telephony` pyproject `[project.optional-dependencies].macos-artc` 中声明；商用构建装 base + Windows-specific extras，不装 `[macos-artc]`
- vendor `AliRTCSdk.framework` SHALL **NOT** 进任何 git 仓库；按 `reference_artc_sdk.md` 约定放 `~/codes/vendor/AliRTCSdk_macos/`，运行时 `objc.loadBundle(bundle_path=...)` 注入

#### Scenario: 不影响既有 `MacosRtcSession` / `WindowsRtcSession`

- **WHEN** 本 Requirement 实装上线
- **THEN** `isales_telephony/audio_bridge/session.py::MacosRtcSession`（同进程 loopback mock，A2 / CI 测试用）SHALL 不被修改
- `isales_telephony/audio_bridge/windows_rtc_session.py::WindowsRtcSession`（pybind11 真 ARTC，`windows-artc-pybind11` 实装）SHALL 不被修改
- `RtcSession` ABC（`isales-common/isales_common/audio/rtc.py`）SHALL 不被修改
- 既有 device-hardware Requirement "Windows 平台 backend" / "macOS 边缘形态保留"（来自 archive change） SHALL 不被修改

### Requirement: macOS dev-no-modem orchestrator 路径（mac 装不了 GSM modem 驱动的物理约束）

macOS 边缘进程 SHALL 支持 **dev-no-modem 启动模式**：跳过真 GSM modem 拨号链路，由 cloud-side 主动 `Cloud2Edge.dial` 触发后 edge 直接走"已接通" CallSession 走 audio_bridge join + 真 ARTC 房间。本 Requirement 服务于 mac 上无法安装 USB GSM modem 驱动的物理约束，与 PyObjC binding 形成 dev 形态闭环。

#### Scenario: dev-no-modem CLI flag 触发

- **WHEN** `isales-telephony-edge` 启动且 `--dev-no-modem --dev-channel <name> --dev-uid <id> [--dev-peer-uid <id>]` 顶层 flag 传入且 `sys.platform == "darwin"`
- **THEN** `EdgeOrchestrator` SHALL 在 `start()` 跳过 `SerialATClient` 实例化 / USB watcher 起动 / 任何 AT 命令；仍正常起 cloud-edge grpc_client + audio_bridge
- 进程 SHALL 正常注册 cloud-edge grpc 回调；cloud-side 主动 `Cloud2Edge.dial` 时 edge 直接走"已接通"分支（跳过 `cpcmreg_enable` 与 capture / playback pumps），调 `audio_bridge.join` 用 `MacosArtcPyObjCSession` 真 join RTC 房间
- teardown 由 SIGINT / SIGTERM 触发，发 `Edge2Cloud.remote_hangup{hangup_cause="dev_terminate"}` → audio_bridge.leave → 退出进程

#### Scenario: dev-no-modem 不影响生产路径

- **WHEN** `--dev-no-modem` flag **未**传入
- **THEN** orchestrator SHALL 按既有生产路径运行：`SerialATClient` + USB watcher + AT dial / hangup / CPCMREG 全套链路；本 Requirement **MUST NOT** 影响 Windows 商用 PyInstaller frozen exe 行为

#### Scenario: 平台守护

- **WHEN** `--dev-no-modem` flag 传入但 `sys.platform != "darwin"`
- **THEN** 进程 SHALL fail-fast 退出，打印明确错误 "--dev-no-modem 仅 macOS 支持；Windows 商用走真 GSM modem + windows-artc-pybind11 真 ARTC 路径"
