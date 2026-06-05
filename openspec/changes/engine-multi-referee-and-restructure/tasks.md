# Tasks — engine-multi-referee-and-restructure

> 依赖：本 change 叠在 `pipeline-stream-and-referee` 之上。§0 是硬前置——未完成前不要动 §2+ 的 spec/代码 delta（否则两个 active change 互踩）。

## 0. 前置：pipeline-stream-and-referee 收口

- [x] 0.1 跑完 `pipeline-stream-and-referee` 剩余 task（当前 87/105），确认 main/referee/extractor 链路在 mac dev e2e 绿 <!-- pipeline-stream-and-referee 已 archive 为 archive/2026-06-05-pipeline-stream-and-referee -->
- [x] 0.2 `openspec validate pipeline-stream-and-referee --strict` 通过 <!-- archive 前已通过 -->
- [x] 0.3 `/opsx:archive pipeline-stream-and-referee` — referee/main/extractor 需求合并进 `openspec/specs/` <!-- 已合并：ai-pipeline/goal-achievement/role-prompt/transcript 现含 referee 基线需求 -->
- [x] 0.4 archive 后回看本 change 6 个 spec delta：把对「单 referee」的 ADDED 表述，按需改写为对已合并 referee 需求的 MODIFIED（base 此时已存在），再 `openspec validate engine-multi-referee-and-restructure --strict` <!-- ai-pipeline「referee LLM 二级决策」/ goal-achievement「实时目标达成判定」/ role-prompt「referee prompt 内容规范」/ transcript「pipeline_trace 表的字段约束」改为 MODIFIED；decider/重组流/data-model/web-admin-ui 仍 ADDED。validate --strict 通过 -->

## 1. isales-common：数据模型 + 枚举 + migration

<!-- §1 isales-common 全部实装 + 176 tests green + ruff clean (isales-common HEAD pending commit) -->
- [x] 1.1 `enums.py`：`RoleKind` 增加 `RESTRUCTURE = "restructure"`（集合变 `{main, referee, extractor, restructure}`）<!-- 同步给 PromptScopeType 加 RESTRUCTURE（restructure prompt 需可版本化；test_enums 的 RoleKind==PromptScopeType 不变式仍绿） -->
- [x] 1.2 `models/role_config.py`：新增 `label: Mapped[str | None] = mapped_column(String(64), nullable=True)`
- [x] 1.3 `models/campaign.py`：新增 `routing_rules: Mapped[list] = mapped_column(JSONB, nullable=False, default=list)` + `max_continuous_restructure: Mapped[int]`（默认 2）+ `primary_referee_label: Mapped[str | None]`（低置信兜底用，见 design Open Q）
- [x] 1.4 `models/pipeline_trace.py`：删单 referee 字段，改为 `referee_results JSONB`（数组）+ 新增 `matched_rule JSONB` / `restructure_active Bool` / `restructure_trigger String` / `restructure_source_text Text` <!-- DTO PipelineTraceRead (schemas/call.py) 同步重构 -->
- [x] 1.5 `call_record.prompt_versions` schema（Pydantic）：`referee_llm` → `referee_llms[]`（label+model+pv_id）+ 新增 `restructure_llm` <!-- schemas/messages/dial.py：新增 RefereePromptVersionRef(label)；snapshot model 不入 model 字段（与 main/extractor 一致，model 由 role_config pin） -->
- [x] 1.6 Pydantic schemas：RoutingRule / RoutingAction（transition|restructure）+ RefereeSpec 加 label/category 输出 + 新增 RestructureSpec <!-- routing_rule.py（discriminated TransitionAction|RestructureAction，goal_type validator）；pipeline.py：RefereeSpec.label 必填 + RestructureSpec + PipelineConfig referees[]/restructure/routing_rules/max_continuous_restructure/primary_referee_label -->
- [x] 1.7 alembic migration（一支）：DDL（label 列 / routing_rules 列 / restructure 相关 campaign 列 / pipeline_trace 字段重构 / 放宽 referee 唯一约束、给 referee label 加同-campaign unique index）<!-- a7b8c9d0e1f2 (down=f6a7b8c9d0e1)；referee「恰好一行」是 app 层约束非 DB，故 DB 侧只加 partial unique index uq_role_config_campaign_label WHERE label IS NOT NULL -->
- [x] 1.8 同 migration 内 data migration：给每个现有 campaign 的单 referee 行补 `label="main_judge"`、标 `primary_referee_label`、seed 等价默认 `routing_rules`（goal_achieved→WRAPPING_UP / transfer / customer_decline + 低置信 restructure 规则）<!-- goal_type 由动态(referee)收窄为静态(rule)，seed 用 goal_type="appointment"（v1 无真数据，admin 自行重配）；低置信 restructure 规则不 seed（现有 campaign 无 restructure role，退化 continue=现状） -->
- [x] 1.9 bump isales-common 版本，更新 6 个消费仓 pin <!-- 0.6.0→0.7.0；只升 engine+api pin 到 >=0.7,<0.8（proposal Impact: scheduler/telephony 完全不动、worker 基本不动，pin 本就错位 0.4/0.5/0.6，不强行拉齐） -->
- [x] 1.10 isales-common 单测：RoleKind/restructure、RoutingRule 校验、prompt_versions schema round-trip <!-- test_routing_rule.py 新增；test_pipeline_schemas.py 重写；test_schemas_dto/messages 同步；全仓 176 passed -->

## 2. isales-engine：多 referee 并行 + 规则引擎

<!-- §2 isales-engine 多 referee + decider 全实装 -->
- [x] 2.1 `runtime_config.py`：referee 装配从 `_first(REFEREE)` 改为取**全部** enabled referee → `list[RefereeSpec]`；加 `_restructure_spec(_first(RESTRUCTURE))`；`PipelineConfig` 加 `referees: list` + `restructure` + `routing_rules` + `max_continuous_restructure` + `primary_referee_label` <!-- 新增 _all_enabled() 过滤 enabled；引擎侧 PipelineConfig 在 pipeline/prompt_builder.py（非 common schema）；referee label fallback f"referee_{rc.id}" -->
- [x] 2.2 `streaming/types.py`：`RefereeResult` 改为 `{label, category, confidence, duration_ms}`（去 decision/goal_type 强语义）；新增 fail-open 构造 <!-- category=None 表 fail-open，failopen_reason 记 timeout/invalid；effective_category()/trace_category()/as_trace() helper，置信阈值在此但由 decider 应用 -->
- [x] 2.3 referee 调用层（`run_referee`）：输出契约改 `{category, confidence}`，prompt 注入该 referee 的枚举语义；保留 fail-open <!-- 置信 floor 从 parser 移到 decider（区分 low_conf 与 invalid 供低置信 restructure 用）；label 透传 -->
- [x] 2.4 `orchestrator.py`：单 `create_task` 改为 `asyncio.gather` 并行起全部 referee（与 main streaming 并行，不阻塞）<!-- referee_tasks[] + referee_labels[]；新增 restructure 模式（_build_messages/_stream_params）+ run_restructure_stream factory -->
- [x] 2.5 新增 decider 规则引擎模块：输入 `{label: category}` + routing_rules → first-match-wins → action（transition / restructure / continue）；referee 缺 category 不命中 <!-- pipeline/decider.py：DeciderAction + decide()；低置信兜底也在此 -->
- [x] 2.6 `run_loop.py`：把 §701-730 的 referee-decision 分支替换为「decider 返回 action → 执行」；transition action 复用现有 transition_to / _perform_handoff 逻辑 <!-- _await_referees(多)+_cancel_referees(barge-in 取消 stale)；transfer 检测保留 -->

## 3. isales-engine：重组流 + InterruptText 捕获

<!-- §3 重组流全实装 -->
- [x] 3.1 `call_session.py`（打断字段区 ~135 行后）：新增 `interrupt_remaining_text: str | None` + `consecutive_restructure_count: int`
- [x] 3.2 barge-in 残留捕获：`run_loop.py` `_play_streaming` finally 丢弃路径（~1051-1053），在 `interruption_signaled` 时把**尚未送 TTS 的 sentence buffer 文本**拼接存入 `interrupt_remaining_text`（不改丢弃本身时序/取消语义）<!-- 捕获 = current_job + 队列中 job 的 text；仅 main 流（restructure 流不再捕获防环） -->
- [x] 3.3 restructure 执行路径：复用 main streaming→sentence→TTS，但 messages 仅 `[{system: restructure_prompt}, {user: InterruptText}]`（不带 history/用户最新句）；跑完直接回 LISTENING、不过 referee <!-- _run_restructure() helper -->
- [x] 3.4 InterruptText 来源装配：`source=last_reply` 取 dialog_history 末条 assistant；`source=interrupt_remaining` 取 `interrupt_remaining_text` 并取用即清空（空则退化 last_reply）<!-- _assemble_interrupt_text() -->
- [x] 3.5 低置信兜底 (c)：primary referee `confidence < 阈值` 时走内置低置信 restructure 规则（替换原静默 continue 分支，**删旧分支不叠加**）<!-- decide() 无规则命中时检查 primary 低置信→restructure(last_reply, trigger=low_confidence)；旧 parser 静默 continue 分支已删 -->
- [x] 3.6 连续 restructure 封顶：达 `max_continuous_restructure` 改走 default_replies / 既有连续打断策略；正常 main 回复后清零 <!-- restructure_capped → _play_tts(default_reply) + 计数清零；continue 分支清零 -->
- [x] 3.7 未配置 restructure 时 restructure action 退化为 continue（不报错）<!-- decide(restructure_enabled=False) → continue，matched_rule 仍记录供 trace -->

## 4. isales-engine：pipeline_trace + 测试

<!-- §4 全实装 + 全仓 333 tests green + ruff clean -->
- [x] 4.1 `run_loop.py` pipeline_trace 写入（~615-639）：写 `referee_results` 数组 + `matched_rule` + `restructure_active/trigger/source_text` <!-- _base_trace() helper；transcript_recorder.py 持久化映射同步重构 -->
- [x] 4.2 单测：多 referee gather 并行 + 单个 fail-open 不影响其他 <!-- test_pipeline.py test_multiple_referees_run_in_parallel / test_single_referee_fail_open_isolated -->
- [x] 4.3 单测：decider first-match-wins（多规则命中取第一个）+ 无命中默认 continue <!-- test_decider.py 11 cases -->
- [x] 4.4 单测：restructure 三触发（last_reply / interrupt_remaining / 低置信）各自 InterruptText 正确、不带 history <!-- test_run_loop.py _assemble_interrupt_text* + test_decider low_confidence + test_pipeline restructure messages-only-interrupt-text -->
- [x] 4.5 单测：barge-in 残留捕获 → 下一轮 interrupt_remaining 重说；残留空时退化 <!-- test_assemble_interrupt_text_interrupt_remaining_consumes_and_clears / _degrades_when_empty -->
- [x] 4.6 单测：连续 restructure 封顶 + 单 referee 向后兼容（等价现状）<!-- test_run_session_restructure_caps_then_plays_default + 既有 goal_achieved/transfer/decline run_loop e2e（单 referee + 默认规则=现状）-->
- [x] 4.7 单测：restructure 跑完不再 spawn referee <!-- test_restructure_stream_skips_referee_and_uses_only_interrupt_text + test_run_session_restructure_fires_and_records_trace -->

## 5. isales-api：多 referee CRUD + 规则配置

<!-- §5 isales-api 全实装 + 119 passed（仅 2 个 redis 环境相关 start/pause 为 pre-existing fail，与本 change 无关）+ ruff clean -->
- [x] 5.1 `routers/role_configs.py`：去掉「恰好一个 referee」约束，支持 N 行 referee；加 `restructure` kind；写入校验 referee label 唯一非空 <!-- 原 router 本就无「恰好一个」约束；新增 _require_unique_label（create/update 校验非空+同 campaign 唯一）；RoleConfigNestedWrite/RoleConfigBase 加 label -->
- [x] 5.2 routing_rules 配置 endpoint（read/replace 整组有序规则）+ 校验：referee 指向存在 label、action.to 合法状态、action.source ∈ {last_reply, interrupt_remaining}、goal_achieved 必带 goal_type <!-- GET/PUT /campaigns/{id}/routing-rules；action 合法性由 RoutingRule pydantic（discriminated + goal_type validator）保证；label 存在性 + primary_referee_label 由 routing_validation.py 跨实体校验；campaign nested create/update 同样校验 -->
- [x] 5.3 删除 referee 时校验无 routing_rules 仍引用其 label <!-- delete_role_config：referee 被 routing_rules 或 primary_referee_label 引用 → 409 referee_label_in_use -->
- [x] 5.4 api 单测：多 referee CRUD + 规则校验（非法 label/越界 action 被拒）+ 删裁判引用保护 <!-- tests/test_multi_referee_routing.py 12 cases；test_campaigns_crud/test_campaign_configs referee fixture 补 label -->

## 6. isales-web：多流路由配置页

<!-- §6 isales-web 全实装 + 44 vitest passed + tsc + eslint clean -->
- [x] 6.1 `types/`：RoleKind 加 `restructure`；新增 RoutingRule / RoutingAction 类型；referee 配置改列表 <!-- campaign.ts: RoleKind+restructure、RoleConfig{Read,NestedWrite}.label、TransitionAction/RestructureAction/RoutingRule、CampaignBase routing_rules/max_continuous_restructure/primary_referee_label + CAMPAIGN_DEFAULTS；config.ts PromptScopeType+restructure -->
- [x] 6.2 裁判列表组件：增删 referee（label/model/prompt/枚举语义说明）<!-- RoleConfigTab 加「标识」列 + restructure kind tag；RoleConfigDialog 加 restructure 选项 + label 字段（referee/restructure 必填校验）+ 透传 label -->
- [x] 6.3 路由规则编辑器：有序增删 + 调序（顺序即优先级）+ 每条选 referee→匹配 category→action <!-- 新增 RoutingRulesTab.vue：el-table 规则编辑 + ↑↓ move + referee 下拉(从裁判 label) + match 多选 tag + action 转移/重组切换 -->
- [x] 6.4 重组流配置入口：restructure model + prompt 编辑（带「输入是残留/上一句要点」提示）<!-- restructure 作为 RoleConfigDialog 的一种 kind（model+label+prompt版本）；重组动作的 source(复述上一句/补打断残留)在规则编辑器选 -->
- [x] 6.5 主对话流（main）保持 + 整页布局对齐 voxen「多流路由」式（主流+重组流+裁判+规则）<!-- CampaignEdit 新增「多流路由」tab；main/referee/restructure 同在「AI 配置」tab，路由规则 + 主裁判 + 连续重组上限在「多流路由」tab -->
- [x] 6.6 存量单裁判 campaign 向后兼容呈现（不破坏）<!-- 单 referee(migration 补 label=main_judge) + seed 规则正常呈现；无 restructure 时重组动作不可选亦不报错；既有 campaignEdit/campaignTabs 测试更新后全绿 -->
- [x] 6.7 web 校验体验：删被引用裁判提示、规则引用非法 label 前端拦截 <!-- RoutingRulesTab：无裁判时禁用新增规则 + warning；referee 下拉只列存在的 label（无法选不存在的）；后端 409/422 经既有 errorBanner/fieldErrors 呈现 -->
- [x] 6.8 遵循 STYLE_GUIDE.md（--isales-* token，禁硬编码）；vitest 覆盖规则编辑器交互 <!-- RoutingRulesTab/RoleConfigTab 次要文字用 var(--isales-muted-foreground)；tests/routingRulesTab.test.ts 覆盖增删/调序/动作切换/无裁判禁用 -->

## 7. 验证 + 部署 + 收口

- [x] 7.1 `openspec validate engine-multi-referee-and-restructure --strict` 通过
- [x] 7.2 `make test-all` 各服务绿（engine/common/api 单测 + web vitest）<!-- common 176 / engine 333 / api 119(+2 redis-env pre-existing) / web 44 / telephony 345 / worker 50 / scheduler 37(+3 redis-env，无 redis-server)。本 change 0 回归；5 个失败全为无 redis-server 的环境失败（api start/pause + scheduler dispatch/control/loop），baseline 亦失败 -->
- [ ] 7.3 mac dev-no-modem e2e：配 2 裁判（意图有效性 + 拒绝识别）+ 重组流，验证「没接住→复述」「被打断→重说」「低置信→拖一轮」三场景 + goal_achieved 仍正常 <!-- 待真机：需起 engine + mac edge，本 session headless 无法跑；与 pipeline-stream-realmachine-acceptance 同属真机验收 -->
- [x] 7.4 SCP 部署 ECS engine/api + alembic upgrade + 给现网 campaign 跑 data migration seed 默认规则；更新 `deploy/cloud/STATE.md`（alembic head + 新字段）<!-- 2026-06-05 20:40：scp common+engine+api+scheduler editable 源码 + web rebuild；alembic f6a7b8c9d0e1→a7b8c9d0e1f2；seed 验证 campaign 1 main_judge+3规则 / campaign 2 未动；4 服务 restart clean + openapi 含 routing-rules(401) + SPA 200；备份 /opt/isales/backups/multi-referee-20260605-203424/pre.sql；STATE.md 已更新。踩坑：migration id 撞 appointment a1b2c3d4e5f6 → 改名 a7b8c9d0e1f2 后部署 -->
- [x] 7.5 RUNBOOK 写「migration 后给每个 campaign seed 默认 routing_rules」步骤 <!-- deploy/RUNBOOK.md §1 step 4 加 a7b8c9d0e1f2 data-migration 说明 + 验证 SQL + goal_type 收窄提示；migration 自动 seed，无需手动 -->
- [ ] 7.6 回写本 tasks.md（HTML 注释标 commit/PR/偏离）→ `/opsx:archive` <!-- 代码 task 全回写；archive 待 7.3 真机 + 7.4 部署 -->

> 实施记录（commits）：isales-common `e444d00`（§1）/ isales-engine `ad913a2`（§2-§4）→ 已 merge 回 main `dd739c4`（取分支版解 4 文件冲突，丢弃被取代的 91f7005 降延迟旧补丁；333 tests green）/ isales-api `9a4ea3c`（§5）/ isales-web `b2a447a`+`eccabc0`（§6）/ isales-scheduler `7b6a77f`（dial snapshot 修正）。偏离：(1) proposal 说 scheduler「完全不动」实际需改 pack_prompt_versions（referee_llm→referee_llms）；(2) §1.9 只升 engine/api/scheduler 的 common pin 到 0.7（worker/telephony 不消费改动的 schema，pin 不动）；(3) data-migration goal_type 由动态收窄为静态 seed "appointment"。
