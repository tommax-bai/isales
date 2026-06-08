## MODIFIED Requirements

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

### Requirement: main LLM 异常的默认回复兜底

main LLM streaming 主路径 + 非流式 fallback 都失败时，engine SHALL 走 Campaign 的默认回复兜底；MUST NOT 重试 LLM。

#### Scenario: 默认回复随机抽取

- **WHEN** main streaming + chat() fallback 都失败
- **THEN** engine SHALL 从 `campaign.default_replies` JSONB 数组中随机抽 1 条；用 TTS 一次性合成播放；transcript 追加 `{type: "default_reply_used", text: ..., reason: "main_llm_failed"}` 事件；pipeline_trace 记录 `main_reply_text=<default_reply>` + `error="main_streaming_and_fallback_failed"`

#### Scenario: 默认回复不影响门控

- **WHEN** main（被选对话路由）走默认回复路径
- **THEN** 开口前门控仍正常：run_referees 作为 eval_fn 照常 await 并选路；engine MUST NOT 因 main 生成失败就跳过门控；若门控选中的仍是 main 路由则放行 default_reply 内容

## ADDED Requirements

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

## REMOVED Requirements

### Requirement: SelectRouter 效果分发（kill-switch ENGINE_USE_ROUTER）

**Reason**: change-2 的 `ENGINE_USE_ROUTER` kill-switch 是 removal-tracked 过渡债（蓝图 §5 / change-2 design.md 明记 removal trigger = change-3 Phase-4）。本 change Phase-4 在同一 commit 删除 legacy `_main_turn_loop` 内联效果分发 + `ENGINE_USE_ROUTER` flag + effect-route adapter，双路径双 flag 不再存在。

**Migration**: 由本 change ADDED 的 § "SelectRouter 路由分发、开口前门控与 then_state" 取代——Router 升级为唯一分发路径，并从「`decide()` 之后的效果分发」扩展到「eager 对话路由 + 开口前门控 eval_fn + lazy tool route + then_state 副作用」。存量 campaign（无 persona / tool 配置）行为等价于「仅 main 对话路由 + 门控 fail-open-to-main」，决策结果不变。
