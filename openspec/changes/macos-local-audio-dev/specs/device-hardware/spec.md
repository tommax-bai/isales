> **2026-05-18 SUPERSEDED — DO NOT MERGE INTO openspec/specs/.** 取代者
> [`macos-artc-pyobjc-binding`](../../../macos-artc-pyobjc-binding/specs/device-hardware/spec.md)。
> 本 spec delta 保留作思路记录；详见
> [`../../proposal.md`](../../proposal.md) 顶部 SUPERSEDED 块。

## ADDED Requirements

### Requirement: macOS dev-only local-audio backend（仅 `--dev-no-modem` 模式启用）

macOS 边缘进程 SHALL 在显式 `--dev-no-modem` 启动模式下提供一条 **dev-only** 的 audio I/O 路径：用 mac 系统默认麦克风 / 扬声器作为 RTC 对端，并跳过真 GSM modem 拨号链路。本 Requirement 与既有 "Windows 平台 backend"（SerialPcm-over-COM）以及既有 macOS PoC backend（`MacosRtcSession` 同进程 loopback mock）**并列**，**不**替代后两者。

本 Requirement 服务于开发同学在 mac 工作机上做策略层（state machine / 3-layer AI pipeline / barge-in / 垫词 / handoff / goal partial）与工程层（cloud-edge gRPC bidi / durable buffer / token mint）的真音频闭环演练。**MUST NOT** 进入 v1.0 商用形态（Windows + 真 GSM modem + 真 Aliyun ARTC SDK，由 `arch-cloud-edge-split` + `windows-artc-pybind11` 联合交付）；**MUST NOT** 影响 A2 + windows-artc-pybind11 联合验收契约。

#### Scenario: 仅在 `--dev-no-modem` flag 下启用

- **WHEN** `isales-telephony-edge` 启动且 `--dev-no-modem` flag **未**传
- **THEN** `audio_bridge/__init__.py::get_default_rtc_session_class()` SHALL 按既有逻辑选择：`sys.platform == "darwin"` → `MacosRtcSession`（loopback mock）/ `sys.platform == "win32"` → `WindowsRtcSession`（pybind11 真 ARTC）/ 其他 → `NotImplementedError`
- `MacosLocalAudioRtcSession` SHALL NOT 被实例化，sounddevice 模块 SHALL NOT 被 import

- **WHEN** `isales-telephony-edge` 启动且 `--dev-no-modem` flag 传入且 `sys.platform == "darwin"`
- **THEN** session 工厂 SHALL 返回 `MacosLocalAudioRtcSession` 类；进程 SHALL NOT 起 `SerialATClient` / USB watcher / 发任何 AT 命令

- **WHEN** `--dev-no-modem` flag 传入但 `sys.platform != "darwin"`
- **THEN** 进程 SHALL fail-fast 退出，并打印明确错误 "dev-no-modem mode is macOS-only; use Windows real ARTC path on this platform"

#### Scenario: PortAudio / sounddevice 作为 audio I/O 后端

- **WHEN** `MacosLocalAudioRtcSession.join(channel, token, uid)` 被调用
- **THEN** session SHALL 通过 `sounddevice` 开 mac 默认 input device 作 mic capture（16 kHz mono int16）；开 mac 默认 output device 作 speaker playback（16 kHz mono int16）；`channel` / `token` / `uid` 仅用作日志 / dev 标识，**MUST NOT** 验证 token、**MUST NOT** 联接任何远端 RTC 信道
- input/output device SHALL 可由 CLI flag `--dev-input-device <name|idx>` / `--dev-output-device <name|idx>` 显式指定，未指定时走 `sd.default.device`
- session 启动 SHALL 打印 WARN level 日志，提示"使用 mac 系统 mic+speaker；不戴耳机将导致 TTS 回灌 / barge-in 误触 / ASR 失真"

#### Scenario: 16 kHz mono int16 PCM，与 RTC ABC 一致，无重采样

- **WHEN** mic capture 产生 PCM
- **THEN** PCM SHALL 以 16 kHz / 16-bit / LE / mono / 20 ms 帧（320 samples = 640 字节）为单位通过 `audio_frames()` async iterator 暴露给 engine，与 `isales_common.audio.rtc.PcmFrame` 形状一致
- `push_audio(pcm, timestamp_ms)` 接受同样格式 PCM，写入 mac 默认 output device
- **MUST NOT** 经过 `audio_bridge/resampler.py`（resampler 仅供 modem 8 kHz ↔ RTC 16 kHz 路径使用，dev 路径无 modem）；CoreAudio / PortAudio 自身完成系统-device 真实采样率与 16 kHz 之间的转换

#### Scenario: dev mode 单 session 不并发

- **WHEN** dev mode 启动
- **THEN** 进程内 SHALL 仅运行一个 `MacosLocalAudioRtcSession` 实例；不接受第二通呼叫；teardown 后进程退出（不自动重启接续第二通）

#### Scenario: 回声 / AEC 不在本 Requirement 范围

- **WHEN** dev 同学不戴耳机使用本 backend
- **THEN** mic 收到 speaker 输出的 TTS 是已知行为；本 Requirement **MUST NOT** 实装任何形式的 AEC / echo cancellation / 回声抑制；dev recipe 文档 SHALL 强制要求戴耳机使用

#### Scenario: 商用路径不引入 sounddevice 依赖

- **WHEN** Windows PyInstaller 商用 frozen exe 构建（见 `deploy/edge/windows/build.ps1`）
- **THEN** `sounddevice` 与 `PortAudio` SHALL NOT 被打入 frozen exe；商用 exe 二进制 MUST NOT 含本 backend 任何代码路径
- `sounddevice` SHALL 仅作为 `isales-telephony` `[project.optional-dependencies]` 中的 `dev-mac-audio` extras 安装，不进入 `dependencies` 主列表
- `MacosLocalAudioRtcSession` 模块 SHALL 使用 lazy import sounddevice，未装 extras 时 ImportError SHALL 给出明确提示 "pip install -e '.[dev-mac-audio]' first"

#### Scenario: 不影响既有 `MacosRtcSession` / `WindowsRtcSession`

- **WHEN** 本 Requirement 实装上线
- **THEN** `isales_telephony/audio_bridge/session.py::MacosRtcSession`（同进程 loopback mock，A2 / CI 测试用）SHALL 不被修改
- `isales_telephony/audio_bridge/windows_rtc_session.py::WindowsRtcSession`（pybind11 真 ARTC，`windows-artc-pybind11` 实装）SHALL 不被修改
- `RtcSession` ABC（`isales-common/isales_common/audio/rtc.py`）SHALL 不被修改
