> **2026-05-18 SUPERSEDED — DO NOT IMPLEMENT.** 取代者
> [`macos-artc-pyobjc-binding`](../macos-artc-pyobjc-binding/) 已 active +
> 实施落地。本 design 保留作思路记录；详见
> [`proposal.md`](./proposal.md) 顶部 SUPERSEDED 块。

## Context

iSales v1.0 商用形态 = Windows + 真 GSM modem + 真 Aliyun ARTC，由 `arch-cloud-edge-split` (A2, 52/64) + `windows-artc-pybind11` (39/51) 联合交付。开发同学的日常工作机是 macOS，存在两条硬件 blocker：

1. **USB GSM modem 驱动**不能在 mac 上装（SIM7600G-H Windows 专属 driver / 串口需要 Windows IRP 栈）。
2. **Windows ARTC SDK**是 C++ only，集成走 pybind11 `.pyd`（CPython 3.12 ABI / VS Build Tools / Windows-only），不能在 mac 跑。

现有 macOS 上的 audio 路径只有 `MacosRtcSession`（`isales-telephony/isales_telephony/audio_bridge/session.py`）——**同进程内存 loopback mock**：两个 macOS 进程通过类级 `_channel_registry` 互发 PCM。它验证 wire-format 和 `RtcSession` ABC 契约够用，但无法让 engine 的策略机制在**真声学环境**下演练：barge-in 在真 mic / 真 speaker 上的检测、VAD 阈值、真 ASR 抗噪、真 TTS 出声延迟。

同时 mac 真 ARTC SDK 集成已经在 `reference_artc_sdk.md` 决策**不做**——SDK 是纯 Obj-C Cocoa framework，PyObjC bridge 成本高 / ROI 低。所以 mac 上永远不会有真 RTC 信道。

dev 同学需要在 mac 上做策略迭代的真闭环演练，比 mock loopback 高一档（"我对着 mac 说话 → engine 走完 ASR/LLM/TTS → mac 扬声器播 AI 回应"）。

约束：
- 不能替换 `MacosRtcSession` mock（CI / unit-test 在用）
- 不能引入与 `device-hardware` spec L402 冲突的 platform 选择 env var
- 不能侵入 Windows 商用 PyInstaller spec / build.ps1 / cloud deploy
- 不能影响 A2 + windows-artc-pybind11 联合验收的契约

## Goals / Non-Goals

**Goals:**
- 在 macOS 上加一条**真音频** `RtcSession` 实装，开 mac 默认 mic / speaker；engine 端策略层（state machine / 3-layer AI pipeline / barge-in / 垫词 / handoff）端到端走真音频
- 跳过真 modem 拨号：edge orchestrator 在 dev mode 下注入"已接通" CallSession，cloud-side engine 透明（看到的是正常 connected session）
- 生产路径零侵入：默认 flag 不传，原 modem 路径 + `MacosRtcSession` mock 完整保留
- dev-only 边界硬性可见：CLI flag 显式触发 / sounddevice 仅在 optional extras / frozen exe 不含

**Non-Goals:**
- **不**替换 `MacosRtcSession` mock；它仍是 CI / unit-test 同进程 fixture
- **不**做 echo cancellation / AEC（dev 戴耳机解决）
- **不**做真 modem 模拟 / SIM 卡模拟 / 完整 hangup_cause 集（dev mode 只 SIGINT teardown → `remote_hangup`）
- **不**支持多并发 call（dev mode 一次一个 session）
- **不**替代 v1.0 MVP 验收（仍是 Windows + 真 ARTC + 真 GSM modem）
- **不**做 mac 真 ARTC SDK 集成（PyObjC bridge 决策不变）
- **不**走 cloud / Windows / PyInstaller / RUNBOOK 任何商用路径
- **不**与 `arch-cloud-edge-split` / `windows-artc-pybind11` 任何 task 互锁

## Decisions

### Decision 1: dev mode 触发 = CLI flag，不引入 env var

**选**：`isales-telephony-edge --dev-no-modem --dev-channel <name> --dev-uid <id> [--dev-peer-uid <id>] [--dev-input-device <name|idx>] [--dev-output-device <name|idx>]`。dev mode 是一个二元 process-level 开关，进程启动就定，运行期不切换。

**否决** `ISALES_TELEPHONY_AUDIO_BACKEND` 环境变量。

**Why**：
- `device-hardware` spec L402 已确立约束 "platform 选择 SHALL 根据 `sys.platform` 自动决定，MUST NOT 通过环境变量强制覆盖"。env var 触发 dev mode 与这条精神冲突（虽然原文指 modem-controller 而非 audio-bridge）。
- CLI flag 在 `ps -ef` / 日志 / 错误堆栈里都直接可见，dev 与生产边界一眼明，比 env var 隐蔽切换安全。
- dev mode 同时还要带 channel / uid 等参数，CLI argparse 比 4-5 个 env var 更自然。

### Decision 2: audio I/O 库 = sounddevice

**选**：`sounddevice >= 0.4.6`（PortAudio binding）。

**否决**：PyAudio（PortAudio 旧 binding，CFFI 不在主线，pip wheel 在 Apple Silicon 上历史 broken）；`pyobjc-framework-AVFoundation`（重，仅为 audio I/O 引入 PyObjC 不值）。

**Why**：
- sounddevice 是 PortAudio 现代 CFFI binding，pip wheel 同时支持 x86_64 / arm64 mac，brew install portaudio 一行依赖
- API 简洁：`sd.InputStream` / `sd.OutputStream` 直接给 callback 喂 int16 mono numpy 数组，与 `PcmFrame` 形状直接对接，不需要 ctypes / 复杂 buffer 协议
- `sd.query_devices()` 可枚举系统设备，`--dev-input-device` flag 可按 name substring 或 index 选

### Decision 3: dev-mode CallSession 注入点 = EdgeOrchestrator，不动 engine

**选**：`EdgeOrchestrator.__init__` 接 `dev_no_modem: bool` + dev params；dev mode 下 `start()` 跳过 `SerialATClient` / USB watcher，构造 `CallSession(channel=dev_channel, uid=dev_uid, state="connected", ...)`，按已有 grpc client `cloud2edge.dial → DialAck → on connected: AudioBridge.join` 路径触发（cloud 也可主动 `Cloud2Edge.dial`，edge 直接 ack 并起 AudioBridge）。

**否决**：在 cloud-side engine 加 dev mode 分支（违反"生产路径零侵入"）；写新 console script `isales-telephony-edge-dev`（多入口维护成本）。

**Why**：
- cloud-side engine 只看到 `CallSession` schema + cloud-edge gRPC 协议，源头是真 modem 还是 dev mock 它不感知；这正是 A2 拆分的好处。
- `EdgeOrchestrator` 已经是 modem 与 audio-bridge 的胶水层（archive 2026-05-17-windows-client-core / A2 §13c），dev mode 分支落在这里最自然。
- 单入口 + 单 flag 比多 console script 维护成本低。

### Decision 4: session 工厂选择 = sys.platform + dev_no_modem 复合判定

**选**：`get_default_rtc_session_class(dev_no_modem: bool = False)` 加入 dev_no_modem 参数；当 `dev_no_modem=True` and `sys.platform == "darwin"` → `MacosLocalAudioRtcSession`；其他组合走原 sys.platform 默认（darwin → mock loopback / win32 → WindowsRtcSession / else → NotImplementedError）。

**Why**：保留既有 platform-default 行为；dev override 是显式参数传入，不是全局状态切换，CI / unit-test 不传 flag 行为完全不变。

### Decision 5: PCM 格式 = 16 kHz mono int16（与 RtcSession ABC 一致），不引入重采样

**选**：sounddevice 直接以 16k mono int16 开 input/output stream（PortAudio 内部会与系统 default device 的实际采样率做转换）。`PcmFrame` 直接喂 engine，不经 `audio_bridge/resampler.py`（resampler 是给 modem 8k ↔ RTC 16k 用的，dev 路径没 modem）。

**Why**：
- `MacosLocalAudioRtcSession` 是 RTC-side 实装，直连 16k 域；不存在 modem 8k 需要桥接。
- 让 PortAudio 接管系统-device 采样率转换（AudioUnit / CoreAudio 原生），比 Python 侧 scipy.signal.resample_poly 质量好、延迟低。

### Decision 6: 回声处理 = 强制戴耳机 + 启动 warning，不实装 AEC

**选**：`MacosLocalAudioRtcSession.join()` 启动时打 WARN log "本会话使用 mac 系统 mic+speaker；不戴耳机将导致 TTS 回灌、barge-in 误触和 ASR 失真；按 Ctrl+C 退出后改用耳机重启"；`deploy/edge/macos/dev-recipes.md` 第一段强调。

**否决**：集成 WebRTC AEC（`pywebrtc-audio-processing` / `speexdsp` 等），实装成本 1-2 天 + 跨平台编译；dev 用途下 ROI 极低。

**Why**：dev 场景下戴耳机是 0 成本约束；引入 AEC 反而拖慢演练迭代。

### Decision 7: sounddevice = optional extras `dev-mac-audio`，不进主依赖

**选**：`isales-telephony/pyproject.toml` `[project.optional-dependencies]` 加 `dev-mac-audio = ["sounddevice>=0.4.6", "numpy>=1.26"]`；CI / 生产装 base + dev / mac-edge 商用装 base。

**否决**：放进 main `dependencies` —— Windows frozen exe 会把 sounddevice + PortAudio dll 打进去，污染 8 MB 包大小且引入无用代码路径。

**Why**：dev-only 依赖隔离是惯例；`MacosLocalAudioRtcSession` 用 `from sounddevice import ...` lazy import，ImportError 时给清晰提示 "pip install -e '.[dev-mac-audio]' first"。

### Decision 8: dev mode 单 session，无并发

**选**：`EdgeOrchestrator` dev 路径开机即起一个 CallSession，挂断后进程退出（不重启 / 不接第二通）。

**Why**：dev 演练核心是单通对话调策略；多并发是生产路径关心的事，已经在 modem + RTC 真路径下覆盖。多并发 dev 需求出现再单独提 change。

## Risks / Trade-offs

- **[风险] 不戴耳机 → mic 收到 TTS → barge-in 在 engine 端被误触 / VAD 持续 active / TTS 回灌 loop 把 ASR 喂自己** → Mitigation: `join()` WARN log + dev-recipes.md 第一段强调 + barge-in 演练 section 给出"对照测试"步骤（先静音 speaker 跑一次，再戴耳机跑一次对比）。
- **[风险] sounddevice 在 mac 上首次装需要 `brew install portaudio` 否则 pip install 失败** → Mitigation: dev-recipes.md "前置依赖" 第一条；`MacosLocalAudioRtcSession` ImportError 时给指引性错误。
- **[风险] mac 系统默认 input/output device 不是用户想要的（接了多个 audio interface / 蓝牙耳机优先级）** → Mitigation: CLI `--dev-input-device` / `--dev-output-device` 支持 name substring 或 index；`isales-telephony-edge --list-audio-devices` subcommand 打印 `sd.query_devices()` 全表。
- **[风险] dev path 滑入生产路径** → Mitigation 三层：(a) CLI flag `--dev-no-modem` 显式必传；(b) sounddevice 在 frozen exe / Linux 不装；(c) `MacosLocalAudioRtcSession` import 在 win32 / linux 下 ImportError 即 fail-fast。
- **[风险] CoreAudio 端到端延迟（capture → engine → tts → playback）波动大，影响 barge-in 调参的可信度** → Mitigation: 接受这个 trade-off（dev 用途）；recipe 文档说明这条延迟与真 RTC + Windows + 真 modem 链路有差异，不能直接转结论。
- **[Trade-off] 不做 AEC** → dev 阶段戴耳机；如未来发现 AEC 是策略层调试 blocker（极少见），单独提 change。
- **[Trade-off] dev mode 单 session** → 多并发需求出现再扩。

## Migration Plan

无 migration。纯追加：
- 新代码：`macos_local_audio_session.py` / `EdgeOrchestrator` dev 分支 / argparse 新 flag / `pyproject.toml` extras / `dev-recipes.md`
- 现有 `MacosRtcSession` mock、`WindowsRtcSession`、Windows backend、cloud-side engine、所有 spec 既有 Requirement / Scenario 全部不动

回滚策略：dev mode 仅由 CLI flag 触发，不传即原行为；如发现问题，撤回 commit 即可，不存在数据 / 部署 / 协议层 fallout。

## Open Questions

无。
