## MODIFIED Requirements

### Requirement: 简化管线（WRAPPING_UP）

进入 WRAPPING_UP 状态后管线 SHALL 简化为：**main LLM streaming**（取 Campaign 显式指定的 wrap_up main role_config，或缺省下用 main role）直出。引擎 **MUST NOT 门控收尾回复**——收尾风格回复一律照常播出，决不开口前等裁判。当 `campaign.wrap_up_referee_enabled=true` 时，引擎 **MAY** 在收尾回复**播出后**消费一个**非门控旁路收尾裁判**的结论（与回复并行运行的单个 referee，唯一动作是挂断）；该裁判结论 MUST 在回复成功播完（`played`）之后才消费，被客户打断（barge-in）时 MUST 丢弃该结论且 MUST 取消裁判任务。`wrap_up_referee_enabled=false`（默认）时 **MUST NOT 启动任何 referee**。无论是否启用，post-call extractor 仍正常运行（在 END 前 LPUSH 队列）。

#### Scenario: WRAPPING_UP 期间的 PROCESSING（裁判关闭，默认）

- **WHEN** WRAPPING_UP 状态用户说话触发 PROCESSING 且 `campaign.wrap_up_referee_enabled=false`
- **THEN** engine SHALL 调用 main LLM streaming + sentence → TTS；MUST NOT spawn referee；MUST NOT 写 referee_* 字段到 pipeline_trace

#### Scenario: WRAPPING_UP 期间的旁路收尾裁判（裁判开启）

- **WHEN** WRAPPING_UP 状态用户说话触发 PROCESSING 且 `campaign.wrap_up_referee_enabled=true`
- **THEN** engine SHALL 与收尾回复**并行**启动一个内建收尾裁判（引擎内建 prompt + 类别词汇，不进 routing_rules），收尾回复 MUST 照常播出、MUST NOT 被裁判门控或延迟
- **AND** engine SHALL 在收尾回复 `played` 后以 `wait_for(referee_timeout_ms)` 消费裁判结论，并把该结论写入本轮 pipeline_trace 的 `referee_results`
- **AND** 裁判输出落在挂断类别（`无问题`）时 engine SHALL 复用 `tool:hangup → END` 路径直接挂断（不再多播一句），否则 SHALL 落收尾计数器（`evaluate_wrap_up`）继续兜底
- **AND** 裁判超时 / 报错 / 空输出 时 engine MUST fail-open 视为非挂断（继续兜底），MUST NOT 因裁判异常而挂断
- **AND** 客户打断收尾回复（`not played`）时 engine MUST 取消裁判任务并 CONTINUE，MUST NOT 因裁判结论挂断
