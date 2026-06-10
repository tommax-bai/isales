## Purpose

定义 isales-engine 单通通话的核心状态机：状态集合、转换规则、特殊状态（WRAPPING_UP、TRANSFERRING、ACTIVATING）的进入与退出条件。状态机 SHALL 是 engine 的核心，所有实时行为模块（打断、垫词、目标达成、转人工、沉默）都通过状态转换接入。
## Requirements
### Requirement: 状态集合

通话生命周期 SHALL 由 **4 个粗粒度可观测状态**构成（engine-tools-multidialogue-gating 将原 11 态「FSM-as-controller」枚举收缩为生命周期标签——扁平化做透）：

- `INIT` —— 拨号尝试中
- `IN_CALL` —— 通话进行中（接通后到结束 / 转人工之间的整个对话）
- `TRANSFERRING` —— 转人工流程（v1：播衔接话术 + 标记派发 + 主动挂断）
- `END` —— 通话结束

原 8 个细粒度阶段（`GREETING` / `LISTENING` / `SPEAKING` / `INTERRUPTED` / `FILLER` / `PROCESSING` / `WRAPPING_UP` / `ACTIVATING`）**不再是 `CallStatus` 成员**——它们降级为引擎内部的管线阶段 / 事件 / 标志（如 `session.in_wrap_up`），由角色 / 事件自行判断处理（见 ai-pipeline / goal-achievement / silence-activation specs）。其它 spec 中对这些名字的引用 SHALL 理解为**内部阶段**而非可观测状态；通话期间对外可观测 `CallStatus` 恒为 `IN_CALL`。`call_record.status` 为 `String(16)` 列（非 PG enum），收缩无需 DB 迁移；收缩前历史行中的旧值为可接受孤儿（v1 无生产数据）。

`LEGAL_TRANSITIONS` 收缩为：`INIT → {IN_CALL, END}`、`IN_CALL → {TRANSFERRING, END}`、`TRANSFERRING → {END}`、`END → {}`。`transition_to` SHALL **幂等**（`new_state == current` 时 no-op：不写 `state_history`、不改 `previous_state`、不发事件 / 告警）——使原本各自映射到同一 `IN_CALL` 的众多旧内部转移自然折叠为单次 `INIT → IN_CALL`。非法转移沿用已上线的 advisory 行为（写 `state_warning` + 继续，不抛 `IllegalTransition`，继承自 `call-state-machine-soften-guard`）。

#### Scenario: 状态机起始

- **WHEN** scheduler 派发新通话任务
- **THEN** engine SHALL 创建新 session，初始 state = `INIT`

#### Scenario: 接通进入通话

- **WHEN** modem-controller 上报 `connected` 事件
- **THEN** 状态 `INIT → IN_CALL`；engine SHALL 启动开场白（开场白是内部阶段，不再是 `CallStatus`）

#### Scenario: 内部阶段流转不改变可观测状态

- **WHEN** 通话期间 engine 在内部阶段间流转（监听 / 处理 / 说话 / 打断 / 收尾 / 沉默激活）
- **THEN** 对外可观测 `CallStatus` SHALL 恒为 `IN_CALL`（`transition_to(IN_CALL)` 幂等 no-op）；细粒度阶段经事件 / 标志 / transcript 表达，MUST NOT 产生额外 `CallStatus` 转换

#### Scenario: 幂等同态转移

- **WHEN** caller 调用 `transition_to(new_state)` 且 `new_state == current_state`
- **THEN** 状态机 SHALL no-op（不写 `state_history` / 不改 `previous_state` / 不发 `state_warning`）

#### Scenario: 非常规 transition 写 warning 但继续

- **WHEN** caller 调用 `transition_to(new_state)`，`new_state != current` 且 `new_state ∉ LEGAL_TRANSITIONS[current]`
- **THEN** 状态机 SHALL 写 `logger.warning("state_transition_unusual ...")` + 追加 `state_warning` transcript 事件 + 继续完成 transition；SHALL NOT 抛 `IllegalTransition`

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

### Requirement: 连续打断保护

engine SHALL 在 call_session 内维护连续打断计数器；当连续 INTERRUPTED → PROCESSING → SPEAKING → INTERRUPTED 循环超 `campaign.max_continuous_interruptions` 时 MUST 触发保护策略（详见 interruption-detection）。

#### Scenario: 完整轮次清零计数器

- **WHEN** 用户完成一轮无打断的 SPEAKING（即 SPEAKING TTS 完整播完未被打断）
- **THEN** 计数器 MUST 清零

### Requirement: FILLER 状态的并行性

FILLER 状态 SHALL 与 PROCESSING **并行**：垫词与 AI 管线同时启动，垫词播完后接管线 reply 的 TTS。FILLER 期间用户说话被判定为打断时 MUST 立即停垫词、丢弃当前 PROCESSING、把用户输入作为新一轮处理。

#### Scenario: 垫词期间被打断

- **WHEN** FILLER 状态 ASR 中间结果触发"打断"判定
- **THEN** engine MUST 停止垫词、终止当前 PROCESSING；状态 → PROCESSING（新一轮，使用新 ASR 终态结果）

### Requirement: WRAPPING_UP 期间走简化管线

WRAPPING_UP 状态（现为内部 `in_wrap_up` 标志）下任何 PROCESSING MUST 走简化管线（仅 main LLM 流式，跳过 referee），**MUST NOT 启用 PK / 裁判 / 垫词**（详见 ai-pipeline 与 filler）。

#### Scenario: WRAPPING_UP 期间用户提出新问题

- **WHEN** WRAPPING_UP 期间用户说话且不被识别为反悔/挂机
- **THEN** engine 走简化管线，状态在 WRAPPING_UP 内闭环（不退回主管线）

### Requirement: TRANSFERRING 状态的边界

TRANSFERRING 状态期间 engine MUST NOT 调用 AI 管线；MAY 保持 ASR 流式工作以补录最后一条 transcript。衔接话术播完后 SHALL 直接进入 END（v1 不存在转接成功 / 失败的二级分支，详见 human-handoff）。

#### Scenario: TRANSFERRING 期间 ASR 行为

- **WHEN** 衔接话术 TTS 播放中用户说话
- **THEN** ASR MAY 继续转录并写入 transcript；engine MUST NOT 因此中断衔接话术或调用 AI 管线

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

### Requirement: hangup_cause 单一来源

通话生命周期 hangup_cause 字段 SHALL 取值自 `isales_common.enums.HangupCause` 枚举；该枚举是**唯一权威**——modem-controller / engine / worker / retry-followup spec / call-state-machine spec 之间的 cause 字符串 MUST 全部对齐到该枚举，禁止各模块自定义平行词汇表（impl-real-at 之前 `drivers.HANGUP_CAUSE_MAP` 与之偏离，本 change 一并修复）。

#### Scenario: 单一来源枚举内容

- **WHEN** 任何模块（modem-controller / engine / worker / scheduler）记录或匹配 hangup_cause
- **THEN** 字符串值 MUST 是 `HangupCause` 枚举成员之一：
  - **GSM-side**（modem-controller 翻译 URC / `+CEER` 时使用）：`no_answer` / `user_busy` / `network_out_of_order` / `temporary_failure` / `normal_clearing` / `call_rejected` / `user_hangup`
  - **应用层**（engine / scheduler 触发的程序化挂断）：`wrap_up_completed` / `silence_max_reached` / `marked_for_handoff` / `no_progress_timeout` / `manual_hangup` / `referee_hangup`
- 新增 cause 字符串 MUST 先扩 `HangupCause` 枚举 + 同步走 spec 修订；MUST NOT 直接在 `HANGUP_CAUSE_MAP` 或其他映射表中引入未在枚举登记的值

#### Scenario: manual_hangup 不进入 retry-followup 重试逻辑

- **WHEN** worker 处理通话结束、决定是否触发重试
- **THEN** `hangup_cause = manual_hangup` 的通话 MUST NOT 进入重试队列（本端主动挂断意味着业务流程已经走完或已显式放弃）；retry-followup spec 的"可重试 cause"列表（`{no_answer, user_busy, network_out_of_order, temporary_failure}`）SHALL NOT 包含 `manual_hangup`

#### Scenario: referee_hangup 是应用层主动挂断 cause

- **WHEN** engine 经开口前门控选中 `tool:hangup` 主动结束通话
- **THEN** `session.hangup_cause` MUST 设为 `HangupCause.REFEREE_HANGUP`；该值属应用层程序化挂断，归类同 `marked_for_handoff` 等——不进入自动重拨（见 retry-followup spec § "REFEREE_HANGUP 归入不自动重拨终态"）；MUST NOT 出现在 GSM-side 远端 cause 集合

### Requirement: 非法 transition 改 advisory 警告

`transition_to()` 在 transition 不在 `LEGAL_TRANSITIONS[current]` 集合时 SHALL NOT 抛异常阻塞业务。状态机 SHALL 把"非常规 transition"作为 advisory 信号（warning log + transcript event），由 ops 或后续 review 处理；状态机本身 MUST 继续完成 transition 让业务流程不被打断。

**Rationale**: 通话场景的事件本质并发（user 说话 / AI 说话 / VAD / silence timer / 网络抖动同时到达），FSM 静态 LEGAL_TRANSITIONS 表难以穷举所有合法路径。2026-05-27 ~ 2026-06-02 累计 4 次因为静态表漏列导致 engine crash（详见 design.md § Context）。advisory 模式让状态机继续作为业务流程文档 + 可读性 + transcript 记录工具，但不阻塞业务执行。

#### Scenario: 非常规 transition 不抛异常

- **WHEN** caller 调用 `sm.transition_to(NEW_STATE, reason="...")`，且 `NEW_STATE ∉ LEGAL_TRANSITIONS[session.state]`
- **THEN** `transition_to` MUST 完成 `session.state = NEW_STATE` 赋值且 MUST NOT 抛 `IllegalTransition` 异常
- **AND** transcript 中 SHALL 追加 `{type: "state_warning", attempted: <reason>, from_state: <prev_state.value>, to_state: <NEW_STATE.value>}` 事件

#### Scenario: warning 日志可 grep

- **WHEN** 非常规 transition 发生
- **THEN** journalctl SHALL 含一行 `state_transition_unusual current=<from> new=<to> reason=<r>` 格式日志，便于 ops `grep state_transition_unusual` 监控架构 drift

#### Scenario: force=True 参数 backward-compat

- **WHEN** caller 显式传 `force=True`
- **THEN** 行为等价于不传或传 `force=False`——transition 都会执行，区别只在 force=True 不再有 "跳过 guard" 的额外效果（因为默认就不阻塞）
- **AND** 既有 22 处 `transition_to(...)` 调用方代码无需修改

### Requirement: state_error 事件名迁移到 state_warning

历史 transcript 中可能存在 `state_error` 事件（本 change 实施之前的真 IllegalTransition 抛出时写入）。本 change 实施之后 engine MUST 写 `state_warning` 事件名而非 `state_error`，以反映"advisory 警告"而非"业务错误"的语义降级。

#### Scenario: 新通话不再产生 state_error 事件

- **WHEN** 本 change 实施后，engine 处理任何通话
- **THEN** transcript 中 MUST NOT 出现 `type: "state_error"` 事件；非常规 transition 一律写 `type: "state_warning"`

#### Scenario: 历史数据兼容

- **WHEN** 查询历史 call_record transcript（本 change 实施之前的通话）
- **THEN** 历史 `state_error` 事件保留原貌（数据库不动），消费方 SHOULD 同时识别 `state_error`（历史）+ `state_warning`（新）两种 event 名

### Requirement: IllegalTransition 类保留但不再抛出

`IllegalTransition` 异常类 SHALL 保留在 `state_machine.py` 中（避免 import 错误），但 `transition_to()` MUST NOT 再抛出该异常。现有 4 处 `except IllegalTransition` handler 短期保留作 dead code，由 followup change 清理。

#### Scenario: IllegalTransition 类可被 import 但不会被抛出

- **WHEN** 任何代码 `from isales_engine.state_machine import IllegalTransition`
- **THEN** import SHALL 成功（类定义存在）
- **AND** 运行时 `transition_to()` SHALL NOT 抛该异常类的实例

#### Scenario: 既有 except 块不引发回归

- **WHEN** 既有 `except IllegalTransition` 块包裹 `transition_to` 调用
- **THEN** 这些块 SHALL 永远不被执行（dead code），但不影响业务逻辑——transition 通过 advisory 路径完成 + caller 拿到正常 return

### Requirement: StatusProjector 单写者投影状态

engine SHALL 以**单一同步写者**（`StateMachine.transition_to`）作为 `session.state` 的**唯一写者** + `StatusChanged` 的**唯一发射者**。各 route / 模块 MUST NOT 直接散写 `session.state`——它们只**声明 `then_state`**，由 gate-first 轮驱动（`_run_gated_turn`）据下表投影一次。

> 前置依赖：`LEGAL_TRANSITIONS` 的「非法转移 → advisory 警告（写 `state_warning`、不抛 `IllegalTransition`、继续）」已由 **change `call-state-machine-soften-guard`（engine commit 2cb47bc，已 archive）** 落地，本 change 不重复 advisory 降级，仅在该 advisory 模型之上引入单写者投影 + 4 态收缩（见本 delta § `状态集合`）。
>
> **实现取舍（crux2 对抗复核 + 4 态收缩后定稿）**：投影器**就是 `StateMachine` 本身作为同步唯一写者**，而非独立的 bus 订阅者——因为状态收缩为 4 态后 `transition_to` 幂等、转换平凡（`INIT→IN_CALL→[TRANSFERRING]→END`），「单写者」的本意（防止并发写竞争）由**同步调用 + 幂等**天然满足，无需异步订阅；异步 post + drain 反而会与 run_loop 的同步 `session.state` 读竞态 / 乱序（已被复核证伪）。barge-in 仍走 bus（`InterruptRequested`），但它不写 `CallStatus`（打断是内部阶段，恒 `IN_CALL`）。

投影映射 SHALL 为（4 态）：

| 事件 / route 活动 | 投影 `CallStatus` |
|---|---|
| Connected（接通） | `INIT → IN_CALL` |
| 通话内部阶段（处理 / 说话 / 打断 / 监听 / 沉默激活 / 收尾） | `IN_CALL`（恒定，`transition_to(IN_CALL)` 幂等 no-op；阶段经 `session.in_wrap_up` 等内部标志 + transcript 表达） |
| `tool:transfer`（then_state=TRANSFERRING） | `TRANSFERRING` |
| `tool:hangup` / `closing` 收尾耗尽 / 各类终结（then_state=END） | `END` |

`CallStatus` 枚举值（现 4 值 `{init, in_call, transferring, end}`）、transcript 事件词表（含 `state_warning`）、pipeline_trace、`call_record.status`（`String(16)`，二元 INIT→END 语义不变）、`EngineEvent` union、`CallEnded.hangup_cause` MUST 全部 wire 稳定（`CallStatus` 收缩本身是本 change 的对外契约变更，已同步 data-model / web-admin-ui / 各消费仓）。

#### Scenario: 单写者保证状态写序

- **WHEN** 同一轮内 route 完成与 barge-in 几乎同时发生
- **THEN** 仅同步唯一写者（`StateMachine.transition_to`）写 `session.state` + 发 `StatusChanged`；MUST NOT 出现两个写者竞争导致 `previous_state` / `state_history` 错乱；barge-in 经 bus 表达为内部打断阶段，MUST NOT 产生额外 `CallStatus` 转换（恒 `IN_CALL`）

#### Scenario: route 只声明 then_state 不直接写状态

- **WHEN** 被选 route 携带 `then_state`（closing/recovery/transfer/hangup）
- **THEN** route MUST NOT 散写 `session.state`；SHALL 仅声明 `then_state`，由 gate-first 轮据上表投影（`WRAPPING_UP→in_wrap_up` 内部标志 + `IN_CALL`；`recovery`/`main→IN_CALL` no-op；`transfer→TRANSFERRING`；`hangup→END`）

#### Scenario: 投影保持对外可观测序列

- **WHEN** api / web / transcript 消费 `session.state` 或 `StatusChanged`
- **THEN** flag-ON（gate-first）与 flag-OFF（legacy）投影出的 4 态 `CallStatus` 可见序列 MUST 一致（golden 双 flag 守卫）；MUST NOT 新增 / 删除 / 改名 4 态之外的任何 `CallStatus` 值

#### Scenario: 非常规投影沿用 advisory（不重复 soften-guard）

- **WHEN** 投影出的目标不在 `LEGAL_TRANSITIONS`（4 态）集合内
- **THEN** 沿用已上线的 advisory 行为（`transition_to` 写 `state_warning` + WARN 日志 + 继续）；本 change MUST NOT 重新引入 `IllegalTransition` 抛出或 `state_error` 事件名

## Implementation Notes

engine 的状态机模块 SHALL 实现为单进程内的有限状态机；每个 call_session 持有自己的状态实例。状态转换 MUST 通过统一的事件驱动 API（如 `session.transition_to(NEW_STATE, reason=...)`），便于 transcript 落事件和单元测试。
