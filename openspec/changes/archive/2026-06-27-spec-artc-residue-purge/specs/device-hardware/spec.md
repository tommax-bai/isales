## MODIFIED Requirements

### Requirement: 自研控制层与单主机部署

v1.0 SHALL 不引入任何开源 PBX；硬件控制 MUST 由自研 `modem-controller` 模块承担。modem-controller 与本 change 新增的 `audio-bridge` 模块 SHALL 同属 isales-telephony 仓库的**单一边缘进程**，作为 asyncio task 在边缘机（macOS Mac mini，A2 时点；Windows 由 D1 处理）部署。telephony-api HTTP 入口在云-边拆分后 SHALL 保留但角色降级为本地查询。

#### Scenario: 不引入 PBX

- **WHEN** v1.0 实施硬件控制
- **THEN** MUST NOT 安装 FreeSWITCH / Asterisk / chan_dongle / mod_gsmopen 等开源 PBX 组件

#### Scenario: 边缘进程结构

- **WHEN** 部署 v1.0
- **THEN** isales-telephony 仓库 SHALL 提供单一边缘进程 entry point，进程内含以下 asyncio task：
  - **modem-controller**：udev / pyserial polling + AT 命令通道 + PCM 设备 IO（macOS 平台用既有 macOS audio backend，Windows 由 D1 提供 audio backend）
  - **audio-bridge**：阿里 DingRTC 3.x SDK 客户端 + PCM 重采样 + 与 modem-controller 同进程环形 buffer 桥接
  - **cloud-edge gRPC client**：与云端 engine 维护 bidi stream + 本地 SQLite 离线 buffer
  - **telephony-api**（可选）：HTTP server 监听 loopback，提供本地设备查询接口（运维 / 本地 isales-web 使用，A2 后非云调用入口）

#### Scenario: 单边缘机 ≤ N 路并发

- **WHEN** 边缘机规模规划
- **THEN** 单边缘机 SHALL 按物理插槽数支持 ≤ N 路 USB GSM modem 并发（v1.0 典型 N=4-8）；MUST NOT 把多边缘机的 modem 跨主机虚拟成"逻辑大池"——多边缘机扩展是水平加机器而非池化

### Requirement: macOS dev-no-modem orchestrator 路径（mac 装不了 GSM modem 驱动的物理约束）

macOS 边缘进程 SHALL 支持 **dev-no-modem 启动模式**：跳过真 GSM modem 拨号链路，由 cloud-side 主动 `Cloud2Edge.dial` 触发后 edge 直接走"已接通" CallSession 走 audio_bridge join + 真 Aliyun RTC 房间。本 Requirement 服务于 mac 上无法安装 USB GSM modem 驱动的物理约束，与 PyObjC binding 形成 dev 形态闭环。

#### Scenario: dev-no-modem CLI flag 触发

- **WHEN** `isales-telephony-edge` 启动且 `--dev-no-modem --dev-channel <name> --dev-uid <id> [--dev-peer-uid <id>]` 顶层 flag 传入且 `sys.platform == "darwin"`
- **THEN** `EdgeOrchestrator` SHALL 在 `start()` 跳过 `SerialATClient` 实例化 / USB watcher 起动 / 任何 AT 命令；仍正常起 cloud-edge grpc_client + audio_bridge
- 进程 SHALL 正常注册 cloud-edge grpc 回调；cloud-side 主动 `Cloud2Edge.dial` 时 edge 直接走"已接通"分支（跳过 `cpcmreg_enable` 与 capture / playback pumps），调 `audio_bridge.join` 用 `MacosDingRtcPyObjCSession` 真 join RTC 房间
- teardown 由 SIGINT / SIGTERM 触发，发 `Edge2Cloud.remote_hangup{hangup_cause="dev_terminate"}` → audio_bridge.leave → 退出进程

#### Scenario: dev-no-modem 不影响生产路径

- **WHEN** `--dev-no-modem` flag **未**传入
- **THEN** orchestrator SHALL 按既有生产路径运行：`SerialATClient` + USB watcher + AT dial / hangup / CPCMREG 全套链路；本 Requirement **MUST NOT** 影响 Windows 商用 PyInstaller frozen exe 行为

#### Scenario: 平台守护

- **WHEN** `--dev-no-modem` flag 传入但 `sys.platform != "darwin"`
- **THEN** 进程 SHALL fail-fast 退出，打印明确错误 "--dev-no-modem 仅 macOS 支持；Windows 商用走真 GSM modem + 真 DingRTC 路径"

### Requirement: audio-bridge 组件

isales-telephony 仓库 SHALL 新增 `audio-bridge` 模块，作为边缘进程内 asyncio task 运行；职责限定于 PCM 重采样 + 阿里 DingRTC 3.x SDK 客户端 + 与 modem-controller 同进程环形 buffer 桥接；MUST NOT 涉及 AT 命令 / 设备硬件管理 / AI 编排。

#### Scenario: audio-bridge 模块职责

- **WHEN** 一通通话激活
- **THEN** audio-bridge SHALL：
  1. 接收来自 cloud-edge gRPC client 转发的 `DialCommand{rtc_channel, rtc_token, rtc_uid_edge}` 入会参数
  2. 调用 DingRTC SDK `JoinChannel(token, channel, uid_edge, username, joinConfig)` 入会
  3. 启用 `SetExternalAudioSource(enable=True, sampleRate=16000, channelsPerFrame=1)` 关掉默认麦克风
  4. 从 modem-controller 上行环形 buffer 取 PCM 帧（已重采样至 16 kHz）→ `PushExternalAudioFrameRawData` 推到 RTC
  5. 收 `OnSubscribeAudioFrame(uid=rtc_uid_engine, pcm)` → 推到 modem-controller 下行环形 buffer
  6. 通话结束（remote_hangup / cancel）调 `LeaveChannel()` 离会

#### Scenario: audio-bridge 重采样

- **WHEN** modem 上行 8 kHz PCM 进入 audio-bridge
- **THEN** SHALL 用平台原生重采样（如 macOS Audio Converter）或纯 Python 重采样（`scipy.signal.resample_poly` / `audioop.ratecv`）转换为 16 kHz / 16-bit mono；下行 RTC PCM 进入 audio-bridge 时反向重采样为 8 kHz；重采样质量 MUST 满足通话语音可懂度（impl 阶段实测）

#### Scenario: audio-bridge 反压

- **WHEN** DingRTC SDK 触发 `OnPushAudioFrameBufferFull` 回调
- **THEN** audio-bridge SHALL 暂停从 modem-controller 上行 buffer 取帧 → SDK 内部 buffer 排空后恢复；MUST NOT 简单丢弃帧（造成对端听到断续）；如反压持续 > 200 ms 视为媒体面异常，SHALL 上报 `Edge2Cloud.HardwareAlert{kind="audio_buffer_stalled"}` 并触发挂断流程

#### Scenario: audio-bridge 与 modem-controller 接口

- **WHEN** audio-bridge 与 modem-controller 同进程跨 task 通信
- **THEN** SHALL 通过 asyncio Queue / 环形 buffer 传递 PCM 帧 + 入会 / 离会指令；MUST NOT 共享可变全局状态；MUST NOT 通过文件系统 / Unix socket / 本地 HTTP 通信（同进程无需）
