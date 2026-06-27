## Context

`device.status` 生命周期当前由两类写者维护:
- **置忙**: scheduler 选号时 `device_selection.py:96-100` 写 `dialing`(对应 `device-hardware` spec「选 device API」「device 状态机」)。
- **复位/对账**: 历史 v1 单主机模型里,in-process modem-controller 直接走状态机把 `dialing → in_call → idle`;心跳按 `device-hardware` spec「modem-controller 心跳与失联探测」**只更 `last_seen_at`、MUST NOT 翻转 status**(spec line 234-235 明确禁止心跳隐式翻 status,理由是"避免半坏的进程心跳还在但实际不能拨打");watchdog 在 120s stale 后置 `offline`。

`arch-cloud-edge-split`(A2)把 modem-controller 推到边缘后,edge 不能直连云端 DB,改由 gRPC 上报。当前 edge 实现(`main_windows.py::_device_status_provider` + engine `heartbeat_handler.py:106-115`)**让心跳携带并 apply `DeviceHealth.status`**——这既偏离上述 spec 原则,又在 2026-06-06 真拨 #157 实测中**完全没生效**:device 通话期从没变 `in_call`、`user_hangup` 后 2m40s 仍 `dialing`(心跳 fresh 但状态没动)。

结果:cloud-edge 模型下,**没有任何可靠的离散事件把通话结束翻译成 `device → idle`**。`device-hardware` spec「device 状态机」的「挂断后 idle」语义在 cloud-edge 形态下没有落地的执行者。

## Goals / Non-Goals

**Goals:**
- 通话正常结束后,device 在秒级内事件驱动地从 `dialing`/`in_call` 复位为 `idle`,无需人工 SQL。
- 复位由"必须送达"的离散事件驱动,而非 lossy 的 30s 心跳快照。
- 复位即便 edge 崩溃/失联也能发生(由云端发起)。
- 职责单一:置忙者(scheduler)同时是复位者;心跳回归 spec 规定的 liveness-only。
- 幂等:重复/乱序的复位消息无副作用。

**Non-Goals:**
- 不修音频面、不动真拨闭环(#157 已 PASS)。
- 不实现 engine-crash-before-finalize 这一极端失败的强保证(留 watchdog 兜底,见 D4)。
- 不重做 A2 的心跳协议;只把 device 复位从心跳路径迁出。
- 不引入新基础设施(复用既有 Redis Queue)。

## Decisions

### D1: 复位由云端 engine 的 `finalize_session` 发起离散事件,不靠 edge 心跳
`isales-engine` 的 `finalize_session` 由 `dial_consumer.py::_runner_with_finalize` 保证**任何通话结束路径都必然执行**(user_hangup / silence / no_progress / manual / 异常)。在该处发出 device 复位事件,可覆盖所有结束原因,且**发起方在云端**——即使 edge 已崩溃/失联,device 仍被释放。
- 备选: 让 edge 在 NO CARRIER 时发 critical CallEvent 触发复位。否决——edge 可能崩溃就收不到 NO CARRIER 也就发不出;且把复位绑在边缘可靠性上,正是当前 bug 的来源。

### D2: 专用消息 `DeviceReleased` + 专用队列 `isales:device_reset`,不复用/不改 `CallEnded`
Redis Queue 单消费者独占(worker BRPOP `isales:call_ended`),scheduler 收不到同一条;故必须独立通道。承载用**新建最小消息** `DeviceReleased{device_id, call_record_id, ended_at, schema_version}`,而非给 `CallEnded` 加 `device_id` 再双写。
- 理由: ① 关注点分离——`CallEnded`=「处理这通的业务后果」(归 worker),`DeviceReleased`=「这台设备空了」(归 scheduler);② 零 blast radius——不动 `CallEnded` 形状,滚动发版时老 worker 不受影响(避免 `message-contract` spec「破坏性变更」升 schema_version 的连锁);③ 更小的 diff。
- 备选(给 `CallEnded` 加 `device_id` + 双 LPUSH 同一消息): 否决——过载单一消息类、触碰既有 consumer、违背单一关注点。

### D3: 复位归属 scheduler;心跳回归 liveness-only(对齐 device-hardware spec)
`isales-scheduler` 新增 `device_reset_loop` 消费 `isales:device_reset`,执行幂等
`UPDATE device SET status='idle' WHERE id=:device_id AND status IN ('dialing','in_call')`。
置忙者(scheduler)= 复位者,闭合「谁置谁清」。同时**把 device 复位从心跳路径移除**:edge 心跳 + `heartbeat_handler` 不再 apply `DeviceHealth.status` 到 `device.status`(回归 `device-hardware` spec「心跳 MUST 仅更 last_seen_at」)。
- 这不是"加一层兜底再修心跳",而是**把离散转换从错误的载体(lossy 心跳快照)搬到正确的载体(must-deliver 队列)**;心跳本就该 liveness-only。删掉心跳翻 status 这条错误路径 = 减一层,符合 root CLAUDE.md「多层 fallback 是坏味道」。

### D4: engine-crash-before-finalize 的兜底 = watchdog 扩展(独立失败域,可分期)
唯一绕过 D1 的失败是 engine 进程在 `finalize_session` 前崩溃 → 不发 `DeviceReleased`。这是与"正常结束"**不同的失败域**,用 watchdog 兜底不算多层 fallback:扩展 `isales_worker/device_watchdog.py`,对 `status IN ('dialing','in_call') AND last_call_at < now() - <max_call_duration + margin>` 的行回 `idle`(而非只 `offline`)。带明确移除条件:若未来 engine session 有云端 lease/租约自动到期,则此兜底可删。本兜底 MAY 在本 change 内实现,也 MAY 拆后续;主路径 D1-D3 是 must。

### D5: 队列命名与序列化
沿用 spec 既有 `isales:` 前缀约定 → `isales:device_reset`(注:代码侧既有 `isales:call_ended` 在实现里是 `engine:worker:call-ended`,属既存 spec/code drift,本 change 不顺手修,只在 tasks 备注);payload JSON,经 isales-common 的 `DeviceReleased` Pydantic 类(`message-contract` spec「消息基类与版本字段」)。

## Risks / Trade-offs

- **[与 A2 心跳-status 行为冲突]** 当前 edge/engine 心跳已携带并 apply status;D3 要移除该 apply。→ Mitigation: 作为 Open Question 与 A2 owner 对齐;迁移期可先上线 D1-D3 的事件驱动复位(authoritative),心跳 apply 暂留为幂等 corroboration(只允许翻成 idle、且禁止翻动有 active engine session 的 device),稳定后再删心跳 apply,避免一次性大改。
- **[engine 与 scheduler 发版不同步]** 队列双方需契约一致(新消息类在 isales-common,二者都 pin)。→ Mitigation: isales-common 先发版 + bump,engine/scheduler 同批升 pin;`DeviceReleased` 是新增类(非破坏既有),老 scheduler 无该 loop 时消息积压在队列、不丢(must-deliver),升级后被消费。
- **[幂等/乱序]** 复位 WHERE 守卫 `status IN ('dialing','in_call')`,对已 `idle`/`offline`/`flagged` 的行不动 → 重复消费、与 watchdog 竞争都安全。
- **[device_id 来源]** engine `CallSession.device_id` 须在 finalize 时可得且正确(对照 DialRequest.device_id 链路)。→ Mitigation: tasks 含一步核对 device_id 全链路一致(scheduler 选号 → DialRequest → CallSession → DeviceReleased)。

## Migration Plan

1. isales-common: 新增 `DeviceReleased` schema,发版 + bump。
2. isales-engine: pin 新 common;`finalize_session` 末尾 LPUSH `DeviceReleased`;不改 `CallEnded`。
3. isales-scheduler: pin 新 common;新增 `device_reset` 逻辑 + `device_reset_loop` + main.py 接线。
4. 部署 engine + scheduler(同批);冒烟:真拨一通 → 挂断 → 秒级内 `device.status='idle'`,无需手动 SQL。
5. (分期可选)D3 心跳 apply 退场 + D4 watchdog 扩展。
6. 回滚: engine 停发 `DeviceReleased`(device 复位退回手工/watchdog),scheduler loop 空转无害;无 schema 破坏,可独立回滚任一服务。

## Open Questions

- 与 `arch-cloud-edge-split` 对齐: edge 心跳是否彻底不再携带/apply `device.status`?还是迁移期保留为幂等 corroboration?(影响 D3 落地节奏)
- `isales:call_ended` 的 spec(`isales:call_ended`)与 code(`engine:worker:call-ended`)命名 drift 是否在本 change 一并修正,还是另开?(本 change 默认不修,只备注)
- D4 watchdog 的 `max_call_duration + margin` 阈值取值(campaign 级 `wrap_up_max_seconds` + `silence` 预算推导,还是全局常量?)。
