## ADDED Requirements

### Requirement: 真硬件 URC 驱动状态转换

call-state-machine 现有 § "拨号成功进入开场白" / § "用户挂机" scenario 已用 IPC 事件名（`connected` / `remote_hangup`）抽象 ATD 链路细节。本 Requirement 把"IPC 事件 ↔ 真硬件 URC"之间的对应关系固化：engine 状态转换 SHALL 仅由 `SerialATClient` 翻译出的 `ATEvent`（再经 IPC 上抛）触发，MUST NOT 因 ATD 命令 ACK / 中间 URC 单独触发转换。详细 URC → ATEvent 翻译契约见 `device-hardware` spec。

#### Scenario: ATD ACK 后状态停留在 INIT

- **WHEN** call_session 处于 `INIT`，`SerialATClient.dial()` 已返回 `call_id`（ATD ACK 到达）但 CONNECT URC 尚未到达
- **THEN** 状态 MUST 保持在 `INIT`；MUST NOT 因为 ATD ACK 单独转移到 `GREETING`；engine SHALL 等 IPC `connected` 事件（由 CONNECT URC 翻译而来）才触发 INIT → GREETING

#### Scenario: ATD 被拒绝立即结束通话

- **WHEN** `SerialATClient.dial()` 返回的事件流第一条就是 `ATEvent("remote_hangup", ..., cause=<X>)`（ATD 被 modem 拒绝，未到 CONNECT 阶段）
- **THEN** modem-controller MUST 通过 IPC 上报 `remote_hangup` 事件给 engine；engine 状态 MUST 从 `INIT` 直接 → `END(reason=<X>)`，跳过 `GREETING`；transcript 中 SHALL 记录 `{type: "state_error", attempted: "connected", from_state: "INIT", to_state: "GREETING", ts: ...}` ——本路径属"拨号被拒绝"，不算非法转移，但要在 transcript 留痕便于分析

#### Scenario: 远端 hangup_cause 透传到 END reason

- **WHEN** modem-controller 上报 `remote_hangup` 事件，cause 为 `isales_common.enums.HangupCause` GSM-side 值之一（`no_answer` / `user_busy` / `network_out_of_order` / `temporary_failure` / `normal_clearing` / `call_rejected` / `user_hangup`）
- **THEN** 状态 → `END`，`END.reason` MUST 等于该 cause 值；MUST NOT 把所有远端挂断都笼统映射成 `user_hangup`（覆盖现行 § "用户挂机" scenario 的过简描述——该 scenario 描述的是"用户主动挂机"特例，`user_hangup` 仅是其中一种）

#### Scenario: 本端主动挂断的 cause 值

- **WHEN** engine 主动调 `SerialATClient.hangup(call_id)`（如 goal 达成进入 WRAPPING_UP 后 TTS 播完，或 max_no_progress_seconds 超时）
- **THEN** 事件流将 yield `ATEvent("remote_hangup", call_id, cause="manual_hangup")`；engine 收到该事件时状态已经在 `END` 或 `WRAPPING_UP` → `END` 路径中；`manual_hangup` cause SHALL NOT 被状态机用作 `END.reason`（END reason 由触发 hangup 的业务理由决定，如 `wrap_up_completed` / `no_progress_timeout` / `marked_for_handoff`）

### Requirement: hangup_cause 单一来源

通话生命周期 hangup_cause 字段 SHALL 取值自 `isales_common.enums.HangupCause` 枚举；该枚举是**唯一权威**——modem-controller / engine / worker / retry-followup spec / call-state-machine spec 之间的 cause 字符串 MUST 全部对齐到该枚举，禁止各模块自定义平行词汇表（impl-real-at 之前 `drivers.HANGUP_CAUSE_MAP` 与之偏离，本 change 一并修复）。

#### Scenario: 单一来源枚举内容

- **WHEN** 任何模块（modem-controller / engine / worker / scheduler）记录或匹配 hangup_cause
- **THEN** 字符串值 MUST 是 `HangupCause` 枚举成员之一：
  - **GSM-side**（modem-controller 翻译 URC / `+CEER` 时使用）：`no_answer` / `user_busy` / `network_out_of_order` / `temporary_failure` / `normal_clearing` / `call_rejected` / `user_hangup`
  - **应用层**（engine / scheduler 触发的程序化挂断）：`wrap_up_completed` / `silence_max_reached` / `marked_for_handoff` / `no_progress_timeout` / `manual_hangup`
- 新增 cause 字符串 MUST 先扩 `HangupCause` 枚举 + 同步走 spec 修订；MUST NOT 直接在 `HANGUP_CAUSE_MAP` 或其他映射表中引入未在枚举登记的值

#### Scenario: manual_hangup 不进入 retry-followup 重试逻辑

- **WHEN** worker 处理通话结束、决定是否触发重试
- **THEN** `hangup_cause = manual_hangup` 的通话 MUST NOT 进入重试队列（本端主动挂断意味着业务流程已经走完或已显式放弃）；retry-followup spec 的"可重试 cause"列表（`{no_answer, user_busy, network_out_of_order, temporary_failure}`）SHALL NOT 包含 `manual_hangup`
