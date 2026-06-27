## Purpose

定义通话设备硬件层：USB GSM Modem 直连主机的自研控制方案。本规范覆盖 modem-controller 进程职责、device 状态机、SIM 资料化管理、udev 自动检测、engine ↔ modem-controller IPC 协议、hangup_cause 映射。v1 单主机 ≤8 路并发，**不使用 FreeSWITCH / Asterisk / chan_dongle 等开源 PBX**。
## Requirements
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

### Requirement: device 状态机

`device.status` SHALL 在以下状态间转换：

- `unknown` → `detected` → `registered` → `idle` → `dialing` → `in_call` → `idle`
- 任何状态 → `offline`（USB 拔出）
- `idle` / `in_call` → `flagged`（健康度低）
- `detected` → `error`（AT 初始化失败）

#### Scenario: 设备插入后初始化

- **WHEN** udev 检测到新 USB 设备且识别为 GSM modem
- **THEN** device.status = `detected`；modem-controller 发 AT 命令初始化；初始化成功后 → `registered` → `idle`

#### Scenario: 拨号期间状态

- **WHEN** engine 调 dial 接口选中某 device
- **THEN** device.status = `dialing` → 接通后 `in_call` → 挂断后 `idle`

#### Scenario: USB 拔出

- **WHEN** udev 检测到 USB 设备拔出
- **THEN** 对应 device 状态 SHALL 立即置 `offline`；正在使用该 device 的 call_session MUST 收到 device_error 事件并优雅清理

#### Scenario: edge daemon 五件套真启动后双通道实测

- **WHEN** Windows edge `isales_telephony.main_windows` daemon 启动且通过 cloud-edge gRPC 与 ECS engine 建链 (`grpc_connected`)
- **THEN** 同一进程 SHALL 同时持有：① COM12 (HS-USB AT) `pyserial` 句柄 ATR `AT\r\n → OK`；② COM11 (HS-USB Audio Class=Ports) PCM byte stream gated by `AT+CPCMREG=1`；③ `dingrtc_pywrap` 的 `WindowsDingRtcSession` (Windows pybind .pyd 加载成功 + DingRTC vendor DLL 链路顺)；④ `.edge-token-test.jwt` 加载完成 (cloud-edge gRPC client 持 bearer)；五件套全 active 后 `device.status` SHALL 透过 cloud-edge `Heartbeat` 上报 → `registered` (无 USB 拔出 / 无 AT 失败 / 无 RTC join 失败)；MUST 在 tray icon 显示 green

### Requirement: SIM 卡资料化管理

`sim_card` 表 SHALL 覆盖以下属性：iccid / imsi / phone_number / carrier / plan / balance / signal_strength / status / last_checked_at。`device_sim_binding` 表 SHALL 记录绑定历史。

#### Scenario: SIM 表字段

- **WHEN** 系统注册新 SIM
- **THEN** sim_card 记录 MUST 含：iccid（硬件唯一标识）、imsi、phone_number（caller_id 来源）、carrier（移动/联通/电信）、plan、balance、signal_strength、status (active/suspended/arrears/flagged)、last_checked_at

#### Scenario: device_sim_binding 唯一活跃约束

- **WHEN** 同一 device 同一时刻
- **THEN** device_sim_binding 表中 MUST 至多 1 条 `is_active=true`

#### Scenario: 热插拔变更绑定

- **WHEN** udev 检测到 device 上的 SIM 变更（ICCID 不同）
- **THEN** modem-controller SHALL 关闭旧 binding（写 unbind_at）→ 新建 binding 记录（is_active=true, bind_at=now）

### Requirement: udev 自动检测流程

modem-controller SHALL 在收到 udev 事件后自动维护 device 与 binding。

#### Scenario: 处理 add 事件

- **WHEN** udev 触发 `add` 事件
- **THEN** modem-controller 步骤如下：
  1. 通过 ttyUSB / 设备 ID 识别是 GSM modem
  2. 发 AT+CCID / AT+CGMI / AT+CGSN 拿到 ICCID / 厂商 / IMEI
  3. 查 DB：已有 device 记录 → 更新 `last_seen_at` 并置 `idle`；新设备 → 创建 device 记录置 `detected`
  4. 检查 SIM 变更：上次绑定的 ICCID ≠ 当前 → 关闭旧 binding，建新 binding

#### Scenario: 处理 remove 事件

- **WHEN** udev 触发 `remove` 事件
- **THEN** modem-controller SHALL 找到对应 device → 状态置 `offline`；关闭 active binding 的 unbind_at

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

### Requirement: v1 不做的硬件能力

v1 SHALL 不实现 SMS、多主机扩展、硬件级负载均衡、信道质量自动切换；这些 MUST 全部列入 v2。

#### Scenario: SMS 推迟到 v2

- **WHEN** v1 接入硬件
- **THEN** modem-controller MUST NOT 实现短信发送 / 接收逻辑

#### Scenario: 信号差只标记不切换

- **WHEN** 某 device 信号强度低于阈值
- **THEN** worker SHALL 把 device.status 置 `flagged`；MUST NOT 自动切换到其他 device 重发

### Requirement: 选号 API schema 出处

云-边拆分后云内 scheduler 选 device 走云内函数调用，不再有 HTTP RPC，原"选号 API schema"约束改为：选 device 的入参 / 出参数据形态 SHALL 由 isales-common 的 `DialCommand` protobuf message 与云内 `Device` SQLAlchemy 模型共同定义；scheduler 与 engine 跨服务调用 MUST 引用同一份 schema。

#### Scenario: 跨服务模型出处

- **WHEN** scheduler 派发 dial / engine 接收 dial
- **THEN** 双方 SHALL 通过 `from isales_common.proto.cloud_edge_pb2 import DialCommand` 引用同一份 protobuf 编译产物；MUST NOT 各自重新定义 dial 字段

#### Scenario: schema 演进通过 isales-common bump

- **WHEN** dial 字段需要增减
- **THEN** SHALL 走 isales-common 版本 bump 流程；scheduler / engine / 边缘 telephony 三方 MUST 同步升级；MUST NOT 一方先改造成 schema 不一致

### Requirement: ATClient 实现策略

modem-controller SHALL 提供两个 `ATClient` Protocol 实现：`SerialATClient`（v1 生产）与 `MockATClient`（开发 / CI / 无硬件本地调试）。`modem-controller` 进程 MUST 在启动时按环境变量严格 dispatch，MUST NOT 在缺配置时静默回退 mock。

#### Scenario: SerialATClient 为 v1 生产实现

- **WHEN** modem-controller 进程在生产环境启动（systemd unit / launchd plist）
- **THEN** 进程 SHALL 用 `SerialATClient` 实例承担所有 AT 命令通道职责；该实例 MUST 内部持有：
  - 一个 `pyserial` 打开的 `/dev/ttyUSB*`（Linux）或 `/dev/cu.usbmodem*`（macOS）串口
  - 一个 `serial_protocol.AtClient` 实例（低层 framing + URC 队列）
  - 一个由 `drivers.detect_driver()` 选出的 `ModemDriver` 子类实例（A7670 / SIM800C / Quectel UC20）

#### Scenario: env dispatch 与失败语义

- **WHEN** modem-controller 进程启动
- **THEN** 选择 ATClient 实现的 SHALL 严格按以下规则：
  1. 若 `ISALES_MODEM_SERIAL_PATH` 已设置 → 用该路径构造 `SerialATClient`；构造失败（设备不存在 / 权限不够 / 串口被占）MUST 抛异常并 exit 非零
  2. 若 `ISALES_MODEM_SERIAL_PATH` 未设置且 `ISALES_ALLOW_MOCK_AT=1` → 用 `MockATClient` 并打 WARN 日志
  3. 其他情况 → 抛 `RuntimeError` 并 exit 非零
- 进程 MUST NOT 在生产环境（无 `ISALES_ALLOW_MOCK_AT=1`）静默回退 mock

#### Scenario: ISALES_MODEM_DRIVER 提示语义

- **WHEN** `ISALES_MODEM_SERIAL_PATH` 已设置且 `ISALES_MODEM_DRIVER` 可选环境变量已设置（值为 `a7670` / `sim800c` / `quectel_uc20`）
- **THEN** `SerialATClient` 构造时 MUST 把该值作为 hint 传给 `drivers.detect_driver(at, hint=...)`，跳过 `AT+GMI` / `AT+GMM` 自动 detect；hint 未设置时走自动 detect、detect 失败时回落到 `A7670Driver`（保持现行 `detect_driver` 行为）

#### Scenario: handlers 显式注入 ATClient

- **WHEN** `modem_controller.handlers.build_handlers()` 被调用
- **THEN** 函数 MUST 要求显式传 `at_client` 参数；MUST NOT 在 `at_client is None` 时默认构造 `MockATClient()` 兜底（取消 stage-2 兜底逻辑，避免线上漏配置静默走 mock）

### Requirement: URC → ATEvent 翻译契约

`SerialATClient.dial()` SHALL 在 ATD 命令被 modem 接受（OK ACK）后立即返回 `(call_id, AsyncIterator[ATEvent])`；事件流 MUST 由后台协程订阅 `AtClient` 的 URC 通道（通过 `on_urc()` 回调或等价机制）翻译串口 URC 为 `ATEvent` 实例。

#### Scenario: ATD ACK 不触发 connected 事件

- **WHEN** `SerialATClient.dial(number)` 被调用，`ModemDriver.dial()` 返回 `DialResult(connected=True)`
- **THEN** `SerialATClient` MUST NOT 立即 yield `ATEvent("connected", ...)`；MUST 仅返回 `call_id` 与事件流，并等待真正的 CONNECT URC 到达后才 yield connected 事件
- ATD 命令被 modem 拒绝（`DialResult(connected=False)` 含 `hangup_cause`）时 MUST 立即 yield `ATEvent("remote_hangup", call_id, cause=<DialResult.hangup_cause>)` 并结束事件流

#### Scenario: 接通 URC 翻译

- **WHEN** AtClient URC 通道推出表示对端接听的信号（A7670 默认是 `+CIEV` 的语音呼叫激活通知；不同 vendor 可能用 `CONNECT` 等价 token）
- **THEN** 事件流 MUST yield 一次 `ATEvent("connected", call_id)`；同一通话生命周期内 MUST NOT 重复 yield connected；若 vendor 不主动推该 URC（例如某些固件只在响铃后短暂的 OK 之后才推），实现 MAY 用 vendor driver 子类内的 polling 兜底（如周期性 `AT+CLCC` 查询活动呼叫状态），但 SHALL NOT 把 ATD 命令本身的 OK ACK 当作 connected 信号

#### Scenario: 远端挂断 URC 翻译与 cause 映射

- **WHEN** AtClient URC 通道推出 `NO CARRIER` / `BUSY` / `NO ANSWER` / `NO DIALTONE` 等远端挂断 URC
- **THEN** 事件流 MUST 用 `drivers.HANGUP_CAUSE_MAP` 把原始 URC token 映射为 `hangup_cause` 值（见 `isales_common.enums.HangupCause`（`user_hangup` / `user_busy` / `no_answer` / `network_out_of_order` / `temporary_failure` / `normal_clearing` / `call_rejected`）），yield `ATEvent("remote_hangup", call_id, cause=<mapped>)` 并结束事件流；映射缺失 MUST 落到 `network_out_of_order`（保守归类为网络层问题，retry-followup 会触发重试）
- 若需要更精细 cause 区分（如把 `+CEER: 41`（Temporary failure）从 fallback 的 `network_out_of_order` 升级到精确的 `temporary_failure`），driver 子类 MAY 在 URC 到达后异步触发 `AT+CEER` 查询并把 `+CEER` cause code 经 `HANGUP_CAUSE_MAP` 二次映射；该路径属增强能力，v1 不要求

#### Scenario: 本端主动挂断

- **WHEN** `SerialATClient.hangup(call_id)` 被调用
- **THEN** 实现 MUST 调 `ModemDriver.hangup()` 发 ATH / `+CHUP`；事件流 MUST yield `ATEvent("remote_hangup", call_id, cause="manual_hangup")` 并结束；该 cause 值 SHALL 加入 `call-state-machine` 的 hangup_cause enum（见对应 spec delta）

#### Scenario: 串口竞争互斥

- **WHEN** 同一串口设备（POSIX 平台 `/dev/ttyUSB*` / `/dev/cu.usbmodem*`；Windows 平台 `COM*` / `\\.\COM*`）被另一个进程已打开
- **THEN** `SerialATClient` 构造时 MUST 通过 platform-appropriate exclusive access 取得独占；任一平台竞争失败 MUST 抛 `BusyDeviceError` 并阻止进程启动；deploy 层 SHALL 确保 modem-controller 单实例
  - POSIX 平台（Linux / macOS）：`fcntl.flock(LOCK_EX | LOCK_NB)` 显式 flock 锁；`BlockingIOError` MUST 翻译为 `BusyDeviceError`
  - Windows 平台：依赖 OS-level exclusive open（`CreateFile` 不带 `FILE_SHARE_*` flag，pyserial 走默认 `dwShareMode = 0`），第二个 open 由 OS 直接拒绝；pyserial 抛出的 access-denied 类异常（`PermissionError` / `SerialException("Access is denied")` / 等价 `OSError(13, ...)`）MUST 由 `SerialATClient.create_from_tty` 单独识别并翻译为 `BusyDeviceError`，其他 open 失败（设备不存在 / 波特率不支持）继续走 `RuntimeError`
- 跨平台抽象 SHALL 通过 `isales_telephony/modem_controller/platforms/serial_lock.py` 提供（`sys.platform` dispatch + lazy import；POSIX 实现持有 fd / Windows 实现返回 no-op handle）；`at_client.py` MUST NOT 在顶层 `import fcntl`（否则 Windows pytest collect 即失败）

### Requirement: 真硬件冒烟脚本

isales-telephony 仓 SHALL 提供 `scripts/at_smoke.py` 用于真硬件端到端冒烟测试。脚本 MUST 不依赖 isales-engine / DB / IPC server，可独立运行以验证 `SerialATClient` 在新部署环境是否打通真 modem。

#### Scenario: 脚本入参与输出

- **WHEN** 运维 / 工程师执行 `python scripts/at_smoke.py --tty <path> --number <phone> [--driver <hint>]`
- **THEN** 脚本 SHALL 构造 `SerialATClient` → 调 `dial(number)` → 把 `ATEvent` 序列打到 stdout（含 `connected` / `remote_hangup` 与 `cause`）→ 接通后等待 5s → 调 `hangup(call_id)` → 等流结束 → exit 0；任何阶段抛异常 → 异常栈打到 stderr → exit 非零

### Requirement: Windows 平台 backend

边缘 isales-telephony 进程在 Windows 10 21H2+ / Windows 11（x64）上 SHALL 通过 `isales_telephony/modem_controller/platforms/windows_serial.py`（USB watcher）与 `isales_telephony/modem_controller/audio/windows_serial_pcm.py`（音频 IO）两个 Windows-specific 模块实现。本 Requirement 补完 A2 `arch-cloud-edge-split` 中 "Windows backend 由 D1 提供" 占位。

Windows backend 与 macOS / Linux backend 共享相同的 platform Protocol（`CaptureBackend.read_chunk()`/`close()` 与 `PlaybackBackend.write_chunk()`/`close()`，定义在 `modem_controller/audio_pipe.py`），上层 modem-controller / audio-bridge 业务逻辑 MUST NOT 因平台不同而分支判断。

> **2026-05-17 amend**：原 Requirement 体下的 "WASAPI 音频 backend 默认 Shared Mode" / "音频帧格式" / "USB GSM modem 音频设备路径" 三个 Scenario 基于 "modem 在 Windows 注册 USB Audio Class endpoint" 假设；D1 PoC 实测 SIM7600G-H + Windows 10/11 完全无 USB Audio Class endpoint，假设字面失效。三个 Scenario 由本 amend 反转为 SerialPcm-over-COM 路径，windows_wasapi.py 在 v1.0 不实现。详见 `archive/2026-05-17-windows-client-core/design.md` Decision 3 amend + 新增 Decision 8。

#### Scenario: USB watcher 实现策略

- **WHEN** 边缘进程在 Windows 上启动
- **THEN** `windows_serial.py` SHALL：
  - 使用 `serial.tools.list_ports.comports()` 枚举所有 COM 端口
  - 每 1-2 s 轮询一次（与 macOS pyserial polling 频率一致，复用 PR #2 路径）
  - 通过 USB VID:PID 白名单（typical GSM modem 厂商，如华为 / 中兴 / SIMCom）+ AT 试探（向疑似 modem 的 COM 端口发 `AT\r\n`，200 ms 内返回 `OK` 视为命中）联合判定哪个 COM 端口是 GSM modem 的 AT 通道
  - VID:PID 白名单 MAY 通过配置文件扩展，MUST NOT 硬编码到无法外部修改

#### Scenario: 多 COM 端口 modem 识别

- **WHEN** 一个 USB GSM modem 在 Windows 上枚举出多个 COM 端口（AT 通道 / Audio PCM 通道 / 诊断通道 / NMEA 通道，典型如 SIMCom 7600 系列 5-COM composite）
- **THEN** `windows_serial.py` SHALL 用 AT 试探判定 AT 通道（哪个 COM 返回 `OK`）；非 AT 通道 SHALL 不被当作 AT modem 候选；Audio PCM 通道（pyserial `description` 字段含 `Audio` 子串、与 AT 通道同 USB composite serial number / 同 VID:PID）SHALL 被识别并以 `audio_serial_path` 字段随 modem identity 一并 emit，供 SerialPcm backend 构造使用

#### Scenario: SerialPcm-over-COM 音频 backend

- **WHEN** Windows 边缘进程启动音频 capture / playback
- **THEN** `windows_serial_pcm.py` SHALL 通过 `pyserial` 打开 modem 的 audio COM 端口（由 USB watcher 识别得到的 `audio_serial_path`），配置 `baudrate=115200, timeout≈0.020, bytesize=8, parity=N, stopbits=1`；MUST NOT 使用 sounddevice / PortAudio / WASAPI / MME / DirectSound 任何 Windows 音频 API
- audio COM 端口本身 SHALL 在进程启动期一次性 open（与 AT 通道同时），跨所有通话复用同一 file handle；进程退出时 close

#### Scenario: 音频帧格式

- **WHEN** SerialPcm capture 读取或 playback 推流
- **THEN** capture SHALL 以 8 kHz / 16-bit / LE / mono / 20 ms 帧（160 samples = 320 字节）为单位 read；playback SHALL 接受同帧格式 PCM 字节流 write；与 audio-bridge 之间的 8 kHz ↔ 16 kHz 重采样由 `modem_controller/audio_pipe.py` 内既有 `upsample_8k_to_16k` / `downsample_16k_to_8k`（与 macOS / Linux backend 共用路径）完成
- host MUST NOT 假设可通过 AT 命令配置帧格式：SIMCOM SIM7600 系列在主流固件（含本机实测 `LE20B04SIM7600G22`）上 `AT+CPCMFMT=?` 返 `ERROR`，帧格式 modem-fixed；其他兼容 SKU MUST 以同帧约定接入

#### Scenario: USB GSM modem 音频设备路径

- **WHEN** Windows 边缘进程对接 USB GSM modem 音频
- **THEN** v1.0 SHALL 走 **SerialPcm-over-COM** 路径——modem 在 Windows composite USB device 内把 audio 接口（典型 SIMCom MI_04）暴露为 `Class=Ports` 串口而非 USB Audio Class endpoint；host 通过 pyserial 在该 COM 端口 read / write 原始 int16 LE PCM 字节流
- v1.0 MUST NOT 走 "USB Audio Class / WASAPI / sounddevice" 路径：D1 PoC 实测 v1.0 主 SKU SIM7600G-H 在 Windows 上 `Get-PnpDevice -Class AudioEndpoint` 对该 modem 返回 ∅；WASAPI fallback 会静默切到员工 PC 笔记本麦克风/扬声器，构成 silent-wrong 故障模式
- 未来如引入显式注册 USB Audio Class endpoint 的 modem SKU（社区报告华为 E398 / 部分 ZTE MF 系列），MAY 在后续 change 单独评估重引入 WASAPI backend 作并列分支；v1.0 范围 MUST NOT 预留 env / dispatch hook / dual-backend abstraction

#### Scenario: PCM 通道按 SIMCom AT 协议启停（CPCMREG）

- **WHEN** modem 收到 CONNECT URC（call connected）或 NO CARRIER URC（远端挂断）/ 本端 ATH
- **THEN** EdgeOrchestrator 的 `_CallContext` 生命周期 SHALL：
  - 在 connected 之后、`audio_bridge.join_rtc()` 之前发 `AT+CPCMREG=1`（启用 audio COM 端口 PCM 字节流），收到 `OK` 才进入下一步；收到 `ERROR` MUST 上报 `HardwareAlert{kind="pcm_enable_failed"}` 并触发挂断
  - 在 teardown 时 `audio_bridge.leave_rtc()` 之后发 `AT+CPCMREG=0`（释放 PCM 字节流）；该命令失败 SHALL 记 warning log 但 MUST NOT 阻塞 teardown
- audio backend `SerialPcm{Capture,Playback}.read_chunk()` / `write_chunk()` 在 CPCMREG=0 期间自然返回 0 字节 / 超时（pyserial timeout 机制），MUST NOT 抛异常
- `AtClient` SHALL 新增 `cpcmreg_enable()` / `cpcmreg_disable()` 两个 helper，与 `dial()` / `hangup()` 同层；其他 modem SKU 接入时若 AT 协议不同，由 `ModemDriver` 子类 override 这两个 helper

#### Scenario: 音频延迟 SLA

- **WHEN** 边缘进程在 Windows 上跑通常通话
- **THEN** SerialPcm capture / playback 端到端延迟（从 modem mic 采样到 audio-bridge 拿到 PCM；以及反向 audio-bridge push 到 modem speaker 输出）P95 SHALL ≤ 50 ms；如不达标，impl 阶段 MAY 调小 pyserial read timeout 或减小 chunk 帧数；持续不达标 MUST 上报 `HardwareAlert` 并触发挂断

#### Scenario: Windows backend 不影响 macOS / Linux backend

- **WHEN** 实施 D1
- **THEN** `isales_telephony/modem_controller/platforms/macos_*.py` 与 `isales_telephony/modem_controller/audio/{macos_coreaudio,linux_alsa}.py`（已 ship）MUST 不被修改；platform 选择 SHALL 在边缘进程启动时根据 `sys.platform` 自动决定，MUST NOT 通过环境变量强制覆盖

### Requirement: Windows USB GSM modem 设备识别

modem-controller 在 Windows 上 SHALL 维护一份 USB GSM modem 白名单（厂商 VID + 产品 PID 元组），用于优先识别已知设备；未命中白名单的 COM 端口 SHALL 通过 AT 试探回退识别；MUST NOT 假设所有 COM 端口都是 modem。

#### Scenario: VID:PID 白名单

- **WHEN** 边缘进程枚举 COM 端口
- **THEN** SHALL 优先匹配 USB VID:PID 与白名单（白名单存放在 `isales_telephony/modem_controller/platforms/windows_modem_vendors.toml` 之类的配置）；匹配成功 SHALL 直接将该 COM 端口视为 GSM modem 候选，进入下一步初始化

#### Scenario: AT 试探回退

- **WHEN** 某 COM 端口的 USB VID:PID 不在白名单
- **THEN** modem-controller SHALL 顺序对该端口发 `AT\r\n`，200 ms 内收到包含 `OK` 的响应视为命中（更新本机白名单缓存 + 进入初始化）；超时或返回异常视为非 modem，跳过；试探 SHALL 限频，每个 COM 端口每分钟至多试探一次（避免轮询过载非 modem 设备）

#### Scenario: 设备初始化序列

- **WHEN** 一个 COM 端口被识别为 GSM modem
- **THEN** modem-controller SHALL 顺序发 `AT+CGMI`（厂商）/ `AT+CGMM`（型号）/ `AT+CGSN`（IMEI）/ `AT+CCID`（ICCID）等 AT 命令完成设备元数据登记；初始化失败（无响应 / 错误响应）SHALL 标记 device status = `error` 而非 `idle`，并通过 cloud-edge gRPC 上报 `HardwareAlert{kind="modem_init_failed"}`

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

### Requirement: 云端 isales-engine 通过项目内 pybind11 binding 接入 DingRTC 3.x Linux C++ SDK

云端 isales-engine SHALL 在 `isales-engine/isales_engine/transport/dingrtc/` 目录下通过项目内 pybind11 binding（产物 `dingrtc_pywrap.so`）包装 DingRTC Linux C++ SDK 3.x，作为 engine session 的 RTC 入会与音频 IO 实现；MUST 暴露 asyncio-friendly 接口供 `audio_pipe` 与 engine session 主循环调用；MUST 实施 `isales_common.audio.rtc.RtcSession` ABC 的 4 个 abstract API（`join(channel, token, uid, *, send_sample_rate, send_channels)` / `leave()` / `is_joined` property / `audio_frames()` async iterator / `push_audio(pcm, *, timestamp_ms)`）。

本 Requirement 取代既有 "云端 engine 的 ARTC SDK 接入"（来自 `arch-cloud-edge-split`，包装 `AliRTCSDK_Linux-7.10.2` Python wrapper + TCP sidecar IPC 模型）。诊断根因：既往 SDK 是 **ApsaraVideo Live 产品线**下的 ARTC SDK（域名 `alivc-demo-cms.alicdn.com`），与 ECS 配置的 **DingRTC 3.x AppId**（`o6dpsan9...`，域名 `dingrtc.oss-cn-zhangjiakou.aliyuncs.com`）不互通 → token 验证必然失败（[[project_dingrtc_migration_groundtruth]]）。

#### Scenario: 项目内 pybind11 binding 编译产物

- **WHEN** cloud Linux engine 部署 / CI 构建
- **THEN** `transport/dingrtc/CMakeLists.txt` SHALL 编译 pybind11 binding，产物 SHALL 为 `dingrtc_pywrap.so`（Linux ELF shared object，CPython ABI 兼容）；编译命令 SHALL 通过 `pip install -e .` 触发（pyproject `[tool.scikit-build]` 或等价 build backend）；MUST NOT 提交 `.so` 二进制到 git 仓库（编译产物在 `.gitignore`）
- 编译过程 SHALL 引用 DingRTC SDK 头文件（默认 `/opt/isales/vendor/DingRTC_Linux_SDK_3_9_0/include/`）与共享库（默认 `/opt/isales/vendor/DingRTC_Linux_SDK_3_9_0/lib/libDingRTC.so`）；vendor 路径 SHALL 通过环境变量 `ISALES_DINGRTC_LINUX_SDK_PATH` 允许 override

#### Scenario: 入会用 RtcEngineAuthInfo 结构（DingRTC 3.x API）

- **WHEN** `RtcSession.join(channel, token, uid, *, send_sample_rate=16000, send_channels=1)` 被调用
- **THEN** binding SHALL 内部调用 `RtcEngine::Create(extras)` 创建 engine 实例 → `SetEngineEventListener(listener)` 注册回调 → 组装 `RtcEngineAuthInfo{channelId=channel, userId=uid, appId=<from credentials>, token=<token>, gslbServer="https://gslb.dingrtc.com"}` → `engine->JoinChannel(authInfo, userName=uid)`
- token 字段 SHALL 直接喂 `isales_engine.transport.rtc_token` 产出（v3.0 binary 算法不变；rtc_token 模块 SHALL NOT 被本变更修改）
- `join` SHALL 等 `OnJoinChannelResult` 回调（通过 main-loop `asyncio.Future`），10 秒超时 raise `RtcError`；result code 非 0 SHALL raise `RtcError(code, message)`

#### Scenario: 外部音频源 push / 远端 PCM observer

- **WHEN** session join 成功后第一次 `push_audio` 调用之前
- **THEN** binding SHALL 调用 `engine->SetExternalAudioSource(true, sampleRate, channels)` 启用外部音频源（参数取 `join` 时传入的 `send_sample_rate` / `send_channels`）；SHALL `engine->PublishLocalAudioStream(true)` + `engine->PublishLocalVideoStream(false)`（audio-only 拓扑）
- **WHEN** `RtcSession.push_audio(pcm, *, timestamp_ms)` 被调用
- **THEN** binding SHALL 组装 `RtcEngineAudioFrame{type=PCM16, bytesPerSample=2, samplesPerSec=sampleRate, channels=channels, buffer=pcm, samples=len(pcm)//2//channels, timestamp=timestamp_ms}` → `engine->PushExternalAudioFrame(&frame)`；调用失败 SHALL raise `RtcError`；vendor 报 buffer full SHALL raise `RtcPushBackpressure`
- 远端订阅 SHALL 走 `engine->SubscribeAllRemoteAudioStreams(true)`（仅混流模式；DingRTC Linux C++ SDK 不提供 per-uid PcmBeforMixing 订阅，v1.0 2-user channel 下混流 = 对方那一路，不构成 blocker）
- binding SHALL 实施 `RtcEngineAudioFrameObserver::OnPlaybackAudioFrame(frame)` 回调，把 PCM 通过 `main_loop.call_soon_threadsafe(...)` marshal 到 `audio_frames()` AsyncIterator

#### Scenario: 离会与销毁

- **WHEN** `RtcSession.leave()` 被调用 或 进程退出
- **THEN** binding SHALL 调用 `engine->LeaveChannel()` → `engine->SetEngineEventListener(nullptr)` → `RtcEngine::Destroy(engine)`；leave SHALL 是 idempotent（二次 leave 不抛）
- 销毁后 engine 指针 SHALL 置 nullptr；后续任何 API 调用 SHALL raise `RtcNotJoined`

#### Scenario: vendor 二进制不进 git，binding 源码进 git

- **WHEN** 任何 commit / PR / CI 构建
- **THEN** DingRTC SDK 共享库 / 头文件 / 文档 SHALL **NOT** 提交到任何 git 仓库；vendor 路径 SHALL 在 `.gitignore` 覆盖（默认 `/opt/isales/vendor/DingRTC_Linux_SDK_*/` glob）
- `transport/dingrtc/` 下的 pybind11 binding 源码（`.cpp` / `.h` / `CMakeLists.txt` / `pyproject` 配置）SHALL 进 git；binding 编译产物（`*.so`）SHALL **NOT** 进 git

### Requirement: macOS 边缘 DingRTC SDK 通过 PyObjC binding 接入（dev / QA 形态）

边缘 isales-telephony 进程在 macOS 13+（x86_64 + Apple Silicon）上 SHALL 通过 `isales_telephony/audio_bridge/macos_dingrtc_pyobjc.py`（项目内 PyObjC bridge）接入真 DingRTC SDK macOS framework；本 Requirement 取代既有 "macOS 边缘 ARTC SDK 通过 PyObjC binding 接入"（loadBundle `AliRTCSdk.framework` 路径），将 vendor SDK 从 ApsaraVideo Live 产品线 ARTC SDK（`AliRTCSdk_7.8.10000-SNAPSHOT`）切换到 DingRTC 3.x（`DingRTC_macOS_SDK_3_9_0`）。

形态边界（dev/QA only / MUST NOT 进商用 / 与既有 mock loopback 并存）与既有 spec 一致；本 Requirement 仅替换 vendor SDK 调用层。

#### Scenario: PyObjC + `objc.loadBundle("DingRTC", ...)` 加载 framework

- **WHEN** 边缘进程在 darwin 平台启动且 `pyobjc-core` 与 `pyobjc-framework-Cocoa` 已安装（通过 `[macos-artc]` optional extras，extras 名保持向后兼容）且 `DingRTC.framework` 解压在约定路径
- **THEN** `MacosDingRtcPyObjCSession.__init__` SHALL 通过 `objc.loadBundle("DingRTC", bundle_path=<framework path>)` 显式加载 framework
- framework path 默认 SHALL 为 `~/codes/vendor/DingRTC_macOS_SDK_3_9_0/DingRTC.framework`；env var `ISALES_MACOS_DINGRTC_FRAMEWORK_PATH` SHALL 允许 override 该默认值（既有 `ISALES_MACOS_ARTC_FRAMEWORK_PATH` SHALL 作 deprecated alias 保留一个 release 周期，读到时 WARN log 并 fallback 解析）
- framework 加载失败（路径不存在 / 不是 framework / 架构不兼容 / Obj-C class lookup 失败）SHALL 在 `__init__` 抛 `RtcError`，错误信息 SHALL 含具体诊断（缺失路径 / 缺失 class / Obj-C runtime error）

#### Scenario: PyObjC NSObject 子类作 DingRtc audio delegate，audio-only 子集

- **WHEN** binding 模块加载
- **THEN** SHALL 定义 PyObjC NSObject 子类 `_DingRtcAudioDelegate` 实施 audio-only 子集 selector（具体 selector 名由 PoC 阶段 `class-dump` framework `.tbd` 确认；约定按 DingRTC iOS SDK selector pattern 实施 `onJoinChannelResult:channel:elapsed:` / `onLeaveChannelResult:` / `onAudioFrame:` 类回调）
- selector 实施 SHALL 把 vendor callback 通过 `main_loop.call_soon_threadsafe(...)` marshal 到 main loop；MUST NOT 在 Obj-C 回调线程内直接调 Python asyncio API

#### Scenario: `MacosDingRtcPyObjCSession` 实施 `RtcSession` ABC，形状镜像 cloud 与 Windows session

- **WHEN** `MacosDingRtcPyObjCSession` 实例被使用
- **THEN** SHALL 实施 `isales_common.audio.rtc.RtcSession` ABC 的 4 个 abstract API；失败模式（`RtcError` / `RtcNotJoined` / `RtcPushBackpressure`）SHALL 与 cloud `DingRtcSession` / Windows `WindowsRtcSession` 一一对齐

#### Scenario: 平台默认路由 darwin → DingRTC PyObjC binding，fallback to mock

- **WHEN** `audio_bridge/__init__.py::get_default_rtc_session_class()` 在 `sys.platform == "darwin"` 下被调用
- **THEN** SHALL 优先 import `MacosDingRtcPyObjCSession` 并返回该类
- **WHEN** import 失败（pyobjc / framework 缺失 / SDK 不在路径）
- **THEN** SHALL 打 WARN log（含装包指引："pip install -e '.[macos-artc]' 并解压 DingRTC SDK 到 ~/codes/vendor/DingRTC_macOS_SDK_3_9_0/"）并 fallback 返回 `MacosRtcSession` mock loopback；MUST NOT 抛硬错（fresh checkout 不应 crash）
- MUST NOT 引入 `ISALES_EDGE_RTC_BACKEND` 类 env var 强制覆盖 platform 选择

#### Scenario: vendor SDK 与依赖隔离

- **WHEN** 商用 Windows PyInstaller 构建 / cloud Linux deploy
- **THEN** `pyobjc-core` / `pyobjc-framework-Cocoa` / `DingRTC.framework` SHALL **NOT** 被打入商用 frozen exe 或 cloud image
- `pyobjc-core` / `pyobjc-framework-Cocoa` SHALL 仅在 `isales-telephony` pyproject `[project.optional-dependencies].macos-artc` 中声明（extras 名保留 `macos-artc` 向后兼容）；商用构建装 base + Windows-specific extras，不装 `[macos-artc]`
- vendor `DingRTC.framework` SHALL **NOT** 进任何 git 仓库；按 [[reference_artc_sdk]] 约定放 `~/codes/vendor/DingRTC_macOS_SDK_3_9_0/`，运行时 `objc.loadBundle(bundle_path=...)` 注入

### Requirement: Windows 边缘 DingRTC SDK 通过项目内 pybind11 binding 接入（vendor 调用层切 DingRTC 3.x）

边缘 isales-telephony 进程在 Windows 10 21H2+ / Windows 11（x64）上 SHALL 通过 `isales_telephony/audio_bridge/windows_rtc_session.py` + 项目内 pybind11 binding（产物 `dingrtc_pywrap.pyd`，源码 `isales-telephony/isales_telephony/audio_bridge/_dingrtc_pywrap_src/`）包装 DingRTC Windows SDK 3.x（`DingRTC.dll`），作为边缘 RTC 入会与音频 IO 实现。

本 Requirement 取代既有 `windows-artc-pybind11` 实装中的 vendor 调用层（包装 `AliVCSDK_ARTC-7.6.0`），保留其 binding 框架（CMake / audio_observer / ring_buffer / engine_listener 通用层 ~80%）；vendor 调用层换 DingRTC 3.x API。

#### Scenario: vendor 路径与 DLL 名

- **WHEN** Windows edge 部署 / `build.ps1` PyInstaller 构建
- **THEN** vendor SDK SHALL 解压在 `C:\Users\<user>\codes\vendor\DingRTC_Windows_SDK_3_9_0\`（或环境变量 `ISALES_DINGRTC_WINDOWS_SDK_PATH` 指定路径）
- DLL 名 SHALL 为 `DingRTC.dll`（取代 `AliVCSDK_ARTC.dll` / `AliRTCSdk.dll`）；PyInstaller spec `binaries` 段 SHALL 显式包含 `DingRTC.dll` + 项目内 binding 产物 `dingrtc_pywrap.pyd`
- pybind11 模块名 SHALL 为 `dingrtc_pywrap`（取代 `aliyun_artc_pywrap`）；PyInstaller `hiddenimports` 段同步更新

#### Scenario: vendor 调用层 API 映射

- **WHEN** binding 编译
- **THEN** 头文件 include SHALL 改为 DingRTC 3.x 提供（`RtcEngine.h` / `RtcEngineAudioFrameObserver.h` / `RtcEngineEventListener.h`）；类名 SHALL 改为 `RtcEngine` / `RtcEngineAuthInfo` / `RtcEngineEventListener` / `RtcEngineAudioFrameObserver`；API 签名 SHALL 与 cloud Linux DingRTC binding 同（`Create` / `Destroy` / `SetEngineEventListener` / `JoinChannel(authInfo, userName)` / `LeaveChannel` / `SetExternalAudioSource(true, sampleRate, channels)` / `PushExternalAudioFrame(RtcEngineAudioFrame)` / `SubscribeAllRemoteAudioStreams(true)`）

#### Scenario: binding 通用层（vendor 无关）保留

- **WHEN** 本变更落地
- **THEN** `windows-artc-pybind11` 既有 binding 框架的通用层 SHALL **NOT** 被重写：
  - `CMakeLists.txt` build pipeline 骨架
  - `audio_observer.cpp/h`（`OnPlaybackAudioFrame` callback 桥接）
  - `ring_buffer.cpp/h`（capture / playback PCM 环形 buffer）
  - `engine_listener.cpp/h`（engine 事件 callback 桥接）
  - Python wrapper `WindowsRtcSession` 形状 + `RtcSession` ABC 实施
- 仅 vendor 调用层（包含的头文件、类名、API 签名）SHALL 重写为 DingRTC 3.x

#### Scenario: 三端 SDK 版本一致性 lint

- **WHEN** CI 构建 / `make spec-validate` / 任何 PR 提交
- **THEN** SHALL 强制三端 DingRTC SDK 版本号一致（`isales-engine` pyproject DingRTC Linux SDK 版本 + `isales-telephony` pyproject DingRTC Windows / macOS SDK 版本 + `deploy/cloud/STATE.md` + `isales-telephony/deploy/edge/windows/STATE.md` + `isales-telephony/deploy/edge/macos/RUNBOOK.md`，5 处对账）；版本不一致 SHALL 阻断 PR 合并
- 任何升 minor SHALL 三端同 PR；MUST NOT 单端升

## Data Schema

| 表 / 字段 | 用途 |
|---|---|
| `device` | id, name, usb_port, modem_model, imei, status, last_seen_at |
| `sim_card` | iccid, imsi, phone_number, carrier, plan, balance, signal_strength, status, last_checked_at |
| `device_sim_binding` | device_id, sim_card_id, is_active, bind_at, unbind_at |
| `campaign_device` | campaign_id, device_id |
