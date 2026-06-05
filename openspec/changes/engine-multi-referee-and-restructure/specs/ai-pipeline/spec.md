<!-- 本 delta 叠在 active change `pipeline-stream-and-referee` 引入的「main 流式 + 单 referee 旁路决策」之上。
     下列 ADDED Requirements 把「单 referee」升级为「多 referee 并行 + 路由规则引擎」并新增「重组流」，
     supersede pipeline-stream-and-referee 的 § "referee LLM 二级决策" 单 referee 行为。
     实施顺序见 design.md Migration Plan：pipeline-stream-and-referee 先 archive，再实施本 change。 -->

## ADDED Requirements

### Requirement: 多 referee 并行决策

每一轮 PROCESSING SHALL 支持 N 个（N ≥ 1）referee LLM 并行决策（替代单 referee）。engine MUST 在 PROCESSING 入口用 `asyncio.gather` 同时 spawn 所有 enabled 的 `kind=referee` role_config，与 main LLM streaming 并行，MUST NOT 串行或互相等待。每个 referee 独立 system prompt、独立输出分类枚举语义、独立 fail-open，engine MUST NOT 硬编码任何 referee 的枚举值。

#### Scenario: N 个 referee 并行 spawn

- **WHEN** 进入 PROCESSING 状态且 campaign 配置了 N 个 enabled referee
- **THEN** engine SHALL `asyncio.gather` 并行启动全部 N 个 referee LLM 调用 + main LLM streaming
- **AND** main LLM streaming → sentence → TTS 主链路 MUST NOT 因等待任一 referee 而阻塞

#### Scenario: 单 referee 向后兼容

- **WHEN** campaign 仅配置 1 个 referee（pipeline-stream-and-referee 现状）
- **THEN** 行为 SHALL 等价于单 referee + 一组内置默认路由规则；已有 campaign MUST NOT 因本 change 改变决策行为

#### Scenario: 个别 referee fail-open

- **WHEN** 某个 referee LLM 超时 / 返回非法输出 / confidence < 阈值
- **THEN** engine MUST 将该 referee 视为「无 category 输出」（不命中任何规则），MUST NOT 抛异常阻塞通话，其他 referee 结果照常参与决策

### Requirement: referee 输出契约（category + confidence）

每个 referee LLM SHALL 输出严格 JSON `{category, confidence}`，其中 `category` 是该 referee prompt 自定义的分类字符串（闭集枚举，语义由 prompt 定义），`confidence ∈ [0, 1]`。engine MUST NOT 在 referee 输出中要求 `goal_type`——`goal_type` 由路由规则的 `goal_achieved` action 携带（见 § 路由规则引擎）。

#### Scenario: referee 输出被规则引擎消费

- **WHEN** 某 referee 返回 `{category: "NEGATIVE", confidence: 0.9}`
- **THEN** engine SHALL 以 `{<referee_label>: "NEGATIVE"}` 形式喂给路由规则引擎做匹配
- **AND** engine MUST NOT 对 category 字符串施加 engine 侧语义解释

#### Scenario: referee 输出校验失败

- **WHEN** referee 输出缺字段 / confidence 越界 / 非法 JSON
- **THEN** engine MUST fail-open：该 referee 视为无 category 输出；pipeline_trace 记录该 referee 的 `category="invalid"` 或 `"timeout"` 或 `"low_confidence"`

### Requirement: 路由规则引擎（decider）

engine SHALL 在所有 referee 返回后，按 campaign 配置的有序 `routing_rules` 列表逐条匹配，**第一个命中的规则即生效**（first-match-wins），执行其 action 后停止匹配。无任何规则命中时 SHALL 默认 `continue`（回 LISTENING）。每条规则绑定一个 referee（按 label）+ 匹配值集合 + 一个 action。

#### Scenario: 规则级联匹配，第一个命中即生效

- **WHEN** referee 结果为 `{judge_intent: "NEGATIVE", judge_reject: "OPERATOR"}` 且 routing_rules 顺序为 [规则A 绑 judge_reject 匹配 OPERATOR → transfer, 规则B 绑 judge_intent 匹配 NEGATIVE → restructure]
- **THEN** engine SHALL 执行规则A 的 transfer action 并停止匹配，MUST NOT 再执行规则B

#### Scenario: action 类型 — 状态转移

- **WHEN** 命中规则的 action 为 `{type: "transition", to: "goal_achieved", goal_type: "appointment"}`
- **THEN** engine SHALL `sm.transition_to(WRAPPING_UP, reason="appointment")`，与现有 referee 驱动状态机逻辑一致
- **AND** action 为 `to: "transfer"` → `_perform_handoff(trigger_type="referee_decision")`；`to: "customer_decline"` → 现有 customer_decline 处置

#### Scenario: action 类型 — 切重组流

- **WHEN** 命中规则的 action 为 `{type: "restructure", source: "last_reply" | "interrupt_remaining"}`
- **THEN** engine SHALL 走重组流（见 § 重组流），按 source 构造 InterruptText

#### Scenario: 无命中默认 continue

- **WHEN** 所有 routing_rules 均未命中（含全部 referee fail-open）
- **THEN** engine SHALL 默认回 LISTENING（continue），MUST NOT 误触发任何状态转移

### Requirement: 重组流 restructure

campaign MAY 配置一条 `kind=restructure` 的 role_config。当路由规则命中 restructure action 时，engine SHALL 调用 restructure LLM，输入为 `{system: restructure_prompt, user: InterruptText}`——**MUST NOT 携带 dialog_history、MUST NOT 携带用户最新一句**——输出仍走 streaming → sentence → TTS。restructure 跑完 SHALL 直接回 LISTENING，MUST NOT 再过 referee（避免自循环 + 多余延迟）。未配置 restructure 时，restructure action SHALL 退化为 continue。

#### Scenario: restructure 输入只含 InterruptText

- **WHEN** 命中 restructure action 且 InterruptText 非空
- **THEN** restructure LLM 调用 messages SHALL 仅为 `[{role: system, content: restructure_prompt}, {role: user, content: InterruptText}]`
- **AND** engine MUST NOT 在该调用中注入 dialog_history 或用户最新 utterance

#### Scenario: restructure 跑完不再过 referee

- **WHEN** restructure stream TTS 播放完成
- **THEN** engine SHALL 直接转回 LISTENING；MUST NOT spawn referee；MUST NOT 写 referee_* trace 字段（仅写 restructure_* 字段）

#### Scenario: 未配置 restructure 时退化

- **WHEN** 命中 restructure action 但 campaign 无 `kind=restructure` role_config
- **THEN** engine SHALL 退化为 continue（回 LISTENING），MUST NOT 报错

### Requirement: 重组流三触发场景的 InterruptText 来源

engine SHALL 按命中规则的 `source` 字段构造 restructure 的 InterruptText，对应三个产品场景：

- `source="last_reply"`（用户没接住 / 主裁判低置信兜底）→ InterruptText = 上一轮 AI 回复（dialog_history 最后一条 assistant utterance）；
- `source="interrupt_remaining"`（barge-in 重说）→ InterruptText = 被打断时 main 残留未送 TTS 的句子文本。

#### Scenario: 用户没接住 → 复述上一句

- **WHEN** 某 referee 判用户输入无意义（如返回 NEGATIVE）且规则 action 为 `restructure source=last_reply`
- **THEN** engine SHALL 取 dialog_history 末条 assistant utterance 作为 InterruptText，口语化重说

#### Scenario: barge-in 残留捕获后重说

- **WHEN** 上一轮用户 barge-in 打断 main，engine 捕获了 `interrupt_remaining_text`，本轮规则 action 为 `restructure source=interrupt_remaining`
- **THEN** engine SHALL 取 `interrupt_remaining_text` 作为 InterruptText 重组成顺畅一句补上；取用后 MUST 清空该字段
- **AND** 若 `interrupt_remaining_text` 为空，restructure SHALL 退化为复述 last_reply

#### Scenario: 主裁判低置信兜底 → 复述拖一轮

- **WHEN** 被标记为 primary 的 referee `confidence < 阈值`，且配置了低置信 restructure 规则
- **THEN** engine SHALL 走 `restructure source=last_reply` 口语化复述上一句，等下一轮再判定；MUST NOT 静默 continue（替换 pipeline-stream-and-referee 的低置信静默分支）

### Requirement: 重组流连续触发封顶

为避免连续 restructure 让 AI 显得复读，engine SHALL 用计数器对连续 restructure 触发封顶（默认上限可由 campaign 配置）。超过上限时 SHALL 不再 restructure，改走 default_replies 或既有 continuous-interruption 处置。

#### Scenario: 连续 restructure 超限改走兜底

- **WHEN** 同一通话连续 restructure 次数达到 `max_continuous_restructure`
- **THEN** engine SHALL 停止 restructure，改播 campaign default_replies 或按既有连续打断策略处置；连续计数在正常 main 回复后 SHALL 清零
