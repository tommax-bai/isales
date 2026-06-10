## MODIFIED Requirements

### Requirement: 关键状态转换

通话的**对外可观测状态转换**SHALL 仅为 4 态生命周期：`INIT → IN_CALL`（接通）、`IN_CALL → TRANSFERRING`（转人工）、`IN_CALL → END` / `TRANSFERRING → END`（各类挂断）。通话内部的**对话阶段流转**（开场白 → 监听 → 处理 → 说话 → 打断 → 收尾 → 沉默激活）由事件 / 角色 / 标志驱动（engine-tools-multidialogue-gating 扁平化），不再是 `CallStatus` 转换；其行为细节见 ai-pipeline（门控管线）/ goal-achievement（收尾）/ silence-activation（沉默）/ human-handoff（转人工）/ interruption-detection（打断）specs。engine MUST 在每个对外状态转换及关键阶段事件时追加对应 transcript 事件。

#### Scenario: 接通进入通话

- **WHEN** modem-controller 上报 `connected`
- **THEN** `INIT → IN_CALL`；engine SHALL 启动开场白（内部阶段）

#### Scenario: 转人工

- **WHEN** 任一转人工触发命中（human-handoff 四触发路径 / 门控 `tool:transfer`）
- **THEN** `IN_CALL → TRANSFERRING`；engine 播衔接话术 → 主动挂断 → END (reason=`marked_for_handoff`)

#### Scenario: 收尾结束

- **WHEN** `session.in_wrap_up` 期间轮数 / 时长计数器任一耗尽
- **THEN** engine 播挂断话术 → END (reason=`wrap_up_completed`)

#### Scenario: 沉默激活上限挂断

- **WHEN** 沉默触发但激活次数已达上限
- **THEN** engine 播 `silence_hangup_phrase` → END (reason=`silence_max_reached`)

#### Scenario: 门控主动挂断

- **WHEN** 开口前门控选中 `tool:hangup`
- **THEN** engine 抑制本轮对话回复（可选先播 `closing_phrase`）→ END (reason=`referee_hangup`)

#### Scenario: 用户挂机

- **WHEN** modem-controller 上报远端挂断
- **THEN** `→ END` (reason=`user_hangup`)

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

- **WHEN** engine 主动调 `SerialATClient.hangup(call_id)`（如 goal 达成进入 WRAPPING_UP 后 TTS 播完）
- **THEN** 事件流将 yield `ATEvent("remote_hangup", call_id, cause="manual_hangup")`；engine 收到该事件时状态已经在 `END` 或 `WRAPPING_UP` → `END` 路径中；`manual_hangup` cause SHALL NOT 被状态机用作 `END.reason`（END reason 由触发 hangup 的业务理由决定，如 `wrap_up_completed` / `marked_for_handoff` / `referee_hangup`）
