> **2026-05-18 SUPERSEDED — DO NOT IMPLEMENT.**
>
> 取代者：[`macos-artc-pyobjc-binding`](../macos-artc-pyobjc-binding/proposal.md)（active change，
> 已实施 / 已 push origin/main：meta-repo `104c04b`、isales-telephony `407df87`；
> 39/47 tasks 完成，剩 vendor SDK 落地 + 真云 smoke + archive 流）。
>
> 取代原因：本 change 起草时假设 mac 上无法接真 Aliyun ARTC SDK
> （macOS SDK 是 Obj-C only，2026-05-14 决策不做 PyObjC bridge），所以走 dev-only
> mac mic/speaker + 单进程绕开 RTC 的路径。Audit 时发现这条路径有 design hole：
> mac mic → cloud engine 没有走得通的复用商用链路的方案，本质要么自造单进程 all-in-one
> dev runner，要么改 engine 代码。
>
> 重新评估后改走 PyObjC bridge 真接 macOS ARTC SDK：mac 上的 edge 与 Windows 商用 edge
> 等同地 join 真 RTC 房间、连真 cloud engine（121.89.85.150），dev 测出的策略机制
> （barge-in / VAD / 垫词 / handoff）可外推到 Windows 商用，且复用既有 A2 控制面 +
> 数据面，不需要自造 dev runner。
>
> **本 change 不再推进。** proposal / design / specs / tasks 保留作"为何不走
> dev-only mac mic/speaker 路径"的思路记录，git log + 仓库目录里都能查到。
> 任何后续 dev 工作流问题请走 `macos-artc-pyobjc-binding`，**不要**执行本
> change 的 tasks。

## Why

mac 开发机既不能装 USB GSM modem 驱动，也不能装 Windows ARTC SDK（C++ only，集成走 `windows-artc-pybind11` active change，需 Windows dev rig），但 engine 的策略机制（state machine / 3-layer AI pipeline / barge-in / 垫词 / handoff / goal partial）和工程链路（cloud-edge gRPC bidi / durable buffer / token mint）需要日常在 mac 上做真音频闭环演练，而不只是当前 `MacosRtcSession` 这种**同进程内存 loopback mock**。本 change 在 macOS 上新增一条 **dev-only** 音频路径——用 mac 系统麦克风 / 扬声器当 RTC 对端，并跳过真 modem 拨号链路——让策略层在真声学环境下的行为（VAD 阈值 / 真 ASR 抗噪 / 真 TTS 出声延迟 / barge-in 检测）可以在 mac 上演练。

商用形态不变：Windows + 真 GSM modem + 真 ARTC，由 `arch-cloud-edge-split` + `windows-artc-pybind11` 联合验收交付；mac 真 ARTC SDK 集成的 PyObjC bridge 决策（不做）也不变。

## What Changes

- **新增 `MacosLocalAudioRtcSession`**（`isales-telephony/isales_telephony/audio_bridge/macos_local_audio_session.py`）：实现 `isales_common.audio.rtc.RtcSession` ABC，用 `sounddevice` 开 mac 默认 input device 采 16k mono int16 PCM 喂 `audio_frames()`；`push_audio()` 把 engine 的 TTS PCM 推到 mac 默认 output device。`join(channel, token, uid)` 只作日志 / dev 标识，**不**验证 token、**不**接真 RTC 信道。
- **新增 dev-no-modem CLI mode**：`isales-telephony-edge` 入口增加顶层 flag `--dev-no-modem --dev-channel <name> --dev-uid <id> [--dev-peer-uid <id>]`。`EdgeOrchestrator` 检测到 dev mode：不起 `SerialATClient` / 不监听 USB watcher / 不发 AT 命令，直接构造一个"已接通"`CallSession` 注入 cloud-edge gRPC client（cloud-side engine 看到的是正常 connected session，state machine 不变）；teardown 由 SIGINT / SIGTERM 触发 → 给 engine 发 remote_hangup。生产路径（默认不带 flag）零侵入。
- **修改 `audio_bridge/__init__.py::get_default_rtc_session_class()`**：保留按 `sys.platform` 自动选择的默认逻辑（macOS → `MacosRtcSession` loopback / Windows → `WindowsRtcSession` 真 ARTC），新增 dev-only override：当 `EdgeOrchestrator` 启动时 `dev_no_modem=True` 且 `sys.platform == "darwin"`，session 工厂返回 `MacosLocalAudioRtcSession`。**MUST NOT** 引入 `ISALES_TELEPHONY_AUDIO_BACKEND` 环境变量（与 device-hardware spec L402 "platform 选择 MUST NOT 通过环境变量强制覆盖" 一致）。
- **新增 dev-only 依赖**：`isales-telephony` pyproject 增加 optional extras `[dev-mac-audio]`，含 `sounddevice >= 0.4.6`（依赖 PortAudio）；商用 PyInstaller spec **不**含此 extras，frozen exe 二进制无 PortAudio 依赖。
- **新增 dev 演练 recipe**：`isales-telephony/deploy/edge/macos/dev-recipes.md`（不在 cloud RUNBOOK 中），一行起 engine + edge dev 模式的命令、env 配置、强制戴耳机说明、barge-in 演练步骤。
- **device-hardware spec delta**：在 Windows 平台 backend Requirement 后并列新增 "macOS dev-only local-audio backend" Requirement，明确：仅在 `--dev-no-modem` 模式启用；mic / speaker 走 PortAudio；**不**做 AEC（要求戴耳机）；商用路径 MUST NOT 走此 backend。
- **deployment-topology spec delta**：在 "macOS 边缘形态保留" Scenario 后新增 "macOS dev-no-modem 形态" Scenario，明确这是与 Windows 商用 / macOS QA 并列的**第三种** macOS 部署形态，**dev-only**，不进商用 PyInstaller / Windows / cloud。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `device-hardware`：新增 macOS dev-only local-audio backend Requirement（与既有 Windows backend / macOS PoC backend 并列）；不修改现有 Requirement，纯追加。
- `deployment-topology`：在 v1.0 边缘机 platform 形态 Requirement 下新增 macOS dev-no-modem 形态 Scenario；不修改现有 Scenario，纯追加。

## Impact

**受影响代码**：
- `isales-telephony/isales_telephony/audio_bridge/` 新增 `macos_local_audio_session.py`（不动 `session.py` / `bridge.py`）
- `isales-telephony/isales_telephony/audio_bridge/__init__.py` 改 `get_default_rtc_session_class()`（追加 dev-only 分支）
- `isales-telephony/isales_telephony/edge/main.py` 加 argparse flag `--dev-no-modem` / `--dev-channel` / `--dev-uid` / `--dev-peer-uid`
- `isales-telephony/isales_telephony/edge/orchestrator.py` 新增 dev-mode 分支（不起 modem、注入 already-connected CallSession）
- `isales-telephony/pyproject.toml` 新增 optional extras `[dev-mac-audio]`
- `isales-telephony/deploy/edge/macos/dev-recipes.md` 新建

**不受影响**：
- isales-common（RtcSession ABC 不变）/ isales-engine（cloud-side 看到的是正常 connected session）/ isales-api / isales-scheduler / isales-worker / isales-web
- `MacosRtcSession`（CI / unit-test 同进程 loopback fixture 保留）
- Windows 商用路径（`WindowsRtcSession` / `windows-artc-pybind11` / Windows backend / PyInstaller spec / build.ps1）
- 云端 deploy（无 cloud-side 改动；engine 不感知 edge 是真 modem 还是 dev mode）

**APIs / 协议**：cloud-edge gRPC 协议、`RtcSession` ABC、`CallSession` schema 均不变。

**依赖**：仅 `sounddevice >= 0.4.6`（PortAudio），仅 mac dev extras 装，frozen exe 与 cloud image 不含。

**联合验收点不变**：A2 + windows-artc-pybind11 联合验收（Windows frozen exe + 真 ARTC join + 真 GSM modem + 拨真手机 → AI 开场白）仍是 v1.0 MVP 验收的唯一标准，本 change 的 mac dev 闭环**不**作为验收点。
