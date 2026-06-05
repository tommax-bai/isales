<!-- base spec 已含 § "实时目标达成判定"（由单 referee 的 decision 字段触发）。
     本 delta 用 MODIFIED 改写为「由某 referee 的 category 输出 + 路由规则命中 goal_achieved action」触发。
     状态机转移逻辑不变；worker 不重判逻辑保留。 -->

## MODIFIED Requirements

### Requirement: 实时目标达成判定

目标达成判定 SHALL 由「某个 referee 输出的 category + 一条 action 为 `transition to=goal_achieved` 的 routing rule 命中」共同决定（替代原单 referee `decision="goal_achieved"` 字段）。`goal_type` SHALL 取自命中规则 action 的 `goal_type` 字段，而非 referee 输出。engine MUST 实时读取该命中驱动状态机进入 WRAPPING_UP；通话结束后 worker MUST NOT 再次判定 goal_achieved（仅 post-call extractor 抽取 `extracted` 字段入库，与 goal_achieved 判定无关）。

#### Scenario: 规则命中触发 WRAPPING_UP

- **WHEN** 某 referee 返回判定「已约到」的 category 且对应 routing rule action 为 `{type: transition, to: goal_achieved, goal_type: appointment}`
- **THEN** engine SHALL 在 main TTS 播完后 `sm.transition_to(WRAPPING_UP, reason="appointment")`
- **AND** `goal_type` MUST 取自规则 action 而非 referee 输出

#### Scenario: 多 referee 下目标判定优先级

- **WHEN** 多个 referee 同轮返回结果，且 routing_rules 中 goal_achieved 规则排在某 restructure 规则之前
- **THEN** engine SHALL 按 first-match-wins 执行 goal_achieved（先命中者生效），与规则数组顺序一致

#### Scenario: worker 不重复判定

- **WHEN** worker 处理通话结束消息
- **THEN** `summarize_call` 仅生成摘要并把通话过程中最后一次命中 goal_achieved 规则的 `goal_type` 写入 `call_summary`，MUST NOT 触发独立的目标判定 LLM 调用
- **AND** worker 的 `post_call_extractor` consumer 仅抽 `extracted` 字段，MUST NOT 重判 goal_achieved

#### Scenario: 目标定义仍在 prompt + 规则中，不固化 schema

- **WHEN** campaign 要新增一种目标类型
- **THEN** 创建者 SHALL 通过「在某 referee prompt 加判定语义 + 在 routing_rules 加一条 goal_achieved 规则（带新 goal_type）」实现，MUST NOT 需要 DB schema 变更
