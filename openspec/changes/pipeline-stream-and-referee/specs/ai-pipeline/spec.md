## MODIFIED Requirements

### Requirement: AI 管线编排

每一轮对话生成回复 SHALL 由两个 LLM 并行驱动：**main LLM** 流式输出纯文本回复（streaming token → sentence boundary → TTS chunk-fed）+ **referee LLM** 旁路输出决策枚举。MUST NOT 再使用 N-role PK / N×M judges / polish 三层串联架构（详细历史背景见本 change 的 design.md § Context）。

每一轮 PROCESSING 完成（无论 main 走完整流式 / 流式异常一次性 fallback / referee 超时 fail-open）MUST 落一条 `pipeline_trace` 记录到 DB（字段约束见 transcript spec）。MUST NOT 因写 pipeline_trace 失败影响通话主路径——写入 SHALL 用 try/except 包裹，失败仅 ERROR 日志。

连续打断保护（与 main streaming 兼容）：当 `session.consecutive_interruption_count >= campaign.max_continuous_interruptions` 时 engine SHALL 按 `campaign.continuous_interruption_strategy` 触发保护：

- `short_reply`：在调 main LLM 之前 set `PipelineConfig.short_reply_active=True`，prompt_builder 在 system prompt 末尾追加"请用一句话回应"段落
- `listen_only`：跳过 PROCESSING（不调 main / referee），engine SHALL 直接 TTS 播放短引导语后回 LISTENING；本轮不写 pipeline_trace

完整轮次（SPEAKING TTS 完整播完未被打断）后 engine MUST 把 `consecutive_interruption_count` 清零。

#### Scenario: main LLM 与 referee LLM 并行 spawn

- **WHEN** 进入 PROCESSING 状态
- **THEN** engine SHALL 用 `asyncio.create_task` 同时启动 main LLM streaming + referee LLM；MUST NOT 串行（referee 等 main 完）

#### Scenario: main LLM 流式 token → sentence → TTS

- **WHEN** main LLM 通过 `chat_stream` 返回 token AsyncIterator
- **THEN** engine SHALL 用 sentence boundary detector 切句（命中 `。？！` 或 `\n\n` 或累积超 50 字），每切完一句 MUST 立即喂给 TTS provider 的 `synthesize_stream` 接口；TTS 每输出 PCM chunk MUST 立即推到 RTC `audio_out`
- **AND** engine MUST NOT 等 main LLM 完整结束才开始 TTS

#### Scenario: 首音频延迟监控

- **WHEN** main LLM 第一个 sentence 产出 + TTS 首 PCM chunk 推到 RTC
- **THEN** engine MUST 在 pipeline_trace 写 `first_audio_ms` 字段（从 PROCESSING 入口到首 PCM chunk 时间差），用于上线后 SLA 监控

#### Scenario: referee 决策驱动状态机

- **WHEN** main TTS 播完（SPEAKING 状态退出准备转 LISTENING / WRAPPING_UP / TRANSFERRING / ACTIVATING）
- **THEN** engine SHALL `await asyncio.wait_for(referee_task, timeout=2.0)` 获取 referee 结果；根据 `decision` 字段：
  - `goal_achieved` → `sm.transition_to(WRAPPING_UP, reason=<goal_type>)`
  - `transfer` → `sm.transition_to(TRANSFERRING, reason="referee_decision")`
  - `customer_decline` → `sm.transition_to(ACTIVATING, reason="customer_decline_recovery")`
  - `continue` → `sm.transition_to(LISTENING, reason="tts_done")`

#### Scenario: referee 超时 fail-open

- **WHEN** referee LLM 调用超时（> 2.0s）或返回非法 JSON / confidence < 0.7
- **THEN** engine MUST 默认 `decision="continue"` 走 LISTENING；MUST NOT 阻塞通话；pipeline_trace 记录 `referee_decision="timeout"` 或 `"invalid"` 或 `"low_confidence"`

#### Scenario: main LLM streaming 异常一次性 fallback

- **WHEN** main LLM `chat_stream` 中途抛异常 / SSE 断流 / provider 超时
- **THEN** engine MAY 用 `chat()`（非流式）重试一次作为 fallback；fallback 成功 → 整段 reply 一次性 TTS + 落 pipeline_trace 标 `main_fallback_used=true`；fallback 失败 → 走 campaign 默认回复兜底（详见 § "main LLM 异常的默认回复兜底"）

> **fallback 移除 trigger**: 本 Requirement 的 chat() 一次性 fallback 是过渡期措施。streaming 链路 30 天 SLA ≥ 99.5% 后由 followup change `pipeline-remove-streaming-fallback` 删除。

#### Scenario: pipeline_trace 写入失败不影响通话

- **WHEN** END 时事务批量写 pipeline_trace 因 DB 短暂不可用而失败
- **THEN** engine MUST 重试 3 次（指数退避）后仍失败 → ERROR 日志、session 仍清理（DECR 并发 + LPUSH CallEnded）；MUST NOT 因 pipeline_trace 失败而阻塞 call_record / CallEnded 路径

#### Scenario: 连续打断保护 short_reply 策略

- **WHEN** `session.consecutive_interruption_count >= campaign.max_continuous_interruptions` 且 `campaign.continuous_interruption_strategy = "short_reply"`
- **THEN** engine SHALL 在调 main LLM 之前 set `PipelineConfig.short_reply_active=True`；prompt_builder 在 main system prompt 末尾追加"请用一句话回应"段落；main streaming + referee 照常运行；pipeline_trace 仍写

#### Scenario: 连续打断保护 listen_only 策略

- **WHEN** `session.consecutive_interruption_count >= campaign.max_continuous_interruptions` 且 `campaign.continuous_interruption_strategy = "listen_only"`
- **THEN** engine MUST NOT 调用任何 LLM；SHALL 直接 TTS 播放引导语后回 LISTENING；本轮 MUST NOT 写 pipeline_trace

#### Scenario: 完整 SPEAKING 后清零计数器

- **WHEN** SPEAKING 状态 TTS 完整播完且未被实时 partial 监听器触发打断
- **THEN** engine MUST 把 `session.consecutive_interruption_count` 重置为 0

### Requirement: 简化管线（WRAPPING_UP）

进入 WRAPPING_UP 状态后管线 SHALL 简化为：**main LLM streaming**（取 Campaign 显式指定的 wrap_up main role_config，或缺省下用 main role）直出，**MUST NOT 启动 referee**（WRAPPING_UP 状态机出口已经确定走 END，决策无意义）。post-call extractor 仍正常运行（在 END 前 LPUSH 队列）。

#### Scenario: WRAPPING_UP 期间的 PROCESSING

- **WHEN** WRAPPING_UP 状态用户说话触发 PROCESSING
- **THEN** engine SHALL 调用 main LLM streaming + sentence → TTS；MUST NOT spawn referee；MUST NOT 写 referee_* 字段到 pipeline_trace

### Requirement: 开场白不走管线

开场白（GREETING 状态的播放内容）MUST NOT 经过 referee 或 extractor，原因是内容可预期、合规性提前由 Campaign 创建者保证。

#### Scenario: 固定模板开场白

- **WHEN** Campaign 配置固定模板开场白
- **THEN** engine SHALL 直接 TTS 播放该模板，不调用任何 LLM

#### Scenario: LLM 生成开场白

- **WHEN** Campaign 配置 LLM 生成开场白
- **THEN** engine SHALL 调用 main LLM 生成（用 `chat` 非流式接口，因为开场白短）；直接 TTS；**MUST NOT 调 referee / extractor**

#### Scenario: 开场白记入对话历史

- **WHEN** 开场白播放完成
- **THEN** engine MUST 把开场白文本作为 `assistant` 角色追加到 dialog_history（参与后续轮次的 main LLM 上下文）

## ADDED Requirements

### Requirement: referee LLM 二级决策

referee LLM SHALL 在 PROCESSING 入口与 main LLM 并行 spawn，输入 `{user_last_utterance, recent_dialog_history}`（最近 ≤ 3 轮 user/assistant 对话），输出严格 JSON `{decision, goal_type, confidence}`。referee MUST 用 `chat(json_mode=True)`（非流式），便宜小模型（如 qwen-turbo / gpt-4o-mini / doubao-lite），典型延迟 ≤ 500ms。

#### Scenario: 输出 JSON schema

- **WHEN** referee LLM 完成调用
- **THEN** 输出 MUST 满足：
  ```json
  {
    "decision": "continue" | "goal_achieved" | "customer_decline" | "transfer",
    "goal_type": "appointment" | "sale" | "callback" | null,
    "confidence": 0.0~1.0
  }
  ```
- **AND** engine MUST 校验：`decision` ∈ 枚举值；`goal_type` 在 `decision="goal_achieved"` 时非空，其他情况 null；`confidence` ∈ [0, 1]

#### Scenario: 校验失败 fail-open

- **WHEN** referee 输出 JSON 校验失败（缺字段 / 枚举越界 / confidence 越界）
- **THEN** engine MUST 默认 `decision="continue"` + pipeline_trace 记录 `referee_decision="invalid"`；MUST NOT 抛异常阻塞通话

#### Scenario: confidence 阈值

- **WHEN** referee 返回 `confidence < 0.7`
- **THEN** engine MUST 默认 `decision="continue"`（不信任 referee 决策） + pipeline_trace 记录 `referee_decision="low_confidence"`，避免误触发 WRAPPING_UP / TRANSFERRING

### Requirement: post-call extractor 异步抽取

通话结束（engine 进入 END 状态之前）engine MUST LPUSH 一条任务到 Redis Queue `isales:extract`，载荷 = `{call_record_id, transcript_snapshot, extractor_role_config_id, extractor_prompt_version_id}`；worker 服务 SHALL 有独立 consumer BLPOP 该队列，调 LLM provider 跑结构化抽取，输出 `extracted: {...}` 后 UPDATE `call_record.extracted`。engine 与 extractor 完全解耦——engine 不等结果。

#### Scenario: engine LPUSH extract 任务

- **WHEN** call session 准备转 END 状态
- **THEN** engine MUST 在 call_summary_writer 同流程内 LPUSH 一条到 `isales:extract` 队列；payload schema 见上；MUST 同时 UPDATE `call_record.extract_status='pending'`

#### Scenario: worker BLPOP 处理

- **WHEN** worker 服务的 `post_call_extractor` consumer BLPOP 收到任务
- **THEN** worker SHALL 调 LLM provider 的 `chat(json_mode=True)`（不用 streaming），输入 = 完整 transcript_snapshot + extractor prompt；输出 = `{extracted: {...}}`；成功后 UPDATE `call_record SET extracted = <result>, extract_status = 'done'`

#### Scenario: extractor 失败处理

- **WHEN** worker extractor 失败（LLM provider 超时 / JSON 校验失败 / DB 写失败）
- **THEN** worker SHALL UPDATE `call_record SET extract_status = 'failed', extract_error = <reason>`；MUST NOT 无限重试（防雪崩）；ops 通过 SQL 查 `WHERE extract_status='failed'` 手工触发重跑

#### Scenario: extract_status 字段语义

- **WHEN** 查询 call_record 的提取状态
- **THEN** `extract_status` 字段 SHALL 取值 ∈ `{null (老数据 / 未提交), 'pending', 'done', 'failed'}`

### Requirement: main LLM 异常的默认回复兜底

main LLM streaming 主路径 + 非流式 fallback 都失败时，engine SHALL 走 Campaign 的默认回复兜底；MUST NOT 重试 LLM。

#### Scenario: 默认回复随机抽取

- **WHEN** main streaming + chat() fallback 都失败
- **THEN** engine SHALL 从 `campaign.default_replies` JSONB 数组中随机抽 1 条；用 TTS 一次性合成播放；transcript 追加 `{type: "default_reply_used", text: ..., reason: "main_llm_failed"}` 事件；pipeline_trace 记录 `main_reply_text=<default_reply>` + `error="main_streaming_and_fallback_failed"`

#### Scenario: 默认回复不影响 referee

- **WHEN** main 走默认回复路径
- **THEN** referee 仍正常 await 决策驱动状态机；engine MUST NOT 因 main 失败就跳过 referee

### Requirement: sentence boundary detector

engine SHALL 在 `streaming/sentence_splitter.py` 模块实装 sentence boundary 切分逻辑：累积 main LLM yield 的 token 到 buffer，命中下列条件之一时切一句送 TTS：

- 命中标点 `。？！` 或换行 `\n\n`
- buffer 累积超过 50 字（防单句过长，TTS 延迟回弹）
- stream 结束时 buffer 不空，整体作为末句 flush

#### Scenario: 中文标点切句

- **WHEN** main LLM yield token 累积成 "您好张总，请问周三上午方便吗？"
- **THEN** sentence_splitter SHALL 切成 ["您好张总，请问周三上午方便吗？"] 一句；命中 `？` 后立即返回；buffer 清空

#### Scenario: 50 字 cap

- **WHEN** main LLM 输出一段连续无标点的长文本（如 50 字未现 `。？！`）
- **THEN** sentence_splitter SHALL 在第 50 字处切句；MUST NOT 等到下一个标点

#### Scenario: stream 结束 flush

- **WHEN** main LLM `chat_stream` AsyncIterator 结束（StopAsyncIteration）且 buffer 不空
- **THEN** sentence_splitter SHALL 把 buffer 作为最后一句 yield；buffer 清空

## REMOVED Requirements

### Requirement: 润色选优 + 拟人化

**Reason**: 三层管线被双 LLM 架构替代。润色 LLM 的"选优"职责由 main streaming 单 prompt 调优 + system prompt 约束承担；"拟人化"由 main prompt 风格约束承担。

**Migration**: campaign 配置中 polish role 行需手工删除（alembic migration 自动删 `role_config WHERE kind='polish'`）；polish prompt 历史保留在 prompt_version 表（read-only），但本 change 完成后无业务消费。

### Requirement: 全部裁判否决的兜底

**Reason**: judge 层删除，"全部裁判否决"路径不再存在。main LLM 异常时的兜底由新 Requirement § "main LLM 异常的默认回复兜底" 覆盖。

**Migration**: campaign 的 `default_replies` JSONB 字段保留，只是触发条件从"all_judges_rejected"改为"main_streaming_and_fallback_failed"。

### Requirement: 润色失败的降级

**Reason**: polish layer 删除。

**Migration**: 无需迁移。原降级路径"取通过裁判的第一个候选"不再存在；本 change 用 main streaming + chat() 非流式 fallback 替代降级路径。

### Requirement: 角色 LLM JSON 解析失败的处理

**Reason**: main LLM 输出从 JSON 改为纯文本，不再有 JSON 解析步骤。referee LLM 仍 JSON Mode 但失败由 § "referee LLM 二级决策 / 校验失败 fail-open" Scenario 覆盖。

**Migration**: 无需迁移。原 `json_parser.parse_role_output` 函数删除。
