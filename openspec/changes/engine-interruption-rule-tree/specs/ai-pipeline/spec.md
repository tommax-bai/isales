## RENAMED Requirements

- FROM: `### Requirement: 重组流三触发场景的 InterruptText 来源`
- TO: `### Requirement: 重组流触发场景的 InterruptText 来源`

## MODIFIED Requirements

### Requirement: 重组流触发场景的 InterruptText 来源

engine SHALL 按命中规则的 `source` 字段构造 restructure 的 InterruptText，对应两个产品场景：

- `source="last_reply"`（用户没接住）→ InterruptText = 上一轮 AI 回复（dialog_history 最后一条 assistant utterance）；
- `source="interrupt_remaining"`（barge-in 重说）→ InterruptText = 被打断时 main 残留未送 TTS 的句子文本。

`restructure_trigger` 取值集 SHALL 仅含上述两类来源对应的标记，MUST NOT 含 `low_confidence`——原"主裁判低置信兜底 → restructure" 内置分支已删除（该分支因 referee 输出契约把 bare-token referee 的 `confidence` 固定为 1.0 而恒不触发，是死代码；见 change `engine-interruption-rule-tree`）。无任何 routing rule 命中时 engine SHALL 走 fail-open continue（回 LISTENING），MUST NOT 因低置信触发 restructure。

#### Scenario: 用户没接住 → 复述上一句

- **WHEN** 某 referee 判用户输入无意义（如返回 NEGATIVE）且规则 action 为 `restructure source=last_reply`
- **THEN** engine SHALL 取 dialog_history 末条 assistant utterance 作为 InterruptText，口语化重说

#### Scenario: barge-in 残留捕获后重说

- **WHEN** 上一轮用户 barge-in 打断 main，engine 捕获了 `interrupt_remaining_text`，本轮规则 action 为 `restructure source=interrupt_remaining`
- **THEN** engine SHALL 取 `interrupt_remaining_text` 作为 InterruptText 重组成顺畅一句补上；取用后 MUST 清空该字段
- **AND** 若 `interrupt_remaining_text` 为空，restructure SHALL 退化为复述 last_reply

#### Scenario: 主裁判低置信不再触发 restructure

- **WHEN** 所有 routing_rules 均未命中（含主裁判返回的 category 未匹配任何规则）
- **THEN** engine SHALL 走 fail-open continue（回 LISTENING），MUST NOT 因 referee confidence 走任何内置 restructure 兜底；MUST NOT 产生 `restructure_trigger="low_confidence"` 的 trace
