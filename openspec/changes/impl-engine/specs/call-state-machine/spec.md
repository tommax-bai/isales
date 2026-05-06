## MODIFIED Requirements

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
