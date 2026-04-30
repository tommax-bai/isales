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

#### Scenario: 状态机起始

- **WHEN** scheduler 派发新通话任务
- **THEN** call_session 起始状态 MUST 为 `INIT`

#### Scenario: 状态机终止

- **WHEN** 进入 `END`
- **THEN** engine SHALL 把 call_record 落 DB 并向 worker 派发"通话结束"消息；MUST NOT 再发生任何状态转换

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

## Implementation Notes

engine 的状态机模块 SHALL 实现为单进程内的有限状态机；每个 call_session 持有自己的状态实例。状态转换 MUST 通过统一的事件驱动 API（如 `session.transition_to(NEW_STATE, reason=...)`），便于 transcript 落事件和单元测试。
