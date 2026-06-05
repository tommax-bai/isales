## Purpose

定义 AI 双 LLM 流式管线：每一轮对话由 **main LLM 流式输出纯文本回复**（token → 句界 → TTS chunk）+ **referee LLM 旁路输出决策枚举** 并行驱动，通话结束后由 **post-call extractor** 异步抽取结构化字段。本规范覆盖管线编排、流式与一次性 fallback、referee fail-open、pipeline_trace 落库契约。旧的 N 角色 PK → N×M 裁判 → 1 润色三层串联架构已废弃（背景见 archived change `pipeline-stream-and-referee`）。
## Requirements
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

### Requirement: 简化管线（WRAPPING_UP）

进入 WRAPPING_UP 状态后管线 SHALL 简化为：**main LLM streaming**（取 Campaign 显式指定的 wrap_up main role_config，或缺省下用 main role）直出，**MUST NOT 启动 referee**（WRAPPING_UP 状态机出口已经确定走 END，决策无意义）。post-call extractor 仍正常运行（在 END 前 LPUSH 队列）。

#### Scenario: WRAPPING_UP 期间的 PROCESSING

- **WHEN** WRAPPING_UP 状态用户说话触发 PROCESSING
- **THEN** engine SHALL 调用 main LLM streaming + sentence → TTS；MUST NOT spawn referee；MUST NOT 写 referee_* 字段到 pipeline_trace

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

### Requirement: referee LLM 二级决策

每一轮 PROCESSING SHALL 支持 N 个（N ≥ 1）referee LLM 并行决策（替代原单 referee）。engine MUST 在 PROCESSING 入口用 `asyncio.gather` 同时 spawn 所有 enabled 的 `kind=referee` role_config，与 main LLM streaming 并行，MUST NOT 串行或互相等待，MUST NOT 因等待任一 referee 阻塞 main 主链路。每个 referee 拥有独立 system prompt、独立输出分类枚举语义、独立 fail-open，engine MUST NOT 硬编码任何 referee 的枚举值。referee 调用 MUST 用 `chat(json_mode=True)`（非流式），便宜小模型（如 qwen-turbo / gpt-4o-mini / doubao-lite），典型延迟 ≤ 500ms。referee 的输出契约见 § "referee 输出契约（category + confidence）"，下游消费见 § "路由规则引擎（decider）"。

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

### Requirement: referee 输出契约（category + confidence）

每个 referee LLM SHALL 输出严格 JSON `{category, confidence}`，其中 `category` 是该 referee prompt 自定义的分类字符串（闭集枚举，语义由 prompt 定义），`confidence ∈ [0, 1]`。engine MUST NOT 在 referee 输出中要求 `goal_type`——`goal_type` 由路由规则的 `goal_achieved` action 携带（见 § 路由规则引擎）。此契约替代原单 referee 的 `{decision, goal_type, confidence}` 强语义输出。

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

## Data Schema

| 字段 / 表 | 用途 |
|---|---|
| `campaign.default_replies` (JSONB) | 全部裁判否决时的兜底话术池，随机抽 1 |
| `role_config` | N 个角色 + M 个裁判 + 1 个润色的元配置（model, temperature, top_p, prompt_version 引用） |
| `pipeline_trace` | 每轮管线的候选、裁判结果、润色输入输出（详见 transcript 规范） |

### Requirement: 引擎按 campaign 指定音色合成

引擎合成所有播音（开场白 + 主链路回复 + 固定话术）时 SHALL 使用 campaign 指定的音色。`campaign.voice_id` 持有 vendor speaker 字符串（如 `zh_female_xiaohe_uranus_bigtts`，由管理员在场景表单直接填写），引擎 MUST 将其原样传给 TTS provider 作为 speaker。`campaign.voice_id` 为 NULL / 空串时 MUST 回落到 provider 的默认 speaker，MUST NOT 让整通电话失败。

#### Scenario: 指定音色被真实通话消费

- **WHEN** campaign 的 `voice_id` 为一个非空 vendor speaker 串并发起通话
- **THEN** 引擎 MUST 用该串作为 TTS speaker 合成播音，使真实通话的发音与 web 端「试听」一致

#### Scenario: 未指定音色回落默认

- **WHEN** campaign 的 `voice_id` 为 NULL 或空串
- **THEN** 引擎 MUST 用 provider 默认 speaker 合成，通话正常进行，MUST NOT 抛错中断
