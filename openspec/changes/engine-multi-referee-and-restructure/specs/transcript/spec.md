<!-- 与 data-model delta 同步：pipeline_trace_records 承载多 referee 结果 + restructure 命中记录。
     ai_reply 事件 payload 不变（restructure 输出聚合后仍作 ai_reply 文本对消费方透明）。 -->

## ADDED Requirements

### Requirement: pipeline_trace_records 多 referee 与 restructure 记录

engine 写入 `pipeline_trace_records` 的每轮记录 SHALL 承载 N 个 referee 结果（数组，每元素 `{label, category, confidence, duration_ms}`）而非单 referee 字段，并 SHALL 记录 `matched_rule`、`restructure_active`、`restructure_trigger`、`restructure_source_text`。写入 MUST 保持「不因 trace 失败影响主路径」（try/except 包裹，失败仅 ERROR 日志）。

#### Scenario: 多 referee 轮的 trace 记录

- **WHEN** 一轮 PROCESSING 跑了 N 个 referee 并由规则引擎决策
- **THEN** 该轮 pipeline_trace_records 记录 SHALL 含长度 N 的 referee 结果数组 + 命中的 `matched_rule`

#### Scenario: restructure 轮的 trace 记录

- **WHEN** 本轮命中 restructure action 并播出重组语句
- **THEN** 记录 SHALL 置 `restructure_active=true`、`restructure_trigger ∈ {last_reply, interrupt_remaining, low_confidence}`、`restructure_source_text` 为本轮 InterruptText

#### Scenario: restructure 输出对 ai_reply 事件透明

- **WHEN** restructure stream 播出后聚合文本
- **THEN** ai_reply 事件 payload 结构 MUST NOT 改变（`text` 字段照常承载本轮播出的聚合文本），对 transcript 消费方透明
