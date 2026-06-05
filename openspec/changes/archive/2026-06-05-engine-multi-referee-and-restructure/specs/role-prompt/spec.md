<!-- base spec 已含 § "referee prompt 内容规范"（单 referee、固定 4 decision 枚举）。
     本 delta 用 MODIFIED 把它扩为「每个 referee 独立 prompt + 独立闭集枚举（category）」；
     restructure/rewrite prompt 规范为全新内容，用 ADDED。 -->

## MODIFIED Requirements

### Requirement: referee prompt 内容规范

每个 `kind=referee` 的 role_config SHALL 拥有独立的 system prompt，prompt 内 MUST 显式定义该 referee 输出的闭集分类枚举（category 取值集合）及每个取值的语义。不同 referee 的枚举集合互不相关，engine 不解释其语义。referee prompt MUST 约束 LLM 输出严格 JSON `{category, confidence}` 且 `category` ∈ 该 prompt 定义的闭集，MUST 指示「只输出枚举集合内的一个 category，不得自创取值，不输出解释/markdown」。referee prompt 输入变量遵循既有约定（`{{user_last_utterance}}` + `{{recent_dialog_history}}`，渲染规则见下）。

#### Scenario: 单职责 referee prompt

- **WHEN** campaign 配置一个「拒绝识别」referee
- **THEN** 其 prompt SHALL 定义闭集如 `OFFENSIVE / REJECT / OPERATOR / NEUTRAL` 并逐项说明语义，要求 LLM 只输出其一
- **AND** 另一个「意图有效性」referee 的 prompt 独立定义 `POSITIVE / NEGATIVE`，两者枚举不共享

#### Scenario: referee prompt 强制闭集输出

- **WHEN** referee LLM 被调用
- **THEN** prompt MUST 指示「只输出枚举集合内的一个 category，不得自创取值，不输出解释/markdown」

#### Scenario: prompt 输入填充

- **WHEN** engine 调 referee LLM
- **THEN** engine MUST 替换 `{{user_last_utterance}}` 为最新 ASR 文本；MUST 替换 `{{recent_dialog_history}}` 为最近 ≤ 3 轮（少于 3 轮取全部）按 `用户：xxx / AI：xxx` 格式拼接

#### Scenario: dialog_history 为空

- **WHEN** session 处于首轮（dialog_history 为空 / 只有 greeting）
- **THEN** `{{recent_dialog_history}}` MUST 渲染为 `（首轮对话，无历史）` 占位字符串；MUST NOT 留空

## ADDED Requirements

### Requirement: restructure / rewrite prompt 内容规范

`kind=restructure` 的 role_config prompt SHALL 是「对话包装/重写」指令：把输入文本用更口语化的方式重新组织、可调整语序与用词、MUST NOT 改变原意与目的、SHOULD 在开头加自然过渡衔接词、MUST NOT 输出 markdown/emoji/解释。restructure prompt 的输入是 InterruptText（单条文本），prompt MUST NOT 假设能看到对话历史。

#### Scenario: restructure prompt 重组而不改意

- **WHEN** restructure LLM 收到 InterruptText（上一句 AI 要点或被打断残留）
- **THEN** prompt SHALL 指示「用口语化方式重新表达这句话，可换语序/用词、开头加过渡词，但不得更改含义或目的，直接输出结果」

#### Scenario: restructure prompt 不依赖历史

- **WHEN** 编写 restructure prompt
- **THEN** prompt MUST NOT 引用「对话历史」「用户上一句」等上下文变量，因 engine 只喂单条 InterruptText
