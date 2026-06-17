## MODIFIED Requirements

### Requirement: AI 管线编排

每一轮对话生成回复 SHALL 由两个 LLM 并行驱动：**main LLM**（以及任何 opt-in 的 persona 对话路由）流式输出纯文本回复（streaming token → sentence boundary → TTS chunk-fed）+ **referee LLM** 旁路输出决策枚举。referee 由**开口后判定**改为**开口前门控（gating）**：对话路由 eager 推测起跑、缓冲首句，referee 作为 eval_fn 在**释放任何音频之前**裁决放行哪一条路由（详见 § "SelectRouter 路由分发、开口前门控与 then_state"）。MUST NOT 再使用 N-role PK / N×M judges / polish 三层串联架构（详细历史背景见本 change 的 design.md § Context）。

main / restructure 等**多句连续流式回复**的下游 TTS 消费 SHALL 走 **TTS Provider 会话式合成接口**（见 provider-abc § "TTS Provider 异步流式合成接口"）：整轮开一个 TTS session，sentence boundary detector 切出的句子依次喂入**同一 session**，消费端播放一条连续 PCM 流——使 vendor 跨句统一规划韵律，消除「逐句独立冷请求」造成的跨句音色 / 语气跳变。单片段场景（开场白、连续打断保护 `listen_only` 引导语、main 异常的默认回复兜底、垫词）SHALL 继续走一次性 `synthesize_stream`，MUST NOT 为单片段开会话——这是按调用形态分流，非主备 fallback。

每一轮 PROCESSING 完成（无论 main 走完整流式 / 流式异常一次性 fallback / referee 超时 fail-open）MUST 落一条 `pipeline_trace` 记录到 DB（字段约束见 transcript spec）。MUST NOT 因写 pipeline_trace 失败影响通话主路径——写入 SHALL 用 try/except 包裹，失败仅 ERROR 日志。

连续打断保护（与 main streaming 兼容）：当 `session.consecutive_interruption_count >= campaign.max_continuous_interruptions` 时 engine SHALL 按 `campaign.continuous_interruption_strategy` 触发保护：

- `short_reply`：在调 main LLM 之前 set `PipelineConfig.short_reply_active=True`，prompt_builder 在 system prompt 末尾追加"请用一句话回应"段落
- `listen_only`：跳过 PROCESSING（不调 main / referee），engine SHALL 直接 TTS 播放短引导语后回 LISTENING；本轮不写 pipeline_trace

完整轮次（SPEAKING TTS 完整播完未被打断）后 engine MUST 把 `consecutive_interruption_count` 清零。

#### Scenario: main LLM 与 referee LLM 并行 spawn

- **WHEN** 进入 PROCESSING 状态
- **THEN** engine SHALL 用 `asyncio.create_task` 同时启动 main LLM streaming（及任何 opt-in persona 对话路由）+ referee LLM；MUST NOT 串行（referee 等 main 完）

#### Scenario: main LLM 流式 token → sentence → 会话式 TTS

- **WHEN** main LLM 通过 `chat_stream` 返回 token AsyncIterator
- **THEN** engine SHALL 用 sentence boundary detector 切句（命中 `。？！` 或 `\n\n` 或累积超 50 字），整轮开**一个** TTS session，每切完一句 MUST 立即喂入**同一 session**；session 输出的 PCM chunk MUST 立即推到 RTC `audio_out`
- **AND** engine MUST NOT 等 main LLM 完整结束才开始喂句 / 才开始播音（首句喂入即开始合成与播放）
- **AND** 同一轮内全部句子 MUST 在同一 vendor session 内合成（跨句共享韵律），MUST NOT 每句新开独立请求

#### Scenario: 被打断关闭 TTS session

- **WHEN** 实时 partial 监听器在本轮 main / restructure 流式回复播放中触发 barge-in（取消 audio_out）
- **THEN** engine MUST 关闭本轮 TTS session 立即释放 vendor 连接（替代旧的逐句取消）；已喂入但未播出的句子 SHALL 按既有 barge-in 残句捕获规则保留（`interrupt_remaining`，见 § 重组流 / 打断相关要求），MUST NOT 泄漏 vendor 会话

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
