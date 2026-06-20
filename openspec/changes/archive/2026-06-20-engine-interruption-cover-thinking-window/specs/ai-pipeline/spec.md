## ADDED Requirements

### Requirement: 思考窗口被打断（首音频释放前）

当 barge-in 在**思考窗口**（本轮 gate-first 回合已进入处理、`_await_referees` 门控等待 + eager 缓冲阶段，但 `_play_streaming` 尚未释放首个 TTS chunk）内被判定 `triggered`（判定核见 interruption-detection § "可组合规则树打断判定"）时，engine SHALL 中止本轮、把客户的待处理用户句合并后经 **main 管线（裁判门完整保留）** 重新生成一条回复。该窗口的中止 MUST 复用现有打断机制与拆除路径，MUST NOT 引入 final 级 watcher、第二分类器或 restructure 专用判定。

具体约束：

- engine SHALL 在首音频释放前的既有 await 边界（门控等待、首 chunk 释放前）观察**同一个** `session.interruption_signaled`；置位时 SHALL 调用既有 `_cancel_candidates()` / `cancel_eager()` 取消全部 eager 对话候选并取消未决门控 referee 任务（释放 vendor 连接），MUST NOT 释放本轮（第一句 A）的任何音频。
- 中止后 engine SHALL 返回主轮询循环，由既有 final coalesce（合并排队中的后续用户 final）将客户句作为新一轮 PROCESSING 输入，经 main 管线 + 完整裁判门（referee gate）重新门控生成——使裁判对"客户当前完整意图"（A 的上下文 + B 的最新句）重新判定 transfer / goal / hangup 路由。
- 思考窗口的中止 MUST NOT 捕获 `session.interrupt_remaining_text`、MUST NOT 触发 restructure：一字未播即无"被打断的半句"可续。由于 `interrupt_remaining_text` 恒为空，decider 的 restructure 缺省改判（§ "路由规则引擎（decider）" / § "被打断自动重组开关"）**可证地被跳过**，本轮恒走 main 管线"新回答"。播音中被打断 → 捕获余句 → restructure 的现有路径不受本要求影响、行为不变。
- 第一句 A MUST NOT 丢失：A 在进入回合前已由 `user_speech` 事件镜像进 `dialog_history`，故重答经 `build_main_messages` 天然带入 A 作为前序 user 轮，回复覆盖「A（上下文）+ 最新客户句」。
- 中止的本轮 SHALL 落一条 `pipeline_trace`（`interrupted=True`、`first_audio_ms=None`），与播音 barge-in 的 trace 对齐。
- 思考窗口中止 SHALL 计入连续打断保护（`consecutive_interruption_count += 1`，见 interruption-detection § "连续打断保护"）。
- 无第二句的常见回合 MUST NOT 因本要求付出额外延迟：守卫与门控竞速仅在 `interruption_signaled` 真正置位时改变控制流，正常路径（门控先返回）行为逐字节不变。

#### Scenario: 思考窗口被实质性第二句打断 → 取消候选、合并经 main 管线重答

- **WHEN** 客户说完第一句 A、本轮已 spawn eager 候选并在 `_await_referees` 门控/缓冲等待（首音频未释放），客户的第二句 B 经规则树判定 `triggered`
- **THEN** engine SHALL 取消全部 eager 候选 + 未决 referee 任务、MUST NOT 释放 A 的回复、返回主循环；既有 coalesce 把 B（及更晚到达的 final）合并为新一轮用户输入，经 main 管线 + 完整裁判门生成一条回复

#### Scenario: 思考窗口中止恒走新回答、永不进 restructure

- **WHEN** 思考窗口被打断而中止本轮
- **THEN** `session.interrupt_remaining_text` SHALL 保持为空（未开播、不捕获），decider 的 restructure 缺省改判 MUST 被跳过，本轮 MUST 经 main 管线"新回答"，MUST NOT 调用 restructure LLM

#### Scenario: 第一句 A 经 dialog_history 带入重答

- **WHEN** 思考窗口被打断、A 已在 `dialog_history`、重答轮经 `build_main_messages` 组装 messages
- **THEN** A SHALL 作为前序 user 轮出现在 messages 中，重答回复 SHALL 覆盖 A（上下文）+ 最新客户句；A MUST NOT 被丢弃或漏答

#### Scenario: 无第二句的回合不受影响（零额外开销）

- **WHEN** 本轮思考窗口内无 barge-in（`interruption_signaled` 未置位），门控 referee 正常返回
- **THEN** engine SHALL 按既有 gate-first 流程选路并释放音频，控制流与延迟逐字节不变；MUST NOT 因本要求引入额外等待

#### Scenario: 中止的本轮写 pipeline_trace

- **WHEN** 思考窗口被打断而中止本轮（未释放任何音频）
- **THEN** engine SHALL 落一条 `pipeline_trace` 记录该轮，标记 `interrupted=True`、`first_audio_ms=None`；MUST NOT 因写 trace 失败影响通话主路径
