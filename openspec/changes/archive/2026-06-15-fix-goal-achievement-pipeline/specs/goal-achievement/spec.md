## MODIFIED Requirements

### Requirement: 实时目标达成判定

目标达成判定 SHALL 由「某个 referee 输出的 category + 一条 action 命中 `closing` route（或 legacy `transition to=goal_achieved`，经 shim 映射为 `closing` route）」共同决定（替代原单 referee `decision="goal_achieved"` 字段）。`goal_type` SHALL 取自命中规则 action 的 `goal_type` 字段，而非 referee 输出；该提取 MUST 对 `route` 与 legacy `transition` 两种 action 形态对称——engine MUST NOT 仅对 `transition` 提取 `goal_type` 而在 `route` 形态丢弃它。判定发生在**开口前门控**：门控选中 `closing` route → 播放收尾风格回复（MainSpec + 收尾追加）→ 由其 `then_state=WRAPPING_UP` 经 StatusProjector 投影进 WRAPPING_UP；engine MUST NOT 在 route 内直接 `sm.transition_to`。通话结束后 worker MUST NOT 再次判定 goal_achieved（仅 post-call extractor 抽取 `extracted` 字段入库，与 goal_achieved 判定无关）；worker 读取 goal 标记 SHALL 以 transcript 中的规范事件类型 `ai_reply`（及达成里程碑 `goal_achieved` 事件）为唯一来源。

#### Scenario: 规则命中选 closing route 投影 WRAPPING_UP

- **WHEN** 某 referee 返回判定「已约到」的 category 且对应 routing rule action 为 `{type: route, to: closing, then_state: WRAPPING_UP}`（或 legacy `{type: transition, to: goal_achieved, goal_type: appointment}` 经 shim 映射为 closing route）
- **THEN** engine SHALL 由门控选中 `closing` route 放行收尾风格回复，其 `then_state=WRAPPING_UP` 经 StatusProjector 投影进 WRAPPING_UP；MUST NOT 在 route/decider 内直接 `sm.transition_to`
- **AND** `goal_type` MUST 取自规则 action 而非 referee 输出

#### Scenario: route 与 transition 动作的 goal_type 提取对称

- **WHEN** 命中规则的 action 为 `{type: route, to: closing, goal_type: X}`（modern 形态）
- **THEN** engine 的规则决策层（decider）MUST 从该 action 提取 `goal_type=X` 并沿门控选路一路透传，使最终 `goal_achieved` 事件携带 `goal_type=X`
- **AND** 该提取行为 MUST 与 legacy `{type: transition, to: goal_achieved, goal_type: X}` 形态产生一致结果，MUST NOT 出现「`transition` 携带 `goal_type` 而 `route` 丢弃为空」的不对称

#### Scenario: 多 referee 下目标判定优先级

- **WHEN** 多个 referee 同轮返回结果，且 routing_rules 中 goal_achieved/closing 规则排在某 restructure 规则之前
- **THEN** engine SHALL 按 first-match-wins 选 closing route（先命中者生效），与规则数组顺序一致

#### Scenario: worker 不重复判定

- **WHEN** worker 处理通话结束消息
- **THEN** `summarize_call` 仅生成摘要并把通话过程中最后一次命中 goal_achieved/closing 规则的 `goal_type` 写入 `call_summary`，MUST NOT 触发独立的目标判定 LLM 调用
- **AND** worker 的 `post_call_extractor` consumer 仅抽 `extracted` 字段，MUST NOT 重判 goal_achieved

#### Scenario: worker 从 ai_reply 事件读取 goal 标记

- **WHEN** worker 的 `summarize_call`（及其 provider）从 transcript 读取 `goal_achieved` / `goal_type` / `extracted` 结构化标记
- **THEN** 消费方 MUST 从规范事件类型 `ai_reply`（携带这些字段，见 `transcript` spec § 事件类型枚举）读取——取倒序最近一条携带该标记的 `ai_reply` 事件；达成轮另写的独立 `goal_achieved` 里程碑事件亦为合法来源
- **AND** 消费方 MUST NOT 依据已废弃的 `bot_speech` 事件名读取（该事件名在 `2026-06-10-fix-transcript-schema-drift` 后引擎不再产出，transcript 事件枚举中亦无此类型）；读不到标记时 MUST fail-safe 视为未达成（`goal_achieved=false`）而非报错
- **AND** 摘要正文拼接 SHALL 同样以 `ai_reply` 作为 AI 侧话语来源，MUST NOT 因事件名不匹配而丢失 AI 回复文本

#### Scenario: 目标定义仍在 prompt + 规则中，不固化 schema

- **WHEN** campaign 要新增一种目标类型
- **THEN** 创建者 SHALL 通过「在某 referee prompt 加判定语义 + 在 routing_rules 加一条 closing route 规则（带新 goal_type）」实现，MUST NOT 需要 DB schema 变更
