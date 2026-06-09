<!-- engine-gate-supervision-rename: rename referee→门控监管 in role-prompt prose; fix stale role-cardinality scenario (门控监管 MAY N≥0, persona MAY N); 门控监管 prompt 只输出单个 bare category token（删 JSON {category,confidence}）且 MUST NOT 含 pass/hold/放行 决策动词（决策属门控路由）。 -->

## MODIFIED Requirements

### Requirement: Prompt 由 Campaign 完全自定义

所有 LLM 的 prompt 内容 SHALL 由 Campaign 完全控制，系统 MUST NOT 提供"统一门控监管规则"或"统一 extractor prompt"。系统 SHALL 仅提供工具与模板（v2 Web UI 可视化）。三类 LLM（main / 门控监管 `kind='referee'` / extractor）的 prompt MUST 各自独立。

#### Scenario: main / 门控监管 / extractor 全部自定义

- **WHEN** Campaign 创建者编辑 LLM prompt
- **THEN** main LLM、门控监管 LLM（`kind='referee'`）、extractor LLM 三类 prompt MUST 全部由 Campaign 自由编写；系统 MUST NOT 强加统一前缀或后缀（除收尾追加段落，详见下文）

#### Scenario: campaign 只配置 1 个 main role

- **WHEN** Campaign 配置 role
- **THEN** main role MUST 恰好 1 个；门控监管（`kind='referee'`）MAY 配置 N 个（N≥0，多个门控监管并行执行）；persona role MAY 配置 N 个（N≥0）；extractor MUST 恰好 1 个

### Requirement: referee prompt 内容规范

每个 `kind='referee'` 的 role_config（门控监管）SHALL 拥有独立的 system prompt，prompt 内 MUST 显式定义该门控监管输出的闭集分类枚举（category 取值集合）及每个取值的语义。不同门控监管的枚举集合互不相关，engine 不解释其语义、MUST NOT 硬编码任何枚举值。门控监管 prompt MUST 约束 LLM 只输出闭集枚举里的一个 category 词（bare token，无 JSON、无 confidence、无标点），且 `category` ∈ 该 prompt 定义的闭集，MUST 指示「只输出枚举集合内的一个 category，不得自创取值，不输出解释/markdown」。门控监管 prompt MUST NOT 含 pass/hold/放行 等放行决策动词——release/route/tool 决策由门控路由（routing_rules + `decide()`）裁定，门控监管 LLM 是纯分类器只产出 category。门控监管 prompt 输入变量遵循既有约定（`{{user_last_utterance}}` + `{{recent_dialog_history}}`，渲染规则见下）。

#### Scenario: 单职责门控监管 prompt

- **WHEN** campaign 配置一个「拒绝识别」门控监管
- **THEN** 其 prompt SHALL 定义闭集如 `OFFENSIVE / REJECT / OPERATOR / NEUTRAL` 并逐项说明语义，要求 LLM 只输出其一
- **AND** 另一个「意图有效性」门控监管的 prompt 独立定义 `POSITIVE / NEGATIVE`，两者枚举不共享

#### Scenario: 门控监管 prompt 强制闭集输出

- **WHEN** 门控监管 LLM 被调用
- **THEN** prompt MUST 指示「只输出枚举集合内的一个 category 词（bare token），不得自创取值，不输出 JSON / confidence / 解释 / markdown / 标点」
- **AND** prompt MUST NOT 含 pass/hold/放行 等放行决策动词（这些属门控路由 `decide()`，不属门控监管 LLM）

#### Scenario: prompt 输入填充

- **WHEN** engine 调门控监管 LLM
- **THEN** engine MUST 替换 `{{user_last_utterance}}` 为最新 ASR 文本；MUST 替换 `{{recent_dialog_history}}` 为最近 ≤ 3 轮（少于 3 轮取全部）按 `用户：xxx / AI：xxx` 格式拼接

#### Scenario: dialog_history 为空

- **WHEN** session 处于首轮（dialog_history 为空 / 只有 greeting）
- **THEN** `{{recent_dialog_history}}` MUST 渲染为 `（首轮对话，无历史）` 占位字符串；MUST NOT 留空
