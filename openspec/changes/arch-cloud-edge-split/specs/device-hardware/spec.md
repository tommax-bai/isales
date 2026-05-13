## MODIFIED Requirements

### Requirement: 自研控制层与单主机部署

v1.0 SHALL 不引入任何开源 PBX；硬件控制 MUST 由自研 `modem-controller` 模块承担。modem-controller 与本 change 新增的 `audio-bridge` 模块 SHALL 同属 isales-telephony 仓库的**单一边缘进程**，作为 asyncio task 在边缘机（macOS Mac mini，A2 时点；Windows 由 D1 处理）部署。telephony-api HTTP 入口在云-边拆分后 SHALL 保留但角色降级为本地查询。

#### Scenario: 不引入 PBX

- **WHEN** v1.0 实施硬件控制
- **THEN** MUST NOT 安装 FreeSWITCH / Asterisk / chan_dongle / mod_gsmopen 等开源 PBX 组件

#### Scenario: 边缘进程结构

- **WHEN** 部署 v1.0
- **THEN** isales-telephony 仓库 SHALL 提供单一边缘进程 entry point，进程内含以下 asyncio task：
  - **modem-controller**：udev / pyserial polling + AT 命令通道 + PCM 设备 IO（macOS 平台用既有 macOS audio backend，Windows 由 D1 提供 WASAPI backend）
  - **audio-bridge**：阿里 ARTC SDK 客户端 + PCM 重采样 + 与 modem-controller 同进程环形 buffer 桥接
  - **cloud-edge gRPC client**：与云端 engine 维护 bidi stream + 本地 SQLite 离线 buffer
  - **telephony-api**（可选）：HTTP server 监听 loopback，提供本地设备查询接口（运维 / 本地 isales-web 使用，A2 后非云调用入口）

#### Scenario: 单边缘机 ≤ N 路并发

- **WHEN** 边缘机规模规划
- **THEN** 单边缘机 SHALL 按物理插槽数支持 ≤ N 路 USB GSM modem 并发（v1.0 典型 N=4-8）；MUST NOT 把多边缘机的 modem 跨主机虚拟成"逻辑大池"——多边缘机扩展是水平加机器而非池化

### Requirement: modem-controller 三大职责

modem-controller SHALL 实现以下子系统：USB watcher（macOS pyserial polling + 既有 udev 兼容路径）、AT 命令通道、PCM 音频管道。每个子系统都通过同进程 asyncio 接口暴露给 audio-bridge 与 cloud-edge gRPC client。

#### Scenario: USB watcher

- **WHEN** modem-controller 启动
- **THEN** SHALL 用 macOS pyserial polling（已通过 `impl-deploy-macos` 验证）或 Linux pyudev 持续监听 USB 设备 add / remove 事件，自动同步本地设备状态缓存；变更 SHALL 经 cloud-edge gRPC 上报为 `CallEvent.device_state_changed` 或 `HardwareAlert`

#### Scenario: AT 命令通道

- **WHEN** 云端 engine 经 `Cloud2Edge.DialCommand` 请求拨号 / 通过 `Cloud2Edge.CancelCommand` 请求挂断 / 通过 `ConfigUpdate` 请求设备查询
- **THEN** modem-controller SHALL 通过 `/dev/cu.usbserial-*`（macOS）或 `/dev/ttyUSB*`（Linux）串口发送对应 AT 命令（ATD 拨号、ATH 挂断、AT+CSQ 信号、AT+CCID 卡号、AT+CGSN IMEI 等）；结果以 `Edge2Cloud.CallEvent` / `DialAck` 形式经 cloud-edge gRPC 回传

#### Scenario: PCM 音频管道

- **WHEN** 通话建立（modem 与对端通话信道接通）
- **THEN** modem-controller SHALL 通过平台音频 backend（macOS 既有 backend；Windows 由 D1 提供）双向流转 PCM：上行 8 kHz 16-bit linear PCM → 重采样 16 kHz → **推到同进程的 audio-bridge 上行环形 buffer**；下行 audio-bridge 推过来的 PCM → 重采样 8 kHz → 平台音频 backend playback；**MUST NOT 跨进程 / 跨主机直接对接 engine**

### Requirement: engine ↔ modem-controller IPC 协议

云-边拆分后 engine（云端）与 modem-controller（边缘）之间**不再有直接 IPC**。所有原走 Unix socket / 本地 WebSocket 的指令与事件 SHALL 改走两条链路：

1. **控制指令**：通过 cloud-edge gRPC bidi stream（详见 service-communication spec § 云-边控制面）
2. **音频 PCM**：通过阿里 RTC PaaS（详见 service-communication spec § 云-边媒体面），边缘侧由 modem-controller ↔ audio-bridge 同进程环形 buffer + audio-bridge ↔ 云端 RTC SDK 完成

边缘进程内 modem-controller 与 audio-bridge 之间的通信 SHALL 通过同进程 asyncio Queue / 环形 buffer，使用 Python 对象传递，**不需要序列化**。

#### Scenario: cloud → edge 拨号 / 挂断指令

- **WHEN** 云端 engine 发起拨号 / 挂断
- **THEN** 消息 MUST 形如 `Cloud2Edge.DialCommand{call_id, device_id, number, caller_id, rtc_channel, rtc_token, rtc_uid_edge, rtc_uid_engine}` 或 `Cloud2Edge.CancelCommand{call_id}`，经 gRPC bidi 下发；边缘 modem-controller 收到后 SHALL：
  1. 通知 audio-bridge 用 `rtc_token` + `rtc_channel` + `rtc_uid_edge` 入会
  2. 在 audio-bridge 入会确认后发 AT 命令 ATD/ATH 操作 modem
  3. 将 modem 反馈（call_progress / connected / remote_hangup）经 `Edge2Cloud.CallEvent` 上报

#### Scenario: edge → cloud 通话进展上报

- **WHEN** modem-controller 检测到通话状态变化或硬件事件
- **THEN** SHALL 经 cloud-edge gRPC 发送 `Edge2Cloud.CallEvent{call_id, kind, payload}`，`kind` 可取 `ringing` / `connected` / `remote_hangup` / `device_error` 等；payload 含具体 cause（如 hangup_cause 已映射）

#### Scenario: 音频流不走 gRPC

- **WHEN** 实施 v1.0
- **THEN** PCM 音频流 MUST NOT 走 cloud-edge gRPC（带宽 + 时延 + 编解码 + 抖动控制都不胜任）；MUST NOT 通过 gRPC 推 base64 编码的音频 chunk；音频 PCM SHALL 仅通过阿里 RTC PaaS 这一条媒体面通道

#### Scenario: session_id / call_id 一致性

- **WHEN** 任一控制消息或事件
- **THEN** MUST 携带 `call_id`（cloud-edge gRPC message 中字段命名为 `call_id`，与边缘 modem-controller 内部沿用原 `session_id` 概念对齐）；MUST NOT 同时携带 `call_id` 与 `session_id` 双字段（避免歧义）；边缘 modem-controller 内部 asyncio 上下文 MAY 仍用 `session_id` 局部变量名，但跨进程 / 跨主机消息中 SHALL 用 `call_id`

### Requirement: IPC 帧格式

边缘进程内 modem-controller ↔ audio-bridge ↔ cloud-edge gRPC client 之间的通信 SHALL 通过 asyncio Queue / 环形 buffer 传递 Python 对象，无需序列化。云-边 gRPC 通信 SHALL 用 protobuf 序列化（详见 service-communication spec）。

#### Scenario: 边缘进程内对象传递

- **WHEN** 边缘进程内任一 asyncio task 向另一 task 发送消息
- **THEN** SHALL 直接传递 Python dataclass / namedtuple / dict；MUST NOT JSON 序列化（无收益且增加 CPU 与 GC 压力）；队列实现 SHALL 是 `asyncio.Queue` 或 `collections.deque`-based ring buffer

#### Scenario: 音频环形 buffer 容量

- **WHEN** modem-controller 与 audio-bridge 之间传递 PCM 帧
- **THEN** 上行（modem → audio-bridge → RTC）与下行（RTC → audio-bridge → modem）SHALL 各维护独立环形 buffer；buffer 容量 SHALL 至少容纳 200 ms 音频（按 16 kHz / 16-bit / mono 计算 ≈ 6.4 KB / 200 ms，含余量取 16 KB）；溢出 SHALL 丢弃最早一帧并打告警日志（音频丢帧而非整链路阻塞）

### Requirement: 选 device API

云-边拆分后 telephony-api 的 `POST /devices/select` HTTP 接口在云调用链中 SHALL 不再使用。云端 scheduler 选 device SHALL 直接基于云内 PG 中的 device 表（由边缘经 cloud-edge gRPC 上报的状态维护）；dial 指令通过云-边 gRPC `DialCommand` 下发，**不再有"选号 HTTP RPC"**。telephony-api 的选号端点 MAY 在边缘进程内保留（用于本地工具 / 调试），但 MUST 标注为 deprecated。

#### Scenario: 云端选 device 算法

- **WHEN** scheduler 派发新通话
- **THEN** SHALL 在云内 PG 上查询：
  1. 取该 Campaign 关联的 device（通过 `campaign_device` 中间表）
  2. 过滤 `device.status=idle` 且 `device_sim_binding.is_active=true`
  3. 选 `device.last_call_at` 最早的（保持负载均衡）；`last_call_at IS NULL` SHALL 视为最早，优先选中
  4. 没有空闲设备 → 暂停该 dial 并稍后重试（不再返回 503 RPC，因为在云内同进程调用）

#### Scenario: 选号成功后回写 last_call_at

- **WHEN** scheduler 选中某 device 派发 dial
- **THEN** SHALL 在云内 PG 事务中更新 `device.last_call_at = now()` + 生成 `call_id` + 通过 cloud-edge gRPC 发送 `DialCommand`；SHALL 保证并发 dial 不会选中同一台 idle device（云内事务 + 行级锁；MAY 用乐观锁，由 impl 决定）

#### Scenario: 边缘 telephony-api `/devices/select` 状态

- **WHEN** 边缘 telephony-api 收到本地 HTTP `POST /devices/select` 调用
- **THEN** MAY 仍按既有逻辑响应（基于边缘本地 SQLite 缓存的 device 状态），但响应 header MUST 包含 `Deprecation: 1`；该接口 v1.0 后续 change MAY 完全移除

### Requirement: modem-controller 心跳与失联探测

边缘 isales-telephony 进程 SHALL 通过 cloud-edge gRPC bidi stream 每 30 s 上报一次心跳 + 每个本地 device 的健康状态摘要；云端 worker SHALL 监听 cloud-edge stream 健康度 + 处理 `Edge2Cloud.HardwareAlert`，把超过 120 s 无心跳的边缘机所有 device 状态置 `offline`。这把 § device 状态机 中"USB 拔出 → offline"的兜底链路从"udev 必到位"扩到"cloud-edge 心跳兜底"，覆盖边缘进程崩溃 / 网络分区 / udev 漏报等场景。

#### Scenario: 边缘心跳

- **WHEN** 边缘 isales-telephony 进程运行中
- **THEN** 进程 SHALL 每 30 s 发送 `Edge2Cloud.Heartbeat{edge_device_id, timestamp, devices: [{device_id, status, signal_strength?, last_seen_at}]}`；MUST NOT 在心跳中携带其他业务事件（call_event / hardware_alert 独立 message）

#### Scenario: 云端 watchdog 失联探测

- **WHEN** 云端 worker 监听 cloud-edge stream 健康度
- **THEN** 工作 SHALL 把所有 `last_heartbeat IS NOT NULL AND last_heartbeat < now() - INTERVAL '120 seconds' AND status NOT IN ('offline')` 的 device 行 status 置为 `offline`（按云内 PG 写入）；同一行二次跑 MUST 幂等

#### Scenario: 进程恢复

- **WHEN** 边缘进程崩溃 → device.status 经 watchdog 置 offline → 进程恢复后第一次心跳到达
- **THEN** 心跳本身 MUST 仅更 last_heartbeat；恢复 status=idle 由独立的 udev / pyserial 重新探测路径触发，经 `CallEvent.device_state_changed` 上报；MUST NOT 由心跳隐式翻转 status

### Requirement: GSM hangup_cause 映射

modem-controller SHALL 把 GSM 原始 cause 映射为统一的 `hangup_cause` 字段，通过 `Edge2Cloud.CallEvent{kind="remote_hangup", payload.hangup_cause}` 上报到云端，供 retry-followup 决策使用。

#### Scenario: cause 映射表

- **WHEN** modem-controller 上报 remote_hangup
- **THEN** 映射如下（与 A1 `impl-real-at` 已 ship 的 canonical 集合一致）：
  - `no answer` / `no carrier` → `no_answer`（重试）
  - `busy` → `user_busy`（重试）
  - `network failure` / `signal lost` → `network_out_of_order`（重试）
  - `normal call clearing` → `normal_clearing`（走跟进）
  - `call rejected` → `call_rejected`（不重试）

### Requirement: 选号 API schema 出处

云-边拆分后云内 scheduler 选 device 走云内函数调用，不再有 HTTP RPC，原"选号 API schema"约束改为：选 device 的入参 / 出参数据形态 SHALL 由 isales-common 的 `DialCommand` protobuf message 与云内 `Device` SQLAlchemy 模型共同定义；scheduler 与 engine 跨服务调用 MUST 引用同一份 schema。

#### Scenario: 跨服务模型出处

- **WHEN** scheduler 派发 dial / engine 接收 dial
- **THEN** 双方 SHALL 通过 `from isales_common.proto.cloud_edge_pb2 import DialCommand` 引用同一份 protobuf 编译产物；MUST NOT 各自重新定义 dial 字段

#### Scenario: schema 演进通过 isales-common bump

- **WHEN** dial 字段需要增减
- **THEN** SHALL 走 isales-common 版本 bump 流程；scheduler / engine / 边缘 telephony 三方 MUST 同步升级；MUST NOT 一方先改造成 schema 不一致

## ADDED Requirements

### Requirement: audio-bridge 组件

isales-telephony 仓库 SHALL 新增 `audio-bridge` 模块，作为边缘进程内 asyncio task 运行；职责限定于 PCM 重采样 + 阿里 ARTC SDK 客户端 + 与 modem-controller 同进程环形 buffer 桥接；MUST NOT 涉及 AT 命令 / 设备硬件管理 / AI 编排。

#### Scenario: audio-bridge 模块职责

- **WHEN** 一通通话激活
- **THEN** audio-bridge SHALL：
  1. 接收来自 cloud-edge gRPC client 转发的 `DialCommand{rtc_channel, rtc_token, rtc_uid_edge}` 入会参数
  2. 调用 ARTC SDK `JoinChannel(token, channel, uid_edge, username, joinConfig)` 入会
  3. 启用 `SetExternalAudioSource(enable=True, sampleRate=16000, channelsPerFrame=1)` 关掉默认麦克风
  4. 从 modem-controller 上行环形 buffer 取 PCM 帧（已重采样至 16 kHz）→ `PushExternalAudioFrameRawData` 推到 RTC
  5. 收 `OnSubscribeAudioFrame(uid=rtc_uid_engine, pcm)` → 推到 modem-controller 下行环形 buffer
  6. 通话结束（remote_hangup / cancel）调 `LeaveChannel()` 离会

#### Scenario: audio-bridge 重采样

- **WHEN** modem 上行 8 kHz PCM 进入 audio-bridge
- **THEN** SHALL 用平台原生重采样（如 macOS Audio Converter）或纯 Python 重采样（`scipy.signal.resample_poly` / `audioop.ratecv`）转换为 16 kHz / 16-bit mono；下行 RTC PCM 进入 audio-bridge 时反向重采样为 8 kHz；重采样质量 MUST 满足通话语音可懂度（impl 阶段实测）

#### Scenario: audio-bridge 反压

- **WHEN** ARTC SDK 触发 `OnPushAudioFrameBufferFull` 回调
- **THEN** audio-bridge SHALL 暂停从 modem-controller 上行 buffer 取帧 → SDK 内部 buffer 排空后恢复；MUST NOT 简单丢弃帧（造成对端听到断续）；如反压持续 > 200 ms 视为媒体面异常，SHALL 上报 `Edge2Cloud.HardwareAlert{kind="audio_buffer_stalled"}` 并触发挂断流程

#### Scenario: audio-bridge 与 modem-controller 接口

- **WHEN** audio-bridge 与 modem-controller 同进程跨 task 通信
- **THEN** SHALL 通过 asyncio Queue / 环形 buffer 传递 PCM 帧 + 入会 / 离会指令；MUST NOT 共享可变全局状态；MUST NOT 通过文件系统 / Unix socket / 本地 HTTP 通信（同进程无需）

### Requirement: 云端 engine 的 ARTC SDK 接入

云端 isales-engine SHALL 在 `transport/aliyun_rtc.py` 中包装阿里 ARTC SDK for Linux Python，作为 engine session 的 RTC 入会与音频 IO 实现；MUST 暴露 asyncio-friendly 接口供 `audio_pipe` 与 engine session 主循环调用。

#### Scenario: SDK 接入封装

- **WHEN** engine session 启动（响应 scheduler 派发的 dial）
- **THEN** engine SHALL 调用 `aliyun_rtc.RtcSession(channel, token, uid_engine).join()` 入会；接口 SHALL 暴露 `async def on_audio_frame()` 异步迭代器供消费上行 PCM；SHALL 暴露 `async def push_audio(pcm: bytes, timestamp: int)` 推下行 PCM；通话结束 `await rtc_session.leave()`

#### Scenario: audio_pipe RTC backend

- **WHEN** engine `audio_pipe` 选 capture / playback backend
- **THEN** v1.0 云端 SHALL 默认选 `AliyunRTCCapture` / `AliyunRTCPlayback`；接口 MUST 与既有 ALSA / macOS backend 兼容（实现 capture-backend / playback-backend 抽象基类），便于本地开发 / 测试时切回本地 backend

#### Scenario: SDK vendor 路径

- **WHEN** 云端 ECS 部署
- **THEN** SDK 压缩包 SHALL 解压到 `/opt/isales/current/vendor/aliyun-artc-linux-python/`；engine 进程 `sys.path` 或 `pip install -e file://...` 引入；MUST NOT 提交 vendor 二进制到 git 仓库；SHALL 通过 `deploy/cloud/scripts/install.sh` 中专门的 `install-artc-sdk` 步骤从内部 artifact 仓 / OSS 拉取压缩包

### Requirement: 边缘进程不直接读写云端 PG / Redis

边缘 isales-telephony 进程 SHALL 不直接 TCP 连接云端阿里云 RDS / Redis；所有业务数据读 / 写 SHALL 通过 cloud-edge gRPC `Edge2Cloud.CallEvent` / `Edge2Cloud.HardwareAlert` 上报；边缘 SQLite 仅作离线 buffer + 本地设备元数据缓存。

#### Scenario: 边缘 SQLite 用途

- **WHEN** 边缘进程读写 SQLite
- **THEN** SQLite SHALL 仅存储：
  - 云-边 gRPC 离线期间产生的待补发事件
  - 边缘本地缓存的 device / sim_card 元数据（用于离线期间 telephony-api 本地查询）
- MUST NOT 作为权威数据源（云内 RDS 才是）；MUST NOT 存通话内容 / transcript / call_record（这些在云内 PG）

#### Scenario: 边缘 SQLite schema 不与云内 PG schema 强耦合

- **WHEN** isales-common alembic 迁移演进云内 PG schema
- **THEN** 边缘 SQLite 表结构 MAY 落后云内 schema 一两个版本（在 backward-compatible 范围内）；MUST 由 isales-telephony 仓库自行维护边缘 SQLite 迁移脚本；MUST NOT 共用 isales-common alembic 的迁移（避免边缘进程崩在不识别的列上）
