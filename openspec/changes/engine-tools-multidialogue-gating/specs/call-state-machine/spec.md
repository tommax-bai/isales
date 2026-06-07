## MODIFIED Requirements

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

#### Scenario: 长时间无进展挂断

- **WHEN** 无效内容持续超过 `campaign.max_no_progress_seconds`
- **THEN** engine 主动挂断 → END (reason=`no_progress_timeout`)

#### Scenario: 用户挂机

- **WHEN** modem-controller 上报远端挂断
- **THEN** `→ END` (reason=`user_hangup`)

### Requirement: WRAPPING_UP 期间走简化管线

WRAPPING_UP 状态（现为内部 `in_wrap_up` 标志）下任何 PROCESSING MUST 走简化管线（仅 main LLM 流式，跳过 referee），**MUST NOT 启用 PK / 裁判 / 垫词**（详见 ai-pipeline 与 filler）。

#### Scenario: WRAPPING_UP 期间用户提出新问题

- **WHEN** WRAPPING_UP 期间用户说话且不被识别为反悔/挂机
- **THEN** engine 走简化管线，状态在 WRAPPING_UP 内闭环（不退回主管线）

## ADDED Requirements

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
