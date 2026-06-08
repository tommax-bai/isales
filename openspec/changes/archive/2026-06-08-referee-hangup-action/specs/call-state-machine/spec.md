## ADDED Requirements

### Requirement: 裁判驱动的主动挂断转移

当 decider 命中 `hangup` action 时，engine SHALL 驱动通话进入 `END` 终态，cause=`referee_hangup`。若 hangup action 携带非空 `closing_phrase`，engine SHALL 先经定值 TTS 播放该单句告别（不新增对话轮、不复用 WRAPPING_UP 的多轮收尾、不 spawn referee），随后进入 `END`；`closing_phrase` 为空时 SHALL 直接进入 `END`。该路径 MUST 有界（至多一句话术）。

#### Scenario: 配话术的主动挂断

- **WHEN** 命中 `{type: "hangup", closing_phrase: "感谢您的时间，再见"}`
- **THEN** engine SHALL 经定值 TTS 播放该句 → `sm.transition_to(END, reason="referee_hangup")` → 由 modem-controller / RTC 执行物理挂断
- **AND** 该过程 MUST NOT 进入 WRAPPING_UP、MUST NOT 触发新一轮 referee/main 调用

#### Scenario: 立即挂断（空话术）

- **WHEN** 命中 `{type: "hangup"}`（无 closing_phrase）
- **THEN** engine SHALL 立即 `sm.transition_to(END, reason="referee_hangup")`，不播放任何话术

#### Scenario: 话术播放期间对端先挂

- **WHEN** closing_phrase 尚在播放，但会话已检测到对端挂断 / RTC 链路已断
- **THEN** engine SHALL 跳过剩余话术、直接 finalize，cause 仍为 `referee_hangup`（除非已先记录 `user_hangup`）

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

#### Scenario: referee_hangup 不进入 retry-followup 重试逻辑

- **WHEN** worker 处理 `hangup_cause = referee_hangup` 的通话结束
- **THEN** 该通话 MUST NOT 进入重试队列（engine 依裁判判定主动结束，重拨与该决定矛盾）；`referee_hangup` SHALL NOT 出现在"可重试 cause"列表中，且**不在**跟进 cause 集合内（天然不进跟进队列），与 `manual_hangup` 行为一致
