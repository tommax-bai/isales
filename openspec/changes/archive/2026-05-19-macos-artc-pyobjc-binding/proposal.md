## Why

A2 `arch-cloud-edge-split` 落地后，mac 作为开发同学的**日常工作机长期使用**——不是当初 (2026-05-14) `reference_artc_sdk.md` 假设的"用一次就退役的 QA Mac mini 形态"。在 mac 上做策略层（state machine / 3-layer AI pipeline / barge-in / 垫词 / handoff / goal partial）和工程层（cloud-edge gRPC bidi / durable buffer / token mint）的闭环演练需要**真 audio + 真 RTC + 真 cloud engine**，否则 dev 测出的延迟 / barge-in / VAD / 抗噪行为外推不到 Windows + 真 ARTC + 真 GSM modem 的 v1.0 MVP 验收路径。

刚撤掉的 `macos-local-audio-dev` 走 "mac mic/speaker 当 dev RTC 对端" 的绕开方案，audit 时发现 mac mic → cloud engine 没法复用商用控制面 + 数据面（自造 in-memory 桥或改 engine 代码两条路都不优）。重新评估后改走 **PyObjC bridge 真接 macOS ARTC SDK**：mac 上的 edge 与 Windows 商用 edge 等同地 join 真 RTC 房间，连真 cloud engine（121.89.85.150 已部署），完全复用既有 A2 链路。

技术约束（`reference_artc_sdk.md` macOS 段已记）：macOS ARTC SDK = `AliRTCSdk.framework`（Mach-O universal binary，17 MB），19 个 Headers **全是 Obj-C interface**，`engine_c_interface.h` 只有 4 个 `ALI_RTC_API` 全是 video/screenshare（audio API 全在 Obj-C interface），Aliyun **不**提供 Python wrapper。Python 调用唯一路径是 **PyObjC bridge**：`objc.loadBundle()` 加载 framework + PyObjC `NSObject` 子类作 `AliRtcEngineDelegate` + Cocoa thread ↔ asyncio 跨线程桥。

2026-05-14 原决策不做 PyObjC bridge 的理由"mac edge 用一次（QA），D1 Windows 落地后退役，ROI 低"——前提是**短期一次性**。今天前提反转：mac 是**长期 dev 机**，数百行 PyObjC 投入换持续真 RTC 测试能力，ROI 划算。

本 change 与 `windows-artc-pybind11` 形成对称：Windows 走项目内 pybind11 C++ binding，macOS 走项目内 PyObjC Obj-C bridge，pattern 一致——都是"项目内绑定层接住 Aliyun 平台特定 SDK 形态差异"。商用形态不变（仍是 Windows + 真 GSM modem + 真 ARTC，由 A2 + windows-artc-pybind11 联合交付）；macOS PyObjC 仅服务 **dev / QA**，不进入 v1.0 MVP 验收路径。

## What Changes

- **新增 PyObjC bridge 模块** `isales-telephony/isales_telephony/audio_bridge/macos_artc_pyobjc.py`：
  - `objc.loadBundle("AliRTCSdk", bundle_path=<framework path>)` 加载 framework
  - PyObjC 子类化 `NSObject` 作 `AliRtcEngineDelegate`（响应 audio-only 子集回调：`onJoinChannelResult:` / `onLeaveChannelResult:` / `onError:` / `onSubscribeAudioFrame:` / `onPushAudioFrameBufferFull:` / `onConnectionLost`）
  - 封装 audio-only 子集核心 API：`createEngine` / `setExternalAudioSource:` / `joinChannel:` / `leaveChannel` / `pushExternalAudioFrame:` / `release`
  - Delegate 回调在 Cocoa main / random SDK thread 触发 → `loop.call_soon_threadsafe` 桥到 asyncio
- **新增 `MacosArtcPyObjCSession`** 实现 `isales_common.audio.rtc.RtcSession` ABC：
  - 与 `WindowsRtcSession`（pybind11 真 ARTC，Windows 商用）/ `MacosRtcSession`（mock loopback，CI 用）并列
  - shape 一致：`join(channel, token, uid, *, send_sample_rate=16000, send_channels=1)` / `leave()` / `is_joined` property / `audio_frames()` async iterator / `push_audio(pcm, *, timestamp_ms)`
  - `audio_frames()` 用 asyncio Queue + drainer task 桥接 Cocoa thread 入帧 → asyncio yield
  - `push_audio()` 调 `pushExternalAudioFrame:` 推 PCM 到 RTC 信道
  - 失败模式与 `WindowsRtcSession` 对齐：`RtcError` / `RtcNotJoined` / `RtcPushBackpressure`
- **修改 `audio_bridge/__init__.py::get_default_rtc_session_class()`**：
  - darwin 平台默认从 `MacosRtcSession`（mock loopback）改为 `MacosArtcPyObjCSession`（真 ARTC）
  - `MacosRtcSession` 仍 export，CI / unit-test / 跨进程 mock loopback 场景可显式 import 使用
  - 当 `pyobjc` 或 framework 不在路径时，fallback 到 `MacosRtcSession` mock 并打 WARN log（dev 在 fresh checkout 没装 extras 时不会硬 crash）
- **新增 PyObjC + framework 加载依赖**：
  - `isales-telephony/pyproject.toml` 已有 `macos` extras 当前仅含 `sounddevice>=0.4.6`；本 change **新增 optional extras `[macos-artc]`** 含 `pyobjc-core>=10.0` + `pyobjc-framework-Cocoa>=10.0`（不动既有 `macos` extras，让 modem-controller macos_coreaudio backend 与本 binding 依赖分开）
  - vendor SDK `AliRTCSdk.framework` 17 MB 按 `reference_artc_sdk.md` 约定放 `~/codes/vendor/AliRTCSdk_macos/`，**不**进 git
  - 运行时 framework search path 通过 `objc.loadBundle()` 显式 `bundle_path` 参数注入（env var `ISALES_MACOS_ARTC_FRAMEWORK_PATH` 可 override 默认路径）
- **新增 dev/QA RUNBOOK** `isales-telephony/deploy/edge/macos/RUNBOOK.md`（若已存在则扩展）：
  - SDK 下载 + 解压路径 + framework search path 配置
  - 一行启动 mac edge 连真 cloud engine（121.89.85.150 + RTC AppId `o6dpsan9`）
  - dev 演练 step-by-step：拨真手机 → 接通 → 听 AI 开场白 → barge-in 实测 → 看 engine log
  - macOS dev 形态边界声明（dev-only，不作 v1.0 MVP 验收路径，商用仍 Windows）
- **dev-no-modem 接入**（最小侵入）：
  - `isales-telephony-edge` 启动时 mac 上没有 GSM modem 也没驱动可装，沿用 `macos-local-audio-dev` 已设计的 `--dev-no-modem` CLI flag 接入（superseded change 的 tasks 4.1-4.5 + 3.x CLI 段照搬，design.md Decision 3 / Decision 4 同理）
  - dev mode 下 edge orchestrator 跳过 `SerialATClient` / USB watcher，cloud 主动 dial 后 edge 直接走"已接通"分支 + audio_bridge.join 用 `MacosArtcPyObjCSession`
  - 与 superseded change 差异：那里 audio I/O 接 mac mic/speaker 走 sounddevice，本 change audio I/O 接真 ARTC 房间（mac mic/speaker 由 ARTC SDK 内部 audio device 路径处理）
- **device-hardware spec delta**：新增 ADDED Requirement "macOS 边缘 ARTC SDK 通过 PyObjC binding 接入"，与既有 "Windows 边缘 ARTC SDK 通过 pybind11 binding 接入"（windows-artc-pybind11 已加）并列
- **deployment-topology spec delta**：扩展或新增 Scenario 明确 macOS dev/QA 形态走真 ARTC + 真 cloud engine；明示**不**作为 v1.0 MVP 验收路径

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `device-hardware`：新增 macOS PyObjC binding Requirement（与 Windows pybind11 binding 并列，pattern 一致）；不修改既有 Requirement，纯追加。
- `deployment-topology`：在既有 "macOS 边缘形态保留" Scenario 后新增 / 扩展 Scenario 明确 macOS dev/QA 走真 ARTC 形态；不修改既有 Requirement 主体，纯追加 Scenario。

## Impact

**受影响代码**：
- `isales-telephony/isales_telephony/audio_bridge/` 新增 `macos_artc_pyobjc.py`（PyObjC delegate + binding + RtcSession 实装）
- `isales-telephony/isales_telephony/audio_bridge/__init__.py` 改 `get_default_rtc_session_class()`（darwin 路径切换 + fallback to mock）
- `isales-telephony/isales_telephony/edge/main.py` 新增 argparse 顶层 flag `--dev-no-modem` / `--dev-channel` / `--dev-uid` / `--dev-peer-uid`（沿用 superseded change 设计）
- `isales-telephony/isales_telephony/edge/orchestrator.py` 新增 dev-no-modem 分支（跳过 modem，注入"已接通" CallSession）
- `isales-telephony/pyproject.toml` 新增 `[macos-artc]` optional extras
- `isales-telephony/deploy/edge/macos/RUNBOOK.md` 新建或扩展

**不受影响**：
- isales-common（`RtcSession` ABC 不变）/ isales-engine（cloud-side 看到的是正常 connected session + 真 RTC peer）/ isales-api / isales-scheduler / isales-worker / isales-web
- `MacosRtcSession`（CI / unit-test 同进程 loopback fixture 保留）
- `WindowsRtcSession` + `windows-artc-pybind11`（Windows 商用路径完全独立）
- 云端 deploy（无 cloud-side 改动；cloud engine 看 mac edge 是真 RTC 参与者，与 Windows edge 等同）
- 商用 PyInstaller Windows build / cloud RUNBOOK / 商用部署

**APIs / 协议**：cloud-edge gRPC 协议、`RtcSession` ABC、`CallSession` schema、Aliyun ARTC token 协议全部不变。

**依赖**：
- 新 optional extras `[macos-artc]`：`pyobjc-core>=10.0` + `pyobjc-framework-Cocoa>=10.0`（仅 mac dev 装；frozen exe / cloud image 不含）
- vendor SDK：`AliRTCSdk.framework` 17 MB（同 Linux 137 MB / Windows SDK 一样不进 git）

**风险**：
- PyObjC delegate subclass 跑在 Cocoa thread，asyncio 在 Python main thread——跨线程桥实施不当会出 deadlock / race / lost wakeup。Mitigation 在 design.md Decision 段。
- Aliyun macOS ARTC SDK 是 SNAPSHOT 版本（`AliRTCSdk_7.8.10000-SNAPSHOT.zip`），稳定性 / API 演进可能不如 Linux 7.10.2 GA。Mitigation：dev-only 形态，发现问题不阻塞商用路径。

**联合验收点不变**：A2 + windows-artc-pybind11 联合验收（Windows frozen exe + 真 ARTC join + 真 GSM modem + 拨真手机 → AI 开场白）仍是 v1.0 MVP 验收唯一标准；mac PyObjC binding 的 dev 演练**不**作为验收点。
