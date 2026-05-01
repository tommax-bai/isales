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

通信通道 SHALL 为本地 Unix socket（单主机部署）+ JSON 消息。指令与事件方向严格区分。

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

## Data Schema

| 表 / 字段 | 用途 |
|---|---|
| `device` | id, name, usb_port, modem_model, imei, status, last_seen_at |
| `sim_card` | iccid, imsi, phone_number, carrier, plan, balance, signal_strength, status, last_checked_at |
| `device_sim_binding` | device_id, sim_card_id, is_active, bind_at, unbind_at |
| `campaign_device` | campaign_id, device_id |
