## Purpose

定义 isales-engine 单通通话的核心状态机：状态集合、转换规则、特殊状态（WRAPPING_UP、TRANSFERRING、ACTIVATING）的进入与退出条件。状态机 SHALL 是 engine 的核心，所有实时行为模块（打断、垫词、目标达成、转人工、沉默）都通过状态转换接入。
## Requirements
### Requirement: 状态集合

通话生命周期 SHALL 由以下状态构成：

- `INIT` —— 拨号尝试中
- `GREETING` —— 开场白播放
- `LISTENING` —— 等待用户说话
- `SPEAKING` —— TTS 播放 AI 回复
- `INTERRUPTED` —— 用户说话被判定为打断（短暂中转状态）
- `FILLER` —— 垫词播放
- `PROCESSING` —— AI 三层管线运行中
- `WRAPPING_UP` —— 目标达成后的收尾对话
- `ACTIVATING` —— 沉默激活话术播放
- `TRANSFERRING` —— 转人工流程（v1：播衔接话术 + 标记派发 + 主动挂断）
- `END` —— 通话结束

状态机 SHALL 维护合法转移集合 `LEGAL_TRANSITIONS: dict[CallState, set[CallState]]`；任何不属于当前状态合法转移集合的事件 MUST 抛 `IllegalTransition` 异常并在 transcript 中追加 `{type: "state_error", attempted: <event>, from_state: <current_state>}` 事件。本 Requirement 把"非法状态转移的兜底"从隐式约定提升为硬契约——这是 engine 内部状态机与运行时之间的契约，被前端 / 运维通过 transcript 调试时依赖。

#### Scenario: 状态机起始

- **WHEN** scheduler 派发新通话任务
- **THEN** call_session 起始状态 MUST 为 `INIT`

#### Scenario: 状态机终止

- **WHEN** 进入 `END`
- **THEN** engine SHALL 把 call_record 落 DB 并向 worker 派发"通话结束"消息；MUST NOT 再发生任何状态转换

#### Scenario: 非法转移抛异常并写 state_error

- **WHEN** 任何模块（filler / silence / transfer / orchestrator 等）触发的转移目标不在当前状态的 `LEGAL_TRANSITIONS` 集合内
- **THEN** 状态机 MUST 抛 `IllegalTransition`；CallSession MUST 在 full_transcript 中追加 `{type: "state_error", attempted: <event_name>, from_state: <current>, to_state: <intended>, ts: <relative_ms>}`

#### Scenario: 非法转移可恢复 vs 不可恢复

- **WHEN** 模块捕获 `IllegalTransition` 时判断"事件可忽略"（如 ASR partial 在 PROCESSING 期间）
- **THEN** 模块 SHALL 继续；状态机不改 state

- **WHEN** 模块判断"事件不可忽略"（如 PROCESSING 期间 telephony_client 心跳丢失）
- **THEN** 模块 MUST 强制进 `END(reason="engine_internal_error")`；通过 `transition_to(END, reason="engine_internal_error", force=True)` 跳过合法性校验

### Requirement: 关键状态转换

通话生命周期的所有状态转换 SHALL 由统一的事件触发；engine MUST 在每次转换时把对应事件追加到 transcript。

#### Scenario: 拨号成功进入开场白

- **WHEN** modem-controller 上报 `connected` 事件
- **THEN** 状态 INIT → GREETING；engine SHALL 启动开场白 TTS 播放

#### Scenario: 开场白完成进入监听

- **WHEN** GREETING 的 TTS 播放完毕
- **THEN** 状态 GREETING → LISTENING

#### Scenario: SPEAKING 期间打断进入处理

- **WHEN** SPEAKING 状态下用户说话被判定为打断（详见 interruption-detection）
- **THEN** 状态 SPEAKING → INTERRUPTED → PROCESSING；engine MUST 立刻停 TTS

#### Scenario: 用户正常说完进入处理

- **WHEN** LISTENING 状态下 ASR 上报 speech_end 且未达激活上限
- **THEN** 状态 LISTENING → PROCESSING；同时启动 FILLER（详见 filler 规范）

#### Scenario: 处理完成进入回复

- **WHEN** PROCESSING 完成且管线产出 reply（goal_achieved=false）
- **THEN** 状态 PROCESSING → SPEAKING；TTS 开始播放 reply

#### Scenario: 目标达成进入收尾

- **WHEN** PROCESSING 输出 `goal_achieved=true`
- **THEN** 状态 PROCESSING → SPEAKING（先正常播放当前轮 reply）→ WRAPPING_UP（详见 goal-achievement）

#### Scenario: 收尾结束

- **WHEN** WRAPPING_UP 的轮数计数器或时长计数器任一耗尽
- **THEN** engine 播放挂断话术后 → END (reason=`wrap_up_completed`)

#### Scenario: 沉默触发激活

- **WHEN** LISTENING 状态沉默时长 ≥ `campaign.silence_threshold_ms` 且未达激活上限
- **THEN** 状态 LISTENING → ACTIVATING（详见 silence-activation）

#### Scenario: 激活上限挂断

- **WHEN** 沉默触发但激活次数已达上限
- **THEN** engine 播放 `silence_hangup_phrase` → END (reason=`silence_max_reached`)

#### Scenario: 转人工触发

- **WHEN** 任一转人工触发条件命中（详见 human-handoff）
- **THEN** 状态 → TRANSFERRING；engine 播衔接话术 → 主动挂断 → END (reason=`marked_for_handoff`)

#### Scenario: 长时间无进展挂断

- **WHEN** 用户一直说但都被判定为非打断/无效内容超过 `campaign.max_no_progress_seconds`
- **THEN** engine 主动挂断 → END (reason=`no_progress_timeout`)

#### Scenario: 用户挂机

- **WHEN** modem-controller 上报 `remote_hangup` 事件
- **THEN** 状态 → END (reason=`user_hangup`)

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

WRAPPING_UP 状态下任何 PROCESSING MUST 走简化管线（单角色 LLM + 润色），**MUST NOT 启用 PK / 裁判 / 垫词**（详见 ai-pipeline 与 filler）。

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

## Implementation Notes

engine 的状态机模块 SHALL 实现为单进程内的有限状态机；每个 call_session 持有自己的状态实例。状态转换 MUST 通过统一的事件驱动 API（如 `session.transition_to(NEW_STATE, reason=...)`），便于 transcript 落事件和单元测试。
