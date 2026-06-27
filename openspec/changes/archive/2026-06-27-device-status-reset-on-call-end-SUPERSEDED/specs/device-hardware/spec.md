## ADDED Requirements

### Requirement: 通话结束后 device 由云端事件驱动复位为 idle

cloud-edge 形态下，`device.status` 从 `dialing`/`in_call` 复位为 `idle` SHALL 由**云端发起的离散 must-deliver 事件**驱动，而非边缘心跳的 status 快照。具体：engine 的 `finalize_session`（任何结束原因都必然执行）SHALL 发出 `DeviceReleased`（见 `message-contract` / `service-communication` spec 的 `isales:device_reset` 通道）；scheduler SHALL 消费并复位该 device。复位归属 scheduler——它是置 `dialing` 的同一方（闭合「device 状态机」中 `dialing → in_call → idle` 的 `→ idle` 段在 cloud-edge 下的执行者）。

#### Scenario: 正常通话结束复位

- **WHEN** 一通通话以任何原因结束（user_hangup / silence_max_reached / no_progress_timeout / manual_hangup / 异常），engine `finalize_session` 执行
- **THEN** engine MUST 向 `isales:device_reset` LPUSH 一条 `DeviceReleased{device_id, call_record_id, ended_at}`
- **AND** scheduler 消费后 MUST 把该 device 从 `dialing`/`in_call` 置回 `idle`，使其可被下一轮派发选中
- **AND** 全程 MUST NOT 需要人工 SQL 干预

#### Scenario: 复位即便 edge 崩溃/失联也发生

- **WHEN** edge 在通话结束前后崩溃或与云端断链，未能上报 NO CARRIER / 心跳
- **THEN** 因复位由**云端 engine** 发起，`DeviceReleased` 仍 MUST 被发出并复位 device；device 复位 MUST NOT 依赖 edge 的可达性

#### Scenario: 心跳不承担 device 复位（liveness-only）

- **WHEN** 云端处理来自 edge 的心跳
- **THEN** 心跳 MUST 仅更新 `last_seen_at`（与「modem-controller 心跳与失联探测」一致）；MUST NOT 把心跳携带的 `DeviceHealth.status` 隐式 apply 翻转 `device.status`
- **AND** 理由：以"实时、lossy OK"的健康快照驱动离散生命周期转换不可靠（实证：device 通话期未变 `in_call`、挂断后长时间仍 `dialing`），且违背"避免半坏进程心跳还在但实际不能拨打"的原则

#### Scenario: 复位幂等

- **WHEN** scheduler 收到针对同一 device 的重复或乱序 `DeviceReleased`
- **THEN** 复位 SHALL 用守卫 `WHERE status IN ('dialing','in_call')`；对已 `idle`/`offline`/`flagged` 的行 MUST NOT 改动

#### Scenario: engine 崩溃在 finalize 前的兜底（可分期）

- **WHEN** engine 进程在 `finalize_session` 执行前崩溃，未发出 `DeviceReleased`，device 滞留 `dialing`/`in_call`
- **THEN** watchdog SHOULD 将 `status IN ('dialing','in_call') AND last_call_at` 超过（最大通话时长 + 余量）阈值的 device 行置回 `idle`（而非只 `offline`）；该兜底覆盖的是与"正常结束"不同的失败域（engine 崩溃），并带明确移除条件（若未来 engine session 引入云端租约自动到期，则此兜底可删）
