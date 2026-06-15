## MODIFIED Requirements

### Requirement: 被打断自动重组开关 auto_restructure_on_interrupt

campaign SHALL 持有布尔开关 `auto_restructure_on_interrupt`（默认 `false`）。该开关 ON 时，engine SHALL 在门控 decider 对本轮**未命中任何显式 routing rule**（即 `decide()` 缺省落到 `continue` / fail-open）且同时满足下列**全部**条件时，把该缺省出口**改判为 `restructure(source=interrupt_remaining)`** 而非 continue：

1. `campaign.auto_restructure_on_interrupt` 为 ON；
2. campaign 配置了 `kind=restructure` 的 role_config（restructure slot 存在）；
3. 本轮 `session.interrupt_remaining_text` 非空（= 上一轮 main 被 barge-in 打断、引擎已捕获残留未送 TTS 文本）；
4. **主门控 referee 本轮输出的 category 等于保留类别 `restructure_gate_category`**（引擎默认 `"FILLER"`，语义为"无营养的插话 / 垫词 / 随口附和 / 口头催促"）。

第 4 条是本要求相对早期实现的**收紧**。早期 auto_restructure 把**所有**未命中显式规则、落到缺省 `continue` 的打断都改判 restructure，导致客户用**实质问题 / 反对**打断、却恰好没有对应显式 routing rule 命中时被错误重组（AI 顺着说完而不回答）。引入门控保留类别后，engine SHALL 仅在主门控判定本轮打断为 `restructure_gate_category`（无营养垫词）时才改判 restructure；主门控判定为其它任何 category（实质提问 / 反对 / 同意 / 普通继续）时 SHALL 不改判、按常规放行对话路由作答。`restructure_gate_category` 默认 `"FILLER"`，由引擎 `PipelineConfig` 持有（v1 不暴露为 campaign 列，未来可 promote 为 campaign 列）。engine 仍 MUST NOT 解释门控的其余枚举语义——它只把这**单一保留类别值**当作重组信号（语义上等价于一条隐式 `match==restructure_gate_category → restructure` 的开关，刻意**不**复活已删除的 restructure routing action）。

为让主门控能区分"客户主动开口的垫词"与"打断 AI 时的垫词"，engine SHALL 在调用主门控 referee 前，向其 prompt 注入两个由引擎填充的占位符：

- `{{was_interrupted}}`：值为"是"当且仅当本轮 `session.interrupt_remaining_text` 非空，否则为"否"；
- `{{interrupted_reply}}`：值为被打断、尚未说完的那句 AI 残句文本（`{{was_interrupted}}` 为"否"时为空串）。

门控 prompt 未含这两个占位符时，注入 SHALL 为 no-op（向后兼容存量 prompt）。占位符注入对 `session.interrupt_remaining_text` **只读不清**（清空由下方改判 / 清理路径负责）。`restructure_gate_category` 仅应在 `{{was_interrupted}}` 为"是"时被门控输出——此约束由门控 prompt 文本承担（prompt 层），并由下方引擎守卫兜底（即使门控在非打断轮误判 FILLER，因条件 3 残句为空，engine 亦 MUST NOT 改判 restructure）。

该改判 MUST 在 gate-first 门控**之后、`_select_gated_route` 之前**于 `decide()` 调用点完成；`decide()` SHALL 保持纯函数（MUST NOT 在 `decide()` 内读 session / 开关 / 门控 category / 合成假规则）。referee + 显式 routing rule + 门控保留类别三者共同构成本自动重组的 **veto**：任一显式 routing rule 命中（first-match-wins，如 `judge_reject=OPERATOR → tool:transfer`、`judge_intent=NEGATIVE → recovery`）SHALL 优先生效并否决自动重组；主门控判定为非 `restructure_gate_category` 时亦 SHALL 不触发自动重组。

**跨轮残句清理（不变量）**：当本轮 `session.interrupt_remaining_text` 非空、但 engine **未**把出口改判为 restructure（开关 OFF、无 restructure slot、或主门控判定为非 FILLER 的实质打断已正常作答）时，engine SHALL 在本轮结束前清空 `session.interrupt_remaining_text`，使该残句 MUST NOT 泄漏到后续轮次被误用于重组。改判 restructure 的路径仍由 `_assemble_interrupt_text` 的 take-and-clear 消费该字段，语义不变。

未配置 restructure slot 时开关 SHALL 无效（缺省仍走 continue），MUST NOT 报错。自动改判产生的 restructure 仍 SHALL 受 `max_continuous_restructure` 连续封顶约束（见 § 重组流连续触发封顶），与显式 restructure 走同一封顶逻辑。`auto_restructure_on_interrupt` 为 OFF（默认）时，decider 缺省行为 MUST 与本开关引入前逐字节一致。自动改判产生的 restructure 在 trace 上 SHALL 复用 `restructure_trigger="interrupt_remaining"`，MUST NOT 引入新 trigger 枚举值。

#### Scenario: 开关开启 + 被打断 + 主门控判 FILLER + 无显式规则命中 → 自动重组

- **WHEN** `auto_restructure_on_interrupt` 为 ON、campaign 有 restructure slot、上一轮 main 被 barge-in 打断使 `session.interrupt_remaining_text` 非空、主门控本轮输出 category 等于 `restructure_gate_category`（默认 FILLER），且本轮所有 referee 结果均未命中任何显式 routing rule（decider 本应缺省 continue）
- **THEN** engine SHALL 在 `decide()` 调用点把出口改判为 `DeciderAction(kind="restructure", source="interrupt_remaining")`，走 restructure route（then_state=LISTENING，referee-skipped），按 `interrupt_remaining` 取 `session.interrupt_remaining_text` 构造 InterruptText（取用后清空）

#### Scenario: 被打断但主门控判实质（非 FILLER）→ 不重组、正常作答、清空残句

- **WHEN** `auto_restructure_on_interrupt` 为 ON、有 restructure slot、`session.interrupt_remaining_text` 非空，但主门控本轮输出 category **不等于** `restructure_gate_category`（如客户打断时问价格 / 反对，门控判 continue / customer_decline 等实质类别）
- **THEN** engine MUST NOT 改判 restructure，SHALL 按常规放行对话路由（或命中的显式规则 route）正面作答；并 SHALL 在本轮结束前清空 `session.interrupt_remaining_text`（放弃被打断那句，避免跨轮污染）

#### Scenario: 门控注入打断占位符

- **WHEN** 主门控 prompt 含 `{{was_interrupted}}` / `{{interrupted_reply}}` 占位符
- **THEN** 本轮 `session.interrupt_remaining_text` 非空时 engine SHALL 把 `{{was_interrupted}}` 替换为"是"、`{{interrupted_reply}}` 替换为该残句文本后再调用门控；本轮 `interrupt_remaining_text` 为空时 SHALL 分别替换为"否" / 空串；prompt 未含这两个占位符时替换 SHALL 为 no-op，且替换过程 MUST NOT 清空 `session.interrupt_remaining_text`

#### Scenario: 显式 routing rule 命中否决自动重组

- **WHEN** `auto_restructure_on_interrupt` 为 ON 且 `interrupt_remaining_text` 非空，但某 referee 命中了显式 routing rule（如 `judge_intent=NEGATIVE → recovery` 或 `judge_reject=OPERATOR → tool:transfer`）
- **THEN** engine SHALL 按 first-match-wins 选中该显式规则的 route，MUST NOT 因开关改判为 restructure（显式规则 = veto，referee 仍是判官）

#### Scenario: 未配 restructure slot 时开关无效

- **WHEN** `auto_restructure_on_interrupt` 为 ON 但 campaign 无 `kind=restructure` role_config
- **THEN** decider 缺省 SHALL 仍走 continue（回 LISTENING），MUST NOT 报错，MUST NOT 产生 restructure route

#### Scenario: 无 barge-in 残留时开关不接管

- **WHEN** `auto_restructure_on_interrupt` 为 ON 但本轮 `session.interrupt_remaining_text` 为空（本轮未发生 barge-in，或残留已被取用清空）
- **THEN** decider 无命中时 SHALL 走 fail-open continue（回 LISTENING），MUST NOT 自动改判 restructure（即使主门控误输出 `restructure_gate_category`，因残留为空亦不触发）

#### Scenario: 开关关闭时行为不变

- **WHEN** `auto_restructure_on_interrupt` 为 OFF（默认）
- **THEN** 无论 `interrupt_remaining_text` 是否非空、无论主门控是否输出 `restructure_gate_category`，decider 无命中时 SHALL 走 fail-open continue（回 LISTENING），与本开关引入前逐字节一致

#### Scenario: 自动重组仍受连续封顶约束

- **WHEN** 开关开启致连续多轮自动 restructure，连续次数达到 `max_continuous_restructure`
- **THEN** engine SHALL 停止 restructure，改播 campaign default_replies 或按既有连续打断策略处置（与显式 restructure 走同一封顶逻辑）；连续计数在正常 main 回复后 SHALL 清零
