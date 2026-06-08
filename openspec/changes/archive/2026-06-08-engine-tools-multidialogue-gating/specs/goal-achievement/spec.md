## MODIFIED Requirements

### Requirement: 实时目标达成判定

目标达成判定 SHALL 由「某个 referee 输出的 category + 一条 action 命中 `closing` route（或 legacy `transition to=goal_achieved`，经 shim 映射为 `closing` route）」共同决定（替代原单 referee `decision="goal_achieved"` 字段）。`goal_type` SHALL 取自命中规则 action 的 `goal_type` 字段，而非 referee 输出。判定发生在**开口前门控**：门控选中 `closing` route → 播放收尾风格回复（MainSpec + 收尾追加）→ 由其 `then_state=WRAPPING_UP` 经 StatusProjector 投影进 WRAPPING_UP；engine MUST NOT 在 route 内直接 `sm.transition_to`。通话结束后 worker MUST NOT 再次判定 goal_achieved（仅 post-call extractor 抽取 `extracted` 字段入库，与 goal_achieved 判定无关）。

#### Scenario: 规则命中选 closing route 投影 WRAPPING_UP

- **WHEN** 某 referee 返回判定「已约到」的 category 且对应 routing rule action 为 `{type: route, to: closing, then_state: WRAPPING_UP}`（或 legacy `{type: transition, to: goal_achieved, goal_type: appointment}` 经 shim 映射为 closing route）
- **THEN** engine SHALL 由门控选中 `closing` route 放行收尾风格回复，其 `then_state=WRAPPING_UP` 经 StatusProjector 投影进 WRAPPING_UP；MUST NOT 在 route/decider 内直接 `sm.transition_to`
- **AND** `goal_type` MUST 取自规则 action 而非 referee 输出

#### Scenario: 多 referee 下目标判定优先级

- **WHEN** 多个 referee 同轮返回结果，且 routing_rules 中 goal_achieved/closing 规则排在某 restructure 规则之前
- **THEN** engine SHALL 按 first-match-wins 选 closing route（先命中者生效），与规则数组顺序一致

#### Scenario: worker 不重复判定

- **WHEN** worker 处理通话结束消息
- **THEN** `summarize_call` 仅生成摘要并把通话过程中最后一次命中 goal_achieved/closing 规则的 `goal_type` 写入 `call_summary`，MUST NOT 触发独立的目标判定 LLM 调用
- **AND** worker 的 `post_call_extractor` consumer 仅抽 `extracted` 字段，MUST NOT 重判 goal_achieved

#### Scenario: 目标定义仍在 prompt + 规则中，不固化 schema

- **WHEN** campaign 要新增一种目标类型
- **THEN** 创建者 SHALL 通过「在某 referee prompt 加判定语义 + 在 routing_rules 加一条 closing route 规则（带新 goal_type）」实现，MUST NOT 需要 DB schema 变更

### Requirement: 进入 WRAPPING_UP 状态

当门控选中 `closing` route（goal_achieved 软结局）时，engine SHALL 放行该 route 的收尾风格回复，并由其 `then_state=WRAPPING_UP` 经 StatusProjector 投影进 WRAPPING_UP 状态，MUST 切换 prompt 与简化管线。因门控在**开口前**裁决，被选 `closing` route 的回复**就是**本轮播出的回复——不存在"先播 main 回复再转移"的二段，故无需 hold referee 到 SPEAKING 结束。

#### Scenario: closing route 的回复即本轮回复

- **WHEN** 门控选中 `closing` route
- **THEN** engine SHALL 放行 closing route 的收尾风格回复（MainSpec + 收尾追加）作为本轮 TTS 播出；`then_state=WRAPPING_UP` 投影状态；MUST NOT 另起一段 main 回复，MUST NOT 中途打断已放行的 closing 回复

#### Scenario: 门控裁决先于音频

- **WHEN** referee 门控比对话首句预合成更早完成（典型情况，referee 输入短）
- **THEN** engine 在释放音频前即完成选路（closing vs main vs 其它）；MUST NOT 出现"先放 main 音频又要回退转 WRAPPING_UP"的旧时序竞态

#### Scenario: 切换到简化管线

- **WHEN** 进入 WRAPPING_UP 后用户说话触发新一轮 PROCESSING
- **THEN** 后续轮次 MUST 走简化管线（仅 main LLM streaming，跳 referee）；详见 `ai-pipeline` spec § "简化管线（WRAPPING_UP）"

#### Scenario: prompt 末尾追加收尾指令

- **WHEN** 在 WRAPPING_UP 状态调用 main LLM
- **THEN** engine MUST 在原 main system prompt 末尾追加「目标已达成。请简短确认或告别后结束对话，不要再尝试推进新议题」段落，原 prompt 内容保持不变（详见 `role-prompt` spec § "收尾期间在 system prompt 末尾追加指令"）
