## Purpose

定义通话设备硬件层：USB GSM Modem 直连主机的自研控制方案。本规范覆盖 modem-controller 进程职责、device 状态机、SIM 资料化管理、udev 自动检测、engine ↔ modem-controller IPC 协议、hangup_cause 映射。v1 单主机 ≤8 路并发，**不使用 FreeSWITCH / Asterisk / chan_dongle 等开源 PBX**。
## Requirements
### Requirement: 自研控制层与单主机部署

v1 SHALL 不引入任何开源 PBX；硬件控制 MUST 由自研 `modem-controller` 进程承担。该进程 SHALL 与 telephony-api 同仓库、不同 deployable，单主机部署。

#### Scenario: 不引入 PBX

- **WHEN** v1 实施硬件控制
- **THEN** MUST NOT 安装 FreeSWITCH / Asterisk / chan_dongle / mod_gsmopen 等开源 PBX 组件

#### Scenario: 仓库与进程关系

- **WHEN** 部署 v1
- **THEN** isales-telephony 仓库 SHALL 提供两个 entry point：
  - `telephony-api`（HTTP 服务，处理 device/SIM 管理与选 device）
  - `modem-controller`（守护进程，处理 udev/AT 命令/PCM 音频）

#### Scenario: 单主机限制

- **WHEN** v1 规模规划
- **THEN** 系统 MUST 设计为单主机 ≤ 8 路并发；多主机扩展 MUST 列入 v2

### Requirement: modem-controller 三大职责

modem-controller SHALL 实现以下子系统：udev 监听器、AT 命令通道、PCM 音频管道。每个子系统都通过 IPC 暴露给 engine。

#### Scenario: udev 监听器

- **WHEN** modem-controller 启动
- **THEN** SHALL 用 pyudev 持续监听 USB 设备 add / remove 事件，自动同步 device 表状态

#### Scenario: AT 命令通道

- **WHEN** engine 通过 IPC 请求拨号 / 挂断 / 状态查询
- **THEN** modem-controller SHALL 通过 `/dev/ttyUSB*` 串口发送对应 AT 命令（ATD 拨号、ATH 挂断、AT+CSQ 信号、AT+CCID 卡号、AT+CGSN IMEI 等）

#### Scenario: PCM 音频管道

- **WHEN** 通话建立
- **THEN** modem-controller SHALL 通过 ALSA（`/dev/snd/pcmC*D*c`）双向流转音频：上行 8kHz 16-bit linear PCM → 重采样 16kHz → engine；下行 engine TTS PCM → 重采样 8kHz → ALSA playback

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

通信通道 SHALL 为本地 Unix socket（单主机部署）+ JSON 消息。指令与事件方向严格区分。`session_id` SHALL 是 caller（engine）提供的相关 ID；事件帧 MUST 仅暴露 `session_id` 字段，不暴露 modem-controller 内部生成的 UUID。

#### Scenario: engine → modem-controller 指令格式

- **WHEN** engine 发起拨号 / 挂断 / 推送下行音频
- **THEN** 消息格式 MUST 形如：
  ```json
  {"cmd": "dial",   "device_id": 3, "number": "13800138000", "session_id": "abc"}
  {"cmd": "hangup", "session_id": "abc"}
  {"cmd": "audio_downstream", "session_id": "abc", "pcm_chunk": "<base64>"}
  ```

#### Scenario: modem-controller → engine 事件格式

- **WHEN** modem-controller 上报通话进展 / 音频 / 错误
- **THEN** 消息格式 MUST 形如：
  ```json
  {"event": "call_progress", "session_id": "abc", "state": "ringing"}
  {"event": "connected",     "session_id": "abc"}
  {"event": "audio_upstream","session_id": "abc", "pcm_chunk": "<base64>"}
  {"event": "remote_hangup", "session_id": "abc", "cause": "no_answer"}
  {"event": "device_error",  "session_id": "abc", "code": "signal_lost"}
  ```

#### Scenario: 音频流 v1 走同一 IPC

- **WHEN** v1 实施
- **THEN** 音频流 SHALL 与控制消息走同一 Unix socket（v1 简化）；后期可改为独立流通道（pcm_upstream / pcm_downstream）减少 JSON 编解码开销

#### Scenario: session_id 缺省时的回退

- **WHEN** 调用方（如手工调试 / 旧客户端）省略 `session_id` 字段
- **THEN** modem-controller MAY 用内部生成的 UUID 作为 session_id 回填到 ack 与所有后续事件帧；MUST NOT 把这个 UUID 以 `call_id` 字段单独暴露（事件帧只允许 `session_id` 一个对应字段）；engine 路径正常使用时 MUST 自带 session_id

#### Scenario: 事件帧字段最小化

- **WHEN** modem-controller 发送任何 event 帧
- **THEN** 帧 MUST 仅包含 `event` + `session_id` + 该事件类型语义所需字段（如 `cause` / `code` / `pcm_chunk` / `state`）；MUST NOT 同时回 `call_id` 等内部值（删除 stage-2 留下的 backward-compat 字段）

### Requirement: IPC 帧格式

`engine` ↔ `modem-controller` 的 Unix socket 通信 SHALL 使用 newline-delimited JSON 帧格式：每条消息以 `\n` 结尾，单条消息内 MUST NOT 出现裸换行；接收方按行读取并 `json.loads()` 解析。本 Requirement 是 § engine ↔ modem-controller IPC 协议 的具体化。

#### Scenario: 消息分帧

- **WHEN** 任一端发送一条 IPC 消息
- **THEN** SHALL 在 JSON 序列化结果末尾追加单个 `\n`；JSON 中嵌入的字符串字段若含换行 MUST 按 JSON 标准转义为 `\\n`（不影响分帧）

#### Scenario: 不完整帧的处理

- **WHEN** 接收方读到 EOF 但当前缓冲区有未结束的数据（无 `\n`）
- **THEN** SHALL 视为协议错误，关闭连接并日志告警；MUST NOT 尝试 partial parse

#### Scenario: 单条消息大小上限

- **WHEN** 任一端构造或接收单条消息
- **THEN** SHALL 限制单条 ≤ 1 MiB（覆盖最大 PCM chunk + 控制元数据）；超限发送方 SHALL 拒绝发送、接收方 SHALL 关闭连接并告警

#### Scenario: 双向独立流

- **WHEN** engine 与 modem-controller 同时读写
- **THEN** 双向独立异步 Stream（asyncio StreamReader/Writer），消息不互相阻塞；SHALL NOT 假设请求/响应严格配对（控制指令与音频流交错走同一 socket）

### Requirement: 选 device API

`telephony-api` SHALL 暴露 `POST /devices/select` 给 scheduler 在拨号前调用。请求与响应 schema MUST 由 isales-common 集中提供（见 ADDED Requirement: 选号 API schema 出处）；调用方 MUST 引用同一份 Pydantic 模型。

#### Scenario: 选 device 入参与出参

- **WHEN** scheduler 调用 `POST /devices/select`
- **THEN** 请求体 = `{ campaign_id }`；响应体 = `{ device_id, phone_number }`

#### Scenario: 选 device 算法

- **WHEN** telephony-api 处理选号请求
- **THEN** SHALL：
  1. 取该 Campaign 关联的 device（通过 `campaign_device` 中间表）
  2. 过滤 `device.status=idle` 且 `device_sim_binding.is_active=true`
  3. 选 `device.last_call_at` 最早的（保持负载均衡）；`last_call_at IS NULL`（从未拨打）SHALL 视为最早，优先选中
  4. 没有空闲设备 → 返回 `503 no_idle_device`

#### Scenario: 选号成功后回写 last_call_at

- **WHEN** telephony-api 选中某 device 返回给 scheduler
- **THEN** SHALL 在响应返回前更新 `device.last_call_at = now()`；MUST NOT 等待真实拨号成功后再写；SHALL 保证并发 `/devices/select` 调用不会选中同一台 idle device（实现 MAY 用事务 + `SELECT ... FOR UPDATE`、行级锁或乐观锁，由 impl-telephony 决定具体策略）

### Requirement: GSM hangup_cause 映射

modem-controller SHALL 把 GSM 原始 cause 映射为统一的 `hangup_cause` 字段供 retry-followup 决策使用。

#### Scenario: cause 映射表

- **WHEN** modem-controller 上报 remote_hangup
- **THEN** 映射如下：
  - `no answer` / `no carrier` → `no_answer`（重试）
  - `busy` → `user_busy`（重试）
  - `network failure` / `signal lost` → `network_out_of_order`（重试）
  - `normal call clearing` → `normal_clearing`（走跟进）
  - `call rejected` → `call_rejected`（不重试）

### Requirement: modem-controller 心跳与失联探测

modem-controller SHALL 每 30s 向 telephony-api 发送一次心跳；isales-worker SHALL 每 30s 跑一次 watchdog，把超过 120s 没有心跳的 device 状态置为 `offline`。这把 § device 状态机 中"USB 拔出 → offline"的兜底链路从"udev 必到位"扩到"心跳兜底"，覆盖 modem-controller 进程崩溃 / 主机网络分区 / udev 漏报等场景。

#### Scenario: modem-controller 心跳格式与频率

- **WHEN** modem-controller 进程运行中（任意 device 状态）
- **THEN** 进程 SHALL 每 30s 对每个已注册 device 发一次 `PATCH /devices/{id}/heartbeat`；请求体 `{signal_strength: <0-31, AT+CSQ 实测, optional>}`；MUST NOT 同时更新其他字段（status / last_call_at 等不在心跳路径中维护）

#### Scenario: 心跳端点不修改其他字段

- **WHEN** telephony-api 收到 `PATCH /devices/{id}/heartbeat`
- **THEN** 服务端 MUST 仅更新 `device.last_seen_at = now()`；MUST NOT 修改 `status` / `last_call_at` / `imei` / `signal_strength` 等字段（signal_strength 按 data-model spec 在 sim_card 表，v1 心跳路径暂不级联回写，留给 v2）；MUST 校验当前用户身份（admin JWT 或 service-account JWT 任一）

#### Scenario: watchdog 失联探测

- **WHEN** isales-worker 每 30s 运行 watchdog
- **THEN** 工作 SHALL 把所有 `last_seen_at IS NOT NULL AND last_seen_at < now() - INTERVAL '120 seconds' AND status NOT IN ('offline')` 的 device 行 status 置为 `offline`；同一行二次跑 MUST 幂等（已是 offline 不再写）

#### Scenario: 心跳与 udev 拔出竞态

- **WHEN** USB 设备拔出（udev remove）与 watchdog 失联探测同时检测到同一 device
- **THEN** udev 走 `PATCH /devices/{id}` 直接置 status=offline；watchdog UPDATE 用 `WHERE status != 'offline'` 守卫；DB 行级锁保证最多一次写入；任一路径完成后 status 等于 offline、不会重复触发

#### Scenario: 心跳缺失到恢复

- **WHEN** modem-controller 进程崩溃 → device.status 经 watchdog 置 offline → 进程恢复后第一次心跳到达
- **THEN** 心跳本身 MUST 仅更 last_seen_at；恢复 status=idle 由独立的"udev 注册路径"或者运维显式 `PATCH /devices/{id} status=idle` 触发；MUST NOT 由心跳隐式翻转 status（避免半坏的进程心跳还在但实际不能拨打）

### Requirement: v1 不做的硬件能力

v1 SHALL 不实现 SMS、多主机扩展、硬件级负载均衡、信道质量自动切换；这些 MUST 全部列入 v2。

#### Scenario: SMS 推迟到 v2

- **WHEN** v1 接入硬件
- **THEN** modem-controller MUST NOT 实现短信发送 / 接收逻辑

#### Scenario: 信号差只标记不切换

- **WHEN** 某 device 信号强度低于阈值
- **THEN** worker SHALL 把 device.status 置 `flagged`；MUST NOT 自动切换到其他 device 重发

### Requirement: 选号 API schema 出处

`POST /devices/select` 的请求与响应 Pydantic 模型 SHALL 集中定义在 `isales-common`；telephony-api（响应方）与 scheduler（请求方）MUST 引用同一份模型，MUST NOT 各自维护独立 schema。

#### Scenario: schema 在 isales-common 的位置

- **WHEN** isales-common 落地阶段 2 增量
- **THEN** SHALL 在 `isales_common/schemas/device.py` 增加 `DeviceSelectRequest`（字段：`campaign_id: int`）与 `DeviceSelectResponse`（字段：`device_id: int`、`phone_number: str`）

#### Scenario: scheduler 引用而非复制

- **WHEN** scheduler（impl 阶段 3）实现选号调用
- **THEN** scheduler 代码 MUST 通过 `from isales_common.schemas.device import DeviceSelectRequest, DeviceSelectResponse` 引用；MUST NOT 在 scheduler 仓库内重新定义同名模型

#### Scenario: schema 演进通过 isales-common bump

- **WHEN** select API 的字段需要增减
- **THEN** SHALL 走 isales-common 版本 bump 流程；调用方与响应方 MUST 同步升级；MUST NOT 一方先改造成 schema 不一致

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

- **WHEN** 同一 `/dev/ttyUSB*` 或 `/dev/cu.usbmodem*` 被另一个进程已打开
- **THEN** `SerialATClient` 构造时 MUST 用 `fcntl.flock(LOCK_EX | LOCK_NB)` 拿独占锁；拿不到 MUST 抛 `BusyDeviceError` 并阻止进程启动；deploy 层 SHALL 确保 modem-controller 单实例

### Requirement: 真硬件冒烟脚本

isales-telephony 仓 SHALL 提供 `scripts/at_smoke.py` 用于真硬件端到端冒烟测试。脚本 MUST 不依赖 isales-engine / DB / IPC server，可独立运行以验证 `SerialATClient` 在新部署环境是否打通真 modem。

#### Scenario: 脚本入参与输出

- **WHEN** 运维 / 工程师执行 `python scripts/at_smoke.py --tty <path> --number <phone> [--driver <hint>]`
- **THEN** 脚本 SHALL 构造 `SerialATClient` → 调 `dial(number)` → 把 `ATEvent` 序列打到 stdout（含 `connected` / `remote_hangup` 与 `cause`）→ 接通后等待 5s → 调 `hangup(call_id)` → 等流结束 → exit 0；任何阶段抛异常 → 异常栈打到 stderr → exit 非零

## Data Schema

| 表 / 字段 | 用途 |
|---|---|
| `device` | id, name, usb_port, modem_model, imei, status, last_seen_at |
| `sim_card` | iccid, imsi, phone_number, carrier, plan, balance, signal_strength, status, last_checked_at |
| `device_sim_binding` | device_id, sim_card_id, is_active, bind_at, unbind_at |
| `campaign_device` | campaign_id, device_id |
