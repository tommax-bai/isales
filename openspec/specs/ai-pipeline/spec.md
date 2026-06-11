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

每一轮对话生成回复 SHALL 由两个 LLM 并行驱动：**main LLM**（以及任何 opt-in 的 persona 对话路由）流式输出纯文本回复（streaming token → sentence boundary → TTS chunk-fed）+ **referee LLM** 旁路输出决策枚举。referee 由**开口后判定**改为**开口前门控（gating）**：对话路由 eager 推测起跑、缓冲首句，referee 作为 eval_fn 在**释放任何音频之前**裁决放行哪一条路由（详见 § "SelectRouter 路由分发、开口前门控与 then_state"）。MUST NOT 再使用 N-role PK / N×M judges / polish 三层串联架构（详细历史背景见本 change 的 design.md § Context）。

每一轮 PROCESSING 完成（无论 main 走完整流式 / 流式异常一次性 fallback / referee 超时 fail-open）MUST 落一条 `pipeline_trace` 记录到 DB（字段约束见 transcript spec）。MUST NOT 因写 pipeline_trace 失败影响通话主路径——写入 SHALL 用 try/except 包裹，失败仅 ERROR 日志。

连续打断保护（与 main streaming 兼容）：当 `session.consecutive_interruption_count >= campaign.max_continuous_interruptions` 时 engine SHALL 按 `campaign.continuous_interruption_strategy` 触发保护：

- `short_reply`：在调 main LLM 之前 set `PipelineConfig.short_reply_active=True`，prompt_builder 在 system prompt 末尾追加"请用一句话回应"段落
- `listen_only`：跳过 PROCESSING（不调 main / referee），engine SHALL 直接 TTS 播放短引导语后回 LISTENING；本轮不写 pipeline_trace

完整轮次（SPEAKING TTS 完整播完未被打断）后 engine MUST 把 `consecutive_interruption_count` 清零。

#### Scenario: main LLM 与 referee LLM 并行 spawn

- **WHEN** 进入 PROCESSING 状态
- **THEN** engine SHALL 用 `asyncio.create_task` 同时启动 main LLM streaming（及任何 opt-in persona 对话路由）+ referee LLM；MUST NOT 串行（referee 等 main 完）

#### Scenario: main LLM 流式 token → sentence → TTS

- **WHEN** main LLM 通过 `chat_stream` 返回 token AsyncIterator
- **THEN** engine SHALL 用 sentence boundary detector 切句（命中 `。？！` 或 `\n\n` 或累积超 50 字），每切完一句 MUST 立即喂给 TTS provider 的 `synthesize_stream` 接口；TTS 每输出 PCM chunk MUST 立即推到 RTC `audio_out`
- **AND** engine MUST NOT 等 main LLM 完整结束才开始 TTS

#### Scenario: 首音频延迟监控

- **WHEN** main LLM 第一个 sentence 产出 + TTS 首 PCM chunk 推到 RTC
- **THEN** engine MUST 在 pipeline_trace 写 `first_audio_ms` 字段（从 PROCESSING 入口到首 PCM chunk 时间差），用于上线后 SLA 监控

#### Scenario: referee 开口前门控放行一条路由

- **WHEN** 用户终态文本落定、engine 已 eager 起跑 main（及任何 opt-in persona）对话路由并行缓冲
- **THEN** engine SHALL 在**释放任何音频之前**，以 `await asyncio.wait_for(run_referees, timeout=campaign.referee_timeout_ms/1000)` 作为门控 eval_fn，依 referee 裁决经 decider 选中**一条**已缓冲对话路由放行播放、并取消其余推测路由；被选路由的 `then_state` 副作用 SHALL 由 StatusProjector 驱动后续状态（见 call-state-machine spec）
- **AND** 因 referee 是小快模型且对话首句预合成本身需时，门控裁决通常先于首个音频 chunk 就绪 → p50 ~0ms 额外延迟

#### Scenario: 门控 referee 超时 / 低置信 fail-open

- **WHEN** 门控 referee 调用超时（> `campaign.referee_timeout_ms`，默认 ~600ms）或返回非法 JSON / confidence < 0.7
- **THEN** engine MUST fail-open 到 `campaign.referee_fail_open_route` 命名的对话路由（默认 `"main"`，已 eager 缓冲、放行即可、~0ms）；MUST NOT 阻塞通话；pipeline_trace 把该 referee 在 `referee_results[]` 的 `category` 记为 `"timeout"` / `"invalid"` / `"low_confidence"`，且 `selected_route_id` = 该 fail-open 路由 id（无独立标量 `referee_decision` 列——已被 multi-referee migration 删除）

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

每一轮 PROCESSING SHALL 支持 N 个（N ≥ 1）referee LLM 并行决策（替代原单 referee）。engine MUST 在 PROCESSING 入口用 `asyncio.gather` 同时 spawn 所有 enabled 的 `kind=referee` role_config，与 main（及 persona）对话路由并行，MUST NOT 串行或互相等待，MUST NOT 因等待任一 referee 阻塞对话生成主链路。每个 referee 拥有独立 system prompt、独立输出分类枚举语义、独立 fail-open，engine MUST NOT 硬编码任何 referee 的枚举值。referee 调用 MUST 用 `chat(json_mode=True)`（非流式），便宜小模型（如 qwen-turbo / gpt-4o-mini / doubao-lite），典型延迟 ≤ 500ms（< 门控超时 `referee_timeout_ms` ~600ms，故门控通常先于对话首句就绪）。referee 的输出契约见 § "referee 输出契约（category + confidence）"；下游**作为开口前门控 eval_fn 由 `SelectRouter` 消费**（见 § "SelectRouter 路由分发、开口前门控与 then_state" + § "路由规则引擎（decider）"），不再作为开口后判定。

#### Scenario: N 个 referee 并行 spawn

- **WHEN** 进入 PROCESSING 状态且 campaign 配置了 N 个 enabled referee
- **THEN** engine SHALL `asyncio.gather` 并行启动全部 N 个 referee LLM 调用 + main（及 persona）对话路由
- **AND** 对话路由 streaming → sentence → TTS 缓冲 MUST NOT 因等待任一 referee 而阻塞（门控在释放音频前 await）

#### Scenario: 单 referee 向后兼容

- **WHEN** campaign 仅配置 1 个 referee（pipeline-stream-and-referee 现状）
- **THEN** 行为 SHALL 等价于单 referee 门控 + 一组内置默认路由规则；已有 campaign MUST NOT 因本 change 改变决策行为（fail-open 到 main、放行 main 回复）

#### Scenario: 个别 referee fail-open

- **WHEN** 某个 referee LLM 超时 / 返回非法输出 / confidence < 阈值
- **THEN** engine MUST 将该 referee 视为「无 category 输出」（不命中任何规则），MUST NOT 抛异常阻塞通话，其他 referee 结果照常参与门控决策；全部 referee fail-open 时门控退化为 fail-open 到 `referee_fail_open_route`

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

#### Scenario: 默认回复不影响门控

- **WHEN** main（被选对话路由）走默认回复路径
- **THEN** 开口前门控仍正常：run_referees 作为 eval_fn 照常 await 并选路；engine MUST NOT 因 main 生成失败就跳过门控；若门控选中的仍是 main 路由则放行 default_reply 内容

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

engine SHALL 在门控 referee 返回后，按 campaign 配置的有序 `routing_rules` 列表逐条匹配，**第一个命中的规则即生效**（first-match-wins），把命中规则的 action 映射为**一条 route**（由 `SelectRouter` 放行），然后停止匹配。无任何规则命中时 SHALL 默认放行 `referee_fail_open_route`（默认 main，即 continue/回 LISTENING）。每条规则绑定一个 referee（按 label）+ 匹配值集合 + 一个 action。`decide()` 复用 verbatim；engine MUST NOT 让 route / decider 直接调用 `transition_to` 写状态——状态一律经被选 route 的 `then_state` 由 StatusProjector 投影（见 call-state-machine spec）。

#### Scenario: 规则级联匹配，第一个命中即生效

- **WHEN** referee 结果为 `{judge_intent: "NEGATIVE", judge_reject: "OPERATOR"}` 且 routing_rules 顺序为 [规则A 绑 judge_reject 匹配 OPERATOR → tool:transfer, 规则B 绑 judge_intent 匹配 NEGATIVE → restructure]
- **THEN** engine SHALL 选中规则A 映射的 `tool:transfer` route 并停止匹配，MUST NOT 再执行规则B

#### Scenario: action 类型 — route / tool（新）

- **WHEN** 命中规则的 action 为 `{type: route, to: <persona|closing|recovery|restructure>, then_state?}` 或 `{type: tool, tool: <alias>, then_state?}`
- **THEN** engine SHALL 经 selector 映射到对应 route（dialogue route 放行 eager 缓冲的生成；tool route lazy `execute()`），被选 route 的 `then_state` 由 StatusProjector 投影；MUST NOT 在 decider/route 内直接 `sm.transition_to`

#### Scenario: action 类型 — legacy transition（shim → route + then_state）

- **WHEN** 命中规则的 action 为 legacy `{type: "transition", to: "goal_achieved", goal_type: "appointment"}`（或 `to: "transfer"` / `to: "customer_decline"`）
- **THEN** engine SHALL 经 removal-tracked shim 把它映射为等价 route + then_state：`goal_achieved` → `closing` route（then_state=WRAPPING_UP，`goal_type` 仍取自 action 携带）；`transfer` → `tool:transfer`（then_state=TRANSFERRING，复用 `_perform_handoff`）；`customer_decline` → `recovery` route（then_state=ACTIVATING）；状态一律由 StatusProjector 投影，MUST NOT 直接 `sm.transition_to`，决策结果 MUST NOT 因本映射改变

#### Scenario: action 类型 — 切重组流

- **WHEN** 命中规则的 action 为 `{type: "restructure", source: "last_reply" | "interrupt_remaining"}`（或 route to=restructure）
- **THEN** engine SHALL 走 restructure route（then_state=LISTENING，referee-skipped），按 source 构造 InterruptText（见 § 重组流）

#### Scenario: 无命中默认放行 fail-open 路由

- **WHEN** 所有 routing_rules 均未命中（含全部 referee fail-open）
- **THEN** engine SHALL 放行 `referee_fail_open_route`（默认 main → continue/回 LISTENING），MUST NOT 误触发任何状态转移

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

### Requirement: 重组流连续触发封顶

为避免连续 restructure 让 AI 显得复读，engine SHALL 用计数器对连续 restructure 触发封顶（默认上限可由 campaign 配置）。超过上限时 SHALL 不再 restructure，改走 default_replies 或既有 continuous-interruption 处置。

#### Scenario: 连续 restructure 超限改走兜底

- **WHEN** 同一通话连续 restructure 次数达到 `max_continuous_restructure`
- **THEN** engine SHALL 停止 restructure，改播 campaign default_replies 或按既有连续打断策略处置；连续计数在正常 main 回复后 SHALL 清零

### Requirement: 引擎按 campaign 指定音色合成

引擎合成所有播音（开场白 + 主链路回复 + 固定话术）时 SHALL 使用 campaign 指定的音色。`campaign.voice_id` 持有 vendor speaker 字符串（如 `zh_female_xiaohe_uranus_bigtts`，由管理员在场景表单直接填写），引擎 MUST 将其原样传给 TTS provider 作为 speaker。`campaign.voice_id` 为 NULL / 空串时 MUST 回落到 provider 的默认 speaker，MUST NOT 让整通电话失败。

#### Scenario: 指定音色被真实通话消费

- **WHEN** campaign 的 `voice_id` 为一个非空 vendor speaker 串并发起通话
- **THEN** 引擎 MUST 用该串作为 TTS speaker 合成播音，使真实通话的发音与 web 端「试听」一致

#### Scenario: 未指定音色回落默认

- **WHEN** campaign 的 `voice_id` 为 NULL 或空串
- **THEN** 引擎 MUST 用 provider 默认 speaker 合成，通话正常进行，MUST NOT 抛错中断

### Requirement: main streaming 播放流水线（producer/consumer + 预合成）

main LLM 流式回复的"生成 → TTS 合成 → 播放"三级 MUST 并发流水化，MUST NOT 串行到"播完一句才生成/合成下一句"。engine SHALL 用 producer task 持续消费 `chat_stream → split_sentences`、并对每句**立即**发起 TTS 合成，把就绪句柄塞入一个有界队列；consumer task 从队列取出并播放。播第 N 句时第 N+1 句的 TTS SHALL 已在合成中。

队列 MUST 有界（默认上限 2 句），以限制 main LLM 领先播放的程度、限制 barge-in 时已合成音频的沉没成本。

#### Scenario: 生成不被播放挂起

- **WHEN** consumer 正在播放第 N 句音频
- **THEN** producer SHALL 继续消费 main LLM `chat_stream` 的后续 token 并切句、发起第 N+1 句 TTS 合成；main LLM 流 MUST NOT 因当前句播放而被挂起

#### Scenario: 句间无静音空档

- **WHEN** 第 N 句音频播放结束、队列里第 N+1 句已就绪
- **THEN** consumer SHALL 立即开始播放第 N+1 句；句间 MUST NOT 出现等待 TTS 合成首字节的静音空档

#### Scenario: first_audio_ms 记录点不变

- **WHEN** consumer 播放队列里第一句的首 PCM chunk
- **THEN** engine SHALL 记录 `pipeline_trace.first_audio_ms`（自 PROCESSING 入口起算），语义与 pipeline-stream-and-referee 一致

#### Scenario: barge-in 兼容三态

- **WHEN** partial_monitor 在播放期间判定打断（cancel `current_speaking_task`）
- **THEN** engine MUST cancel consumer 当前播放 + cancel producer task + 关闭队列中未播句柄的 TTS iterator；该轮 `interrupted=True`；下一轮回 LISTENING；无论打断点落在"播放中 / 合成中 / 队列等待中"行为一致

### Requirement: transfer LLM 检测不阻塞 PROCESSING 入口

带 LLM 调用的转人工检测 MUST NOT 在 PROCESSING 入口之前同步执行。便宜的 keyword / round 检测 MAY 保留 inline（零 LLM、确定性）；intent / llm（含 LLM 调用）的检测 SHALL 优先复用 referee 的 `transfer` decision；过渡期对显式配置 `transfer_llm_enabled` 的 campaign，该 LLM 检测 SHALL 与 main streaming 并行 spawn（同 referee 模式），其结果在 SPEAKING 结束前 await，MUST NOT 卡在 PROCESSING 入口前。

#### Scenario: transfer 复用 referee 决策

- **WHEN** referee 返回 `decision="transfer"`
- **THEN** engine SHALL 据此转 TRANSFERRING，MUST NOT 为此额外串行调一次 transfer LLM

#### Scenario: 显式 transfer_llm campaign 走并行兜底

- **WHEN** campaign 显式 `transfer_llm_enabled=true`
- **THEN** 该 LLM 检测 SHALL 在 PROCESSING 入口与 main streaming 并行 spawn；MUST NOT 在 PROCESSING 之前同步 await

### Requirement: SelectRouter 路由分发、开口前门控与 then_state

engine SHALL 提供一个 `SelectRouter`，作为每轮用户对话的**唯一**路由分发机制（change-2 的 `ENGINE_USE_ROUTER` kill-switch 已在本 change Phase-4 删除，Router 成为主路径、无双路径双 flag）。Router 把 `decide()` 的裁决映射到一张**路由表**，每条 route 携带 `kind`（dialogue / tool）、`exec`（eager / lazy）与可选 `then_state`：

- **dialogue route**（`main` / `persona:<label>` / `closing` / `recovery` / `restructure`）：`exec=eager`，用户终态一落定即推测起跑流式生成并缓冲首句。Router MUST 把 **live 未被 drain 的 `sentences()` 异步生成器**原样交给播放方（**eager-generator deviation**，见下）。
- **tool route**（`tool:hangup` / `tool:transfer`）：`exec=lazy`，仅在被选中时才 `execute()`，无推测开销、无 live 生成器（详见 § "挂断 / 转人工 lazy tool route"）。

Router SHALL 以 `run_referees` 为 **eval_fn 在开口前门控**：`await` referee 裁决后经 decider（first-match-wins、`category in match[]` 语义不变、`decide()` 复用 verbatim）选中**一条** route 放行、取消其余推测 dialogue route。被选 route 的 `then_state ∈ {LISTENING, WRAPPING_UP, ACTIVATING, TRANSFERRING, END}` 是副作用，由 StatusProjector 读取驱动状态（见 call-state-machine spec）。每个终结 route MUST 设 `session.hangup_cause`。

**eager-generator deviation（务必勿"修"）**：与 voxen `getResult`（先 drain 再交付）不同，本 Router 交付的是**未起跑的 live 生成器**——在 Router 内 drain 它会（a）摧毁 streaming token→sentence→TTS 的低延迟链路、（b）令门控不再"免费"（Router 会阻塞到整段生成完）。任何把它改成 `await` 整段生成的"整理"将**让每一轮静默**。

#### Scenario: Router 是唯一分发路径（无 kill-switch）

- **WHEN** 处理任一轮用户对话
- **THEN** engine MUST 经 `SelectRouter` 分发；MUST NOT 存在 `ENGINE_USE_ROUTER` 双路径或 legacy `_main_turn_loop` if/elif 效果分发（Phase-4 已删）

#### Scenario: dialogue route 交付 live 未 drain 生成器

- **WHEN** 一条 dialogue route 被选中放行
- **THEN** Router MUST 把该 route 的 `sentences()` 异步生成器以**未起跑（AGEN_CREATED）**状态交给播放方；MUST NOT 在 Router 内先行 drain / `await` 整段
- **AND** 守护测试 `test_eager_dialogue_route_returns_live_generator` MUST 断言交付时生成器处于 AGEN_CREATED（未 CLOSED / 未 SUSPENDED）

#### Scenario: then_state 副作用驱动状态投影

- **WHEN** 被选 route 携带 `then_state`（如 `closing→WRAPPING_UP` / `recovery→ACTIVATING` / `tool:transfer→TRANSFERRING` / `tool:hangup→END`）
- **THEN** engine MUST NOT 在 route 内直接写 `session.state`；route SHALL 仅声明 `then_state`，由 StatusProjector 单写者据此投影状态（call-state-machine spec）

#### Scenario: must-not-drop 机制原样保留

- **WHEN** 任一轮经 Router 分发
- **THEN** 以下机制 MUST 原样保留（复用原函数 / 原 inline 继承）：`_play_streaming` / `_SynthJob` 预合成（maxsize=2）、`_assemble_interrupt_text`、final-coalescing、cross-turn 计数器、greeting 非打断顺序、text≥2 门、wrap-up 关 referee/transfer/filler、the ONE `chat_stream→chat` fallback + `default_reply` guard、shielded finalize + DECR snap-to-0、post-call extractor 走线下 finalize

### Requirement: eager speculative 多人设对话（personas）

campaign MAY 配置 N 个 `kind=persona` 的对话角色（label 必填）。`campaign.persona_fanout_cap`（默认 1，clamp ∈ [1,3]）SHALL 定义**每轮并行推测的对话路由总数（含 main）**：本轮并行 eager 起跑的路由数 = `min(1 + enabled_persona 数, persona_fanout_cap)`，门控 referee 裁决选中**一条**放行、**取消其余**（vendor 会对取消的 token 计费）。`persona_fanout_cap=1` 即**仅 main、无推测**（opt-in 默认关）。

#### Scenario: 多路由并行推测 + 选一掐余

- **WHEN** campaign 启用若干 persona 且 `persona_fanout_cap ≥ 2`、进入 PROCESSING
- **THEN** engine SHALL 并行 eager 起跑 `min(1+enabled_persona, persona_fanout_cap)` 条对话路由（含 main）；门控裁决后 SHALL 仅放行被选 1 条、`cancel()` 其余推测 task；pipeline_trace 记录 `persona_candidates`（候选 label 集）与 `selected_route_id`

#### Scenario: persona_fanout_cap 上限与默认

- **WHEN** campaign 配置 `persona_fanout_cap > 3` 或 = 1 或未配置
- **THEN** engine MUST 把推测路由总数（含 main）clamp 到 [1,3]；`persona_fanout_cap=1`（默认）时仅起 main、无推测 fan-out、无取消计费

#### Scenario: 无 persona / 默认配置向后兼容

- **WHEN** 存量 campaign 无 persona 配置（或 persona_fanout_cap=1）
- **THEN** 行为 SHALL 等价于仅 main 对话路由 + 门控 fail-open-to-main；决策结果 MUST NOT 因本 change 改变

### Requirement: 挂断 / 转人工 lazy tool route

campaign MAY 在 `tools` JSONB 配置 `hangup` / `transfer` 工具（schema 见 data-model spec）。路由规则 `{type: tool, tool: <alias>}` 命中时，engine SHALL 经 `SelectRouter` 走对应 **lazy** tool route（仅命中才 `execute()`）：

- `tool:hangup`：SHALL 设 `session.hangup_cause = REFEREE_HANGUP`，可选先 TTS 播 `closing_phrase` 单句，**抑制本轮对话回复**（gating 下裁决先于音频，hangup 天然**替代**已缓冲回复、无半句抢断），驱动 → END。结束语来源 SHALL 按 **per-keyword 优先**解析：命中规则的 `RouteToolAction.closing_phrase` 非空时取之（同一 hangup 工具可被不同关键字复用、各带话术）；为空 / 缺省时回落 `HangupToolConfig.closing_phrase`；两者皆空则直接挂断、不播话术。
- `tool:transfer`：SHALL 复用现有 `_perform_handoff(trigger_type="referee_decision")` → TRANSFERRING；衔接话术沿用**单一来源** `campaign.transfer_phrases`（与 human-handoff 4 触发路径同源，MUST NOT 引入第二套话术配置）。

#### Scenario: tool:hangup 抑制回复并以 REFEREE_HANGUP 收尾

- **WHEN** 某轮门控裁决命中 `{type: tool, tool: hangup}`
- **THEN** engine MUST 设 `session.hangup_cause = REFEREE_HANGUP`；按 per-keyword 优先解析出的结束语若非空 SHALL 先 TTS 播该单句、否则立即收尾；MUST NOT 释放本轮已缓冲的对话回复音频；驱动通话 → END

#### Scenario: 不同关键字命中同一 hangup 工具取各自结束语

- **WHEN** referee 输出 `OFFENSIVE` 命中携带 `closing_phrase="不打扰了，再见"` 的规则；另一轮输出 `HANGUP` 命中携带 `closing_phrase="那再见"` 的规则（两条规则引用同一 hangup 工具）
- **THEN** engine SHALL 分别播"不打扰了，再见" / "那再见"后挂断，结束语取自**命中规则**而非工具配置的固定值；若命中规则与工具配置的 `closing_phrase` 皆空，engine MUST 直接挂断、不播话术

#### Scenario: tool:transfer 转人工复用单一话术源

- **WHEN** 某轮门控裁决命中 `{type: tool, tool: transfer}`
- **THEN** engine SHALL 调用现有 `_perform_handoff(trigger_type="referee_decision")` 并经 then_state 投影 → TRANSFERRING；衔接话术 SHALL 取自 `campaign.transfer_phrases`（既有单一来源）；MUST NOT 新增并行话术字段（routing/tool 驱动的转人工是既有 referee_decision 触发路径的再表达，非 human-handoff 4 触发闭集的新成员）

#### Scenario: 未配置工具时退化

- **WHEN** 路由规则引用了 campaign `tools` 未定义的 alias
- **THEN** isales-api MUST 在保存时以 `422 routing_rule_unknown_tool` 拒绝（见 web-admin-ui spec）；运行期 engine 对未知 alias SHALL 退化为放行 `referee_fail_open_route`（fail-open 到 main），MUST NOT 报错中断通话

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

### Requirement: 每个 LLM slot 按 role_config 的 provider + model 选用 LLM

engine SHALL 为每个 LLM slot（main / referee / persona / extractor / restructure）按其 role_config 配置的 **provider**（SSOT = `role_config.ext_params.provider`）+ **model**（`role_config.model` 列）选用对应的 LLM client，而非所有 slot 共用单一进程级全局 LLM。engine SHALL 按 `(provider, model)` 惰性构建并缓存 LLM client（避免每轮 / 每 slot 重建）；凭据由 provider-credential store 按 provider 解析（见 provider-credential spec）。

当某 slot 的 role_config 未配置 provider（`ext_params.provider` 缺失或空）时，engine SHALL 回落到**唯一**的全局默认 LLM（由 `engine_llm_provider` 构建一次）。该回落是单层默认解析，MUST NOT 为单个 slot 叠加多层兜底分支。

`_SlotSpec` SHALL 携带可空 `provider` 字段，由 `runtime_config` 从 `ext_params.provider` 读出并 thread 至 LLM 选用。restructure 为 singleton：engine SHALL 取首条 `kind=restructure` role_config 作为 restructure slot，且该 role_config MUST NOT 被要求填写 label（走内建路由 `restructure`，不按 label 路由）。

#### Scenario: slot 用自己配置的 provider + model

- **WHEN** 某 slot 的 role_config 配了 provider=`P` + model=`M`，且 `provider_credential` 有 `P` 的 enabled 凭据
- **THEN** engine SHALL 用 `(P, M)` 对应的 LLM client 发起该 slot 的 `chat` / `chat_stream`
- **AND** 不同 slot 配不同 provider / model 时各用各的，互不影响

#### Scenario: 未配 provider 回落全局默认（单层）

- **WHEN** 某 slot 的 role_config 没有 `ext_params.provider`（或为空）
- **THEN** engine SHALL 用全局默认 LLM（`engine_llm_provider`）服务该 slot
- **AND** 该回落为唯一一层，MUST NOT 叠加额外兜底分支

#### Scenario: (provider, model) client 缓存复用

- **WHEN** 同一 `(provider, model)` 组合被多个 slot 或多轮调用
- **THEN** engine SHALL 复用已缓存的 LLM client，MUST NOT 每轮 / 每 slot 重建

#### Scenario: restructure 取首条且不需 label

- **WHEN** campaign 配了一条或多条 `kind=restructure` role_config
- **THEN** engine SHALL 取首条作为 restructure slot
- **AND** 该 role_config MUST NOT 被要求填写 label

## Data Schema

| 字段 / 表 | 用途 |
|---|---|
| `campaign.default_replies` (JSONB) | 全部裁判否决时的兜底话术池，随机抽 1 |
| `role_config` | N 个角色 + M 个裁判 + 1 个润色的元配置（model, temperature, top_p, prompt_version 引用） |
| `pipeline_trace` | 每轮管线的候选、裁判结果、润色输入输出（详见 transcript 规范） |
