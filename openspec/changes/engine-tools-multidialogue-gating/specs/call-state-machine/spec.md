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

## ADDED Requirements

### Requirement: StatusProjector 单写者投影状态

> 前置依赖：`LEGAL_TRANSITIONS` 的「非法转移 → advisory 警告（写 `state_warning`、不抛 `IllegalTransition`、继续）」已由 **change `call-state-machine-soften-guard`（engine commit 2cb47bc，2026-06-02 已上线代码）** 落地，本 change **不重复** advisory 降级，仅在该 advisory 模型之上引入单写者投影。两 change 都不碰对方的 requirement（soften-guard 改 `状态集合`；本 change 改 `hangup_cause 单一来源` + 新增本节）——但 soften-guard MUST 先 archive，本节文字默认 `transition_to` 已是 advisory（写 `state_warning`）。

engine SHALL 用单一 `StatusProjector` EventBus 订阅者作为 `session.state` 的**唯一写者**（即**唯一调用 `transition_to()` 的订阅者**）、以及 `StatusChanged` 的**唯一发射者**。`StatusProjector` MUST 订阅在**串行化的无损车道**上（保证状态写入的全序，根治异步写序竞态）。各 route / 模块 MUST NOT 直接调用 `transition_to` / 写 `session.state`——它们只声明 `then_state` 或 post lifecycle 事件，由 `StatusProjector` 投影。投影映射 SHALL 为：

| 事件 / route 活动 | 投影 CallStatus |
|---|---|
| Connected | GREETING → LISTENING |
| AsrFinal + referees 门控中 | PROCESSING |
| dialogue route 首个音频 | SPEAKING |
| InterruptRequested | INTERRUPTED |
| `closing` route（then_state） | WRAPPING_UP |
| `recovery` route（then_state） | ACTIVATING |
| `tool:transfer`（then_state） | TRANSFERRING |
| `tool:hangup` / 终结 | END |

`CallStatus` 枚举值、transcript 事件词表（含 soften-guard 的 `state_warning`）、pipeline_trace、`call_record.status`（二元 INIT→END）、`EngineEvent` union、`CallEnded.hangup_cause` MUST 全部 wire 不变。

#### Scenario: 单写者保证状态写序

- **WHEN** 同一轮内 route 完成与 barge-in 几乎同时发生
- **THEN** 仅 `StatusProjector` 一个订阅者按无损车道串行顺序写 `session.state` + 发 `StatusChanged`；MUST NOT 出现两个写者竞争导致 `previous_state` / state_history 错乱；golden-transcript 网 MUST 断言 `StatusChanged` 序列

#### Scenario: route 只声明 then_state 不直接写状态

- **WHEN** 被选 route 携带 `then_state`（closing/recovery/transfer/hangup）
- **THEN** route MUST NOT 调用 `transition_to` 直接写状态；SHALL 仅声明 `then_state`，`StatusProjector` 据上表投影；api/web 观测到的状态序列 MUST 与 legacy 控制器一致

#### Scenario: 投影保持 CallStatus wire 契约

- **WHEN** api / web / transcript 消费 `session.state` 或 `StatusChanged`
- **THEN** 投影出的 `CallStatus` 枚举值集合、状态名、转移可见序列 MUST 与 legacy 控制器 byte-stable；MUST NOT 新增 / 删除 / 改名任何 `CallStatus` 值

#### Scenario: 非常规投影沿用 advisory（不重复 soften-guard）

- **WHEN** `StatusProjector` 投影出的目标不在 `LEGAL_TRANSITIONS` 集合内
- **THEN** 沿用已上线的 advisory 行为（`transition_to` 写 `state_warning` + WARN 日志 + 继续）；本 change MUST NOT 重新引入 `IllegalTransition` 抛出或 `state_error` 事件名（那是 soften-guard 已迁移走的旧 wire 事件）
