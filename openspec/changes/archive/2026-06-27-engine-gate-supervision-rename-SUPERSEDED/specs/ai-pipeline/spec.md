<!-- ai-pipeline delta: 旁路→门控监管 rename + gate-first formalize; 门控监管=pure classifier (bare category token, json_mode=False, no confidence); decider=sole deterministic release/route/tool decider, release=no-match default; await ALL enabled supervisors, fail-open-to-release (markers {timeout,invalid} only, drop low_confidence). -->

## MODIFIED Requirements

### Requirement: AI 管线编排

每一轮对话生成回复 SHALL 由两个 LLM 并行驱动：**main LLM**（以及任何 opt-in 的 persona 对话路由）流式输出纯文本回复（streaming token → sentence boundary → TTS chunk-fed）+ **门控监管 LLM（`kind=referee`，主路径门控、与 main 并行执行）** 输出闭集分类 category。门控监管由**开口后判定**改为**开口前门控（gating）**：对话路由 eager 推测起跑、缓冲首句，门控监管的 category 经门控路由（decider）在**释放任何音频之前**裁决放行哪一条路由（详见 § "SelectRouter 路由分发、开口前门控与 then_state"）。门控监管 LLM 是**纯分类器**——只产出一个 category token，放行 / 选路 / 工具触发全部由确定性门控路由决定，引擎 MUST NOT 让门控监管 LLM 自行做 pass/hold/放行 决策。MUST NOT 再使用 N-role PK / N×M judges / polish 三层串联架构（详细历史背景见本 change 的 design.md § Context）。

N 个门控监管 SHALL 并行执行（`asyncio.create_task` per supervisor）。门控 SHALL `await` **全部** enabled 门控监管完成 **或** 超时（per-supervisor budget = `campaign.referee_timeout_ms`）；超时 / 失败一律 **fail-open 到 release**（放行 `referee_fail_open_route`，默认 main），**永不 fail-closed / hold**——即使该轮命中的本应是 hangup / transfer 这类有后果的工具，工具触发亦为 **best-effort**（方向 A）。单个门控监管失败 = 该监管无 category（不命中任何规则），其余监管照常参与门控决策。无任何 routing rule 命中时 SHALL 默认 release main（release 是 no-match 的默认动作）。

每一轮 PROCESSING 完成（无论 main 走完整流式 / 流式异常一次性 fallback / 门控监管超时 fail-open）MUST 落一条 `pipeline_trace` 记录到 DB（字段约束见 transcript spec）。MUST NOT 因写 pipeline_trace 失败影响通话主路径——写入 SHALL 用 try/except 包裹，失败仅 ERROR 日志。

连续打断保护（与 main streaming 兼容）：当 `session.consecutive_interruption_count >= campaign.max_continuous_interruptions` 时 engine SHALL 按 `campaign.continuous_interruption_strategy` 触发保护：

- `short_reply`：在调 main LLM 之前 set `PipelineConfig.short_reply_active=True`，prompt_builder 在 system prompt 末尾追加"请用一句话回应"段落
- `listen_only`：跳过 PROCESSING（不调 main / 门控监管），engine SHALL 直接 TTS 播放短引导语后回 LISTENING；本轮不写 pipeline_trace

完整轮次（SPEAKING TTS 完整播完未被打断）后 engine MUST 把 `consecutive_interruption_count` 清零。

#### Scenario: main LLM 与 referee LLM 并行 spawn

- **WHEN** 进入 PROCESSING 状态
- **THEN** engine SHALL 用 `asyncio.create_task` 同时启动 main LLM streaming（及任何 opt-in persona 对话路由）+ 全部 enabled 门控监管 LLM；MUST NOT 串行（门控监管等 main 完）

#### Scenario: main LLM 流式 token → sentence → TTS

- **WHEN** main LLM 通过 `chat_stream` 返回 token AsyncIterator
- **THEN** engine SHALL 用 sentence boundary detector 切句（命中 `。？！` 或 `\n\n` 或累积超 50 字），每切完一句 MUST 立即喂给 TTS provider 的 `synthesize_stream` 接口；TTS 每输出 PCM chunk MUST 立即推到 RTC `audio_out`
- **AND** engine MUST NOT 等 main LLM 完整结束才开始 TTS

#### Scenario: 首音频延迟监控

- **WHEN** main LLM 第一个 sentence 产出 + TTS 首 PCM chunk 推到 RTC
- **THEN** engine MUST 在 pipeline_trace 写 `first_audio_ms` 字段（从 PROCESSING 入口到首 PCM chunk 时间差），用于上线后 SLA 监控

#### Scenario: referee 开口前门控放行一条路由

- **WHEN** 用户终态文本落定、engine 已 eager 起跑 main（及任何 opt-in persona）对话路由并行缓冲
- **THEN** engine SHALL 在**释放任何音频之前**，以门控 eval_fn 形式 `await` **全部** enabled 门控监管完成或各自超时（per-supervisor budget = `campaign.referee_timeout_ms`），依各监管的 category 经 decider 选中**一条**已缓冲对话路由放行播放、并取消其余推测路由；被选路由的 `then_state` 副作用 SHALL 由 StatusProjector 驱动后续状态（见 call-state-machine spec）
- **AND** 因门控监管是小快模型且对话首句预合成本身需时，门控裁决通常先于首个音频 chunk 就绪 → p50 ~0ms 额外延迟

#### Scenario: 门控 referee 超时 / 低置信 fail-open

- **WHEN** 某个门控监管调用超时（> `campaign.referee_timeout_ms`，默认 ~600ms）或返回非闭集 / 无法解析的 category token
- **THEN** engine MUST fail-open 到 release，即放行 `campaign.referee_fail_open_route` 命名的对话路由（默认 `"main"`，已 eager 缓冲、放行即可、~0ms）；MUST NOT 阻塞通话、MUST NOT fail-closed/hold（即使该监管本应命中 hangup/transfer，工具触发亦为 best-effort）；pipeline_trace 把该门控监管在 `referee_results[]` 的 `category` 记为 `"timeout"` 或 `"invalid"`（fail-open 标记集仅 `{timeout, invalid}`，无 `low_confidence`——`confidence` 由引擎钉死 1.0），且 `selected_route_id` = 该 fail-open 路由 id（无独立标量 `referee_decision` 列——已被 multi-referee migration 删除）

#### Scenario: main LLM streaming 异常一次性 fallback

- **WHEN** main LLM `chat_stream` 中途抛异常 / SSE 断流 / provider 超时
- **THEN** engine MAY 用 `chat()`（非流式）重试一次作为 fallback；fallback 成功 → 整段 reply 一次性 TTS + 落 pipeline_trace 标 `main_fallback_used=true`；fallback 失败 → 走 campaign 默认回复兜底（详见 § "main LLM 异常的默认回复兜底"）

> **fallback 移除 trigger**: 本 Requirement 的 chat() 一次性 fallback 是过渡期措施。streaming 链路 30 天 SLA ≥ 99.5% 后由 followup change `pipeline-remove-streaming-fallback` 删除。

#### Scenario: pipeline_trace 写入失败不影响通话

- **WHEN** END 时事务批量写 pipeline_trace 因 DB 短暂不可用而失败
- **THEN** engine MUST 重试 3 次（指数退避）后仍失败 → ERROR 日志、session 仍清理（DECR 并发 + LPUSH CallEnded）；MUST NOT 因 pipeline_trace 失败而阻塞 call_record / CallEnded 路径

#### Scenario: 连续打断保护 short_reply 策略

- **WHEN** `session.consecutive_interruption_count >= campaign.max_continuous_interruptions` 且 `campaign.continuous_interruption_strategy = "short_reply"`
- **THEN** engine SHALL 在调 main LLM 之前 set `PipelineConfig.short_reply_active=True`；prompt_builder 在 main system prompt 末尾追加"请用一句话回应"段落；main streaming + 门控监管 照常运行；pipeline_trace 仍写

#### Scenario: 连续打断保护 listen_only 策略

- **WHEN** `session.consecutive_interruption_count >= campaign.max_continuous_interruptions` 且 `campaign.continuous_interruption_strategy = "listen_only"`
- **THEN** engine MUST NOT 调用任何 LLM；SHALL 直接 TTS 播放引导语后回 LISTENING；本轮 MUST NOT 写 pipeline_trace

#### Scenario: 完整 SPEAKING 后清零计数器

- **WHEN** SPEAKING 状态 TTS 完整播完且未被实时 partial 监听器触发打断
- **THEN** engine MUST 把 `session.consecutive_interruption_count` 重置为 0

### Requirement: referee LLM 二级决策

每一轮 PROCESSING SHALL 支持 N 个（N ≥ 1）门控监管 LLM（`kind=referee`）并行执行（替代原单 referee）。engine MUST 在 PROCESSING 入口用 `asyncio.gather` 同时 spawn 所有 enabled 的 `kind=referee` role_config，与 main（及 persona）对话路由并行，MUST NOT 串行或互相等待，MUST NOT 因等待任一门控监管阻塞对话生成主链路。每个门控监管拥有独立 system prompt、独立输出分类枚举语义、独立 fail-open，**枚举完全由各门控监管自己的 prompt 定义**，engine MUST NOT 硬编码任何门控监管的枚举值（不得内置 pass / hold 等任何 category）。门控监管是**纯分类器**——只产出一个闭集 category token，MUST NOT 在 LLM 内做 pass/hold/放行 决策。门控监管调用 MUST 用 `chat(json_mode=False)` 输出**单个 bare category token**（非流式），便宜小模型（如 qwen-turbo / gpt-4o-mini / doubao-lite），典型延迟 ≤ 500ms（< 门控超时 `referee_timeout_ms` ~600ms，故门控通常先于对话首句就绪）。门控监管的输出契约见 § "referee 输出契约（category + confidence）"；下游**作为开口前门控 eval_fn 由 `SelectRouter` 消费**（见 § "SelectRouter 路由分发、开口前门控与 then_state" + § "路由规则引擎（decider）"），不再作为开口后判定。

#### Scenario: N 个 referee 并行 spawn

- **WHEN** 进入 PROCESSING 状态且 campaign 配置了 N 个 enabled 门控监管
- **THEN** engine SHALL `asyncio.gather` 并行启动全部 N 个门控监管 LLM 调用 + main（及 persona）对话路由
- **AND** 对话路由 streaming → sentence → TTS 缓冲 MUST NOT 因等待任一门控监管而阻塞（门控在释放音频前 await 全部 enabled 门控监管完成或超时）

#### Scenario: 单 referee 向后兼容

- **WHEN** campaign 仅配置 1 个门控监管（pipeline-stream-and-referee 现状）
- **THEN** 行为 SHALL 等价于单门控监管 + 一组内置默认路由规则；已有 campaign MUST NOT 因本 change 改变决策行为（fail-open 到 main、放行 main 回复）

#### Scenario: 个别 referee fail-open

- **WHEN** 某个门控监管 LLM 超时 / 返回非闭集或无法解析的 category token
- **THEN** engine MUST 将该门控监管视为「无 category 输出」（不命中任何规则），MUST NOT 抛异常阻塞通话，其他门控监管结果照常参与门控决策；全部门控监管 fail-open 时门控退化为 fail-open 到 release（放行 `referee_fail_open_route`）

### Requirement: referee 输出契约（category + confidence）

每个门控监管 LLM SHALL 只输出闭集枚举里的一个 category 词（bare token，无 JSON、无 confidence、无标点），其中 category 是该门控监管 prompt 自定义的分类字符串（闭集枚举，语义由 prompt 定义）。调用 MUST 用 `chat(json_mode=False)` 输出单个 bare category token。`confidence` 由引擎钉死为 1.0，MUST NOT 由门控监管 LLM 产出。engine MUST NOT 在门控监管输出中要求 `goal_type`——`goal_type` 由路由规则的 `goal_achieved` action 携带（见 § 路由规则引擎）。此契约替代原单 referee 的 `{decision, goal_type, confidence}` 强语义 JSON 输出（历史已废）。

#### Scenario: referee 输出被规则引擎消费

- **WHEN** 某门控监管返回 bare token `NEGATIVE`
- **THEN** engine SHALL 以 `{<referee_label>: "NEGATIVE"}` 形式喂给路由规则引擎做匹配
- **AND** engine MUST NOT 对 category 字符串施加 engine 侧语义解释

#### Scenario: referee 输出校验失败

- **WHEN** 门控监管输出非闭集 category / 含 JSON 或标点 / 无法解析为单个 token
- **THEN** engine MUST fail-open：该门控监管视为无 category 输出；pipeline_trace 记录该门控监管的 `category="invalid"` 或 `"timeout"`（标记集仅 `{timeout, invalid}`，无 `low_confidence`）

### Requirement: 路由规则引擎（decider）

门控路由（`routing_rules` + `decide()`）SHALL 是**唯一**确定性 decider——release / route / tool 的判定全部在此，门控监管 LLM 不参与。engine SHALL 在门控监管返回后，按 campaign 配置的有序 `routing_rules` 列表逐条匹配，**第一个命中的规则即生效**（first-match-wins，多门控监管冲突一律按 **规则顺序** 解决、而非到达顺序），把命中规则的 action 映射为**一条 route**（由 `SelectRouter` 放行），然后停止匹配。无任何规则命中时 SHALL 默认 release `referee_fail_open_route`（默认 main，即 continue/回 LISTENING）——release 是 no-match 的默认动作。每条规则绑定一个门控监管（按 label）+ 匹配值集合 + 一个 action。`decide()` 是纯 first-match-wins 遍历、复用 verbatim；engine MUST NOT 让 route / decider 直接调用 `transition_to` 写状态——状态一律经被选 route 的 `then_state` 由 StatusProjector 投影（见 call-state-machine spec）。

#### Scenario: 规则级联匹配，第一个命中即生效

- **WHEN** 门控监管结果为 `{judge_intent: "NEGATIVE", judge_reject: "OPERATOR"}` 且 routing_rules 顺序为 [规则A 绑 judge_reject 匹配 OPERATOR → tool:transfer, 规则B 绑 judge_intent 匹配 NEGATIVE → restructure]
- **THEN** engine SHALL 选中规则A 映射的 `tool:transfer` route 并停止匹配，MUST NOT 再执行规则B（冲突按规则顺序解决，与各门控监管到达顺序无关）

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

- **WHEN** 所有 routing_rules 均未命中（含全部门控监管 fail-open）
- **THEN** engine SHALL 默认 release `referee_fail_open_route`（默认 main → continue/回 LISTENING），MUST NOT 误触发任何状态转移

### Requirement: SelectRouter 路由分发、开口前门控与 then_state

engine SHALL 提供一个 `SelectRouter`，作为每轮用户对话的**唯一**路由分发机制（change-2 的 `ENGINE_USE_ROUTER` kill-switch 已在本 change Phase-4 删除，Router 成为主路径、无双路径双 flag）。Router 把 `decide()` 的裁决映射到一张**路由表**，每条 route 携带 `kind`（dialogue / tool）、`exec`（eager / lazy）与可选 `then_state`：

- **dialogue route**（`main` / `persona:<label>` / `closing` / `recovery` / `restructure`）：`exec=eager`，用户终态一落定即推测起跑流式生成并缓冲首句。Router MUST 把 **live 未被 drain 的 `sentences()` 异步生成器**原样交给播放方（**eager-generator deviation**，见下）。
- **tool route**（`tool:hangup` / `tool:transfer`）：`exec=lazy`，仅在被选中时才 `execute()`，无推测开销、无 live 生成器（详见 § "挂断 / 转人工 lazy tool route"）。

Router SHALL 以 `run_referees` 为 **eval_fn 在开口前门控**：`await` **全部** enabled 门控监管完成或各自超时后，经 decider（first-match-wins、`category in match[]` 语义不变、`decide()` 复用 verbatim）选中**一条** route 放行、取消其余推测 dialogue route。门控监管 LLM 在主对话**并行执行**（p50 ~0ms overlap），但控制流上是主路径**阻塞门**而非旁路——音频被 hold 到裁决返回才释放。任一门控监管超时 / 失败一律 fail-open 到 release（放行 `referee_fail_open_route`），永不 fail-closed/hold。被选 route 的 `then_state ∈ {LISTENING, WRAPPING_UP, ACTIVATING, TRANSFERRING, END}` 是副作用，由 StatusProjector 读取驱动状态（见 call-state-machine spec）。每个终结 route MUST 设 `session.hangup_cause`。

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

### Requirement: transfer LLM 检测不阻塞 PROCESSING 入口

带 LLM 调用的转人工检测 MUST NOT 在 PROCESSING 入口之前同步执行。便宜的 keyword / round 检测 MAY 保留 inline（零 LLM、确定性）；intent / llm（含 LLM 调用）的检测 SHALL 优先复用门控监管的输出——即门控监管返回的 category 命中一条 `action=tool:transfer` 的路由规则时即驱动转人工；过渡期对显式配置 `transfer_llm_enabled` 的 campaign，该 LLM 检测 SHALL 与 main streaming 并行 spawn（同门控监管模式），其结果在 SPEAKING 结束前 await，MUST NOT 卡在 PROCESSING 入口前。

#### Scenario: transfer 复用 referee 决策

- **WHEN** 门控监管返回的 category 命中一条 `action=tool:transfer`（或 legacy `to:"transfer"`）的路由规则
- **THEN** engine SHALL 据此转 TRANSFERRING，MUST NOT 为此额外串行调一次 transfer LLM

#### Scenario: 显式 transfer_llm campaign 走并行兜底

- **WHEN** campaign 显式 `transfer_llm_enabled=true`
- **THEN** 该 LLM 检测 SHALL 在 PROCESSING 入口与 main streaming 并行 spawn；MUST NOT 在 PROCESSING 之前同步 await
