## Why

通话正常结束后,`device.status` 卡在 `dialing` 不回 `idle`,该设备从此无法被 scheduler 再次派发——必须人工 `UPDATE device SET status='idle'` 才能复用。2026-06-06 真拨 13301035545(call_record #157,完整双向 AI 对话、`user_hangup` 干净收尾)实测复现:lead 已被 worker 正确推进到 `follow_up_exhausted`、modem 侧已 `NO CARRIER`→`AT+CPCMREG=0` 干净拆线,**唯独 device 状态没人写回**。

根因:**没有任何服务在通话结束时做事件驱动的 `device → idle` 复位**。scheduler 派单时写 `dialing`(`isales_scheduler/device_selection.py:96-100`)却没有对应的写回路径;engine `finalize_session` 持有 `device_id`(`isales_engine/call_session.py`)但 `CallEnded` 消息不带它、且引擎不碰 device;worker 拿不到 `device_id`;watchdog 只在 120s stale 后标 `OFFLINE` 从不回 `IDLE`。设备生命周期复位完全押在 edge 每 30s 的心跳 status 快照这一条 lossy 路径上——而该路径在 #157 全程未生效(device 通话期从没变 `in_call`、挂断后 2m40s 仍 `dialing`)。用"实时 / lossy OK"的健康快照作为离散生命周期转换(call ended → device free)的**唯一**驱动,是本 bug 的设计 smell。

## What Changes

- **新增专用消息 `DeviceReleased`**(`isales-common`:`device_id` + `call_record_id` + `ended_at`),专表"这台设备空了"。**不改 `CallEnded` 形状**(关注点分离 + 零 blast radius,理由见 design.md D2)。
- **新增 must-deliver Redis Queue 通道 `isales:device_reset`**:由**云端 engine** 在 `finalize_session`(任何结束原因都必然执行,`dial_consumer.py::_runner_with_finalize` 保证)LPUSH 一条 `DeviceReleased`。发起方在云端 → 即使 edge 崩溃/失联,device 仍被释放。
- **scheduler 新增 `device_reset_loop` 消费者**:消费 `isales:device_reset`,执行幂等 `UPDATE device SET status='idle' WHERE id=:device_id AND status IN ('dialing','in_call')`。复位归属 scheduler——它 own 设备选择与置 `dialing`,闭合"谁置谁清"的单一职责;worker 继续只 own lead 生命周期。
- **心跳回归 liveness-only**:device 复位从 lossy 的 30s 心跳快照路径迁出。edge 心跳 + `heartbeat_handler` 不再把 `DeviceHealth.status` apply 到 `device.status`(对齐 `device-hardware` spec「心跳 MUST 仅更 `last_seen_at`、MUST NOT 翻转 status」)。这是**减一层**(删错误载体)而非加兜底。
- **(可选,分期) watchdog 扩展**:对 engine 在 finalize 前崩溃这一独立失败域,`device_watchdog` 增加"`dialing`/`in_call` 且 `last_call_at` stale → 回 `idle`"(而非只 `offline`),带明确移除条件(见 design.md D4)。
- 复位为幂等(`WHERE status IN ('dialing','in_call')`),重复/乱序消息无副作用;离散转换由 must-deliver 队列驱动(主),watchdog 仅兜 engine-crash(独立失败域)——不引入"多层 fallback"。

## Capabilities

### New Capabilities
<!-- 无新增 capability;本变更跨现有 capability 修改行为与契约 -->

### Modified Capabilities
- `message-contract`: 「通道矩阵覆盖完整」的 v1 必有消息类增加 `DeviceReleased`(engine → scheduler queue:device_id + call_record_id + ended_at)。
- `service-communication`: 通道矩阵新增 `engine → scheduler` Redis Queue (`isales:device_reset`);明确"call ended → device idle 复位"走 must-deliver 队列、由云端 engine 发起,而非心跳快照。
- `device-hardware`: `device.status` 生命周期增加"通话结束由云端事件驱动 `→ idle` 复位、归属 scheduler"的要求;重申心跳 liveness-only(MUST NOT 翻 status),watchdog 扩展为 engine-crash 兜底。

## Impact

- **isales-common**: 新增 `DeviceReleased` 消息 schema(`schemas/messages/`);`CallEnded` 不动。新增类属非破坏性,按 `message-contract`「演进规则」MAY 不升 `schema_version`;仍需发版并更新 engine/scheduler 的 pin。
- **isales-engine**: `call_lifecycle.py::finalize_session` 末尾新增向 `isales:device_reset` 的 `DeviceReleased` LPUSH(从 `session.device_id` 取值);`settings.py` 增队列名配置。`CallEnded` 发送侧不动。
- **isales-scheduler**: 新增 `device_reset` 复位逻辑 + `device_reset_loop` 消费者 + 在 `main.py` task group 接线;`settings.py` 增队列名。
- **isales-engine + isales-telephony (edge)**: 把 device 复位从心跳路径迁出——`heartbeat_handler` 不再 apply `DeviceHealth.status` 到 `device.status`(回归 spec liveness-only)。落地节奏见 design.md Open Questions(与 A2 对齐)。
- **isales-worker (可选/分期)**: `device_watchdog` 增强——`dialing`/`in_call` + stale `last_call_at` → `idle`(engine-crash 兜底)。
- **部署**: 无新基础设施(复用既有 Redis);engine 与 scheduler 需同批发版以保证队列双方一致;`deploy/cloud/STATE.md` 不变(无拓扑变化)。
- **对齐**: 当前处于 `arch-cloud-edge-split` pivot,本变更针对 cloud-edge 拆分后的 device 状态同步模型;与 `joint-mvp-gate-13301035545` / `edge-modem-audio-out-recovery` 互不冲突(本变更专注 device 复位,不动音频面)。
- **优先级**: 非阻塞——真拨闭环已 PASS;这是运营/吞吐 gap(每通话后设备需手动复位才能复用)。
