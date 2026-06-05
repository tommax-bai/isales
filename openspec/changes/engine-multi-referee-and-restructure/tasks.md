# Tasks — engine-multi-referee-and-restructure

> 依赖：本 change 叠在 `pipeline-stream-and-referee` 之上。§0 是硬前置——未完成前不要动 §2+ 的 spec/代码 delta（否则两个 active change 互踩）。

## 0. 前置：pipeline-stream-and-referee 收口

- [ ] 0.1 跑完 `pipeline-stream-and-referee` 剩余 task（当前 87/105），确认 main/referee/extractor 链路在 mac dev e2e 绿
- [ ] 0.2 `openspec validate pipeline-stream-and-referee --strict` 通过
- [ ] 0.3 `/opsx:archive pipeline-stream-and-referee` — referee/main/extractor 需求合并进 `openspec/specs/`
- [ ] 0.4 archive 后回看本 change 6 个 spec delta：把对「单 referee」的 ADDED 表述，按需改写为对已合并 referee 需求的 MODIFIED（base 此时已存在），再 `openspec validate engine-multi-referee-and-restructure --strict`

## 1. isales-common：数据模型 + 枚举 + migration

- [ ] 1.1 `enums.py`：`RoleKind` 增加 `RESTRUCTURE = "restructure"`（集合变 `{main, referee, extractor, restructure}`）
- [ ] 1.2 `models/role_config.py`：新增 `label: Mapped[str | None] = mapped_column(String(64), nullable=True)`
- [ ] 1.3 `models/campaign.py`：新增 `routing_rules: Mapped[list] = mapped_column(JSONB, nullable=False, default=list)` + `max_continuous_restructure: Mapped[int]`（默认 2）+ `primary_referee_label: Mapped[str | None]`（低置信兜底用，见 design Open Q）
- [ ] 1.4 `models/pipeline_trace.py`：删单 referee 字段，改为 `referee_results JSONB`（数组）+ 新增 `matched_rule JSONB` / `restructure_active Bool` / `restructure_trigger String` / `restructure_source_text Text`
- [ ] 1.5 `call_record.prompt_versions` schema（Pydantic）：`referee_llm` → `referee_llms[]`（label+model+pv_id）+ 新增 `restructure_llm`
- [ ] 1.6 Pydantic schemas：RoutingRule / RoutingAction（transition|restructure）+ RefereeSpec 加 label/category 输出 + 新增 RestructureSpec
- [ ] 1.7 alembic migration（一支）：DDL（label 列 / routing_rules 列 / restructure 相关 campaign 列 / pipeline_trace 字段重构 / 放宽 referee 唯一约束、给 referee label 加同-campaign unique index）
- [ ] 1.8 同 migration 内 data migration：给每个现有 campaign 的单 referee 行补 `label="main_judge"`、标 `primary_referee_label`、seed 等价默认 `routing_rules`（goal_achieved→WRAPPING_UP / transfer / customer_decline + 低置信 restructure 规则）
- [ ] 1.9 bump isales-common 版本，更新 6 个消费仓 pin
- [ ] 1.10 isales-common 单测：RoleKind/restructure、RoutingRule 校验、prompt_versions schema round-trip

## 2. isales-engine：多 referee 并行 + 规则引擎

- [ ] 2.1 `runtime_config.py`：referee 装配从 `_first(REFEREE)` 改为取**全部** enabled referee → `list[RefereeSpec]`；加 `_restructure_spec(_first(RESTRUCTURE))`；`PipelineConfig` 加 `referees: list` + `restructure` + `routing_rules` + `max_continuous_restructure` + `primary_referee_label`
- [ ] 2.2 `streaming/types.py`：`RefereeResult` 改为 `{label, category, confidence, duration_ms}`（去 decision/goal_type 强语义）；新增 fail-open 构造
- [ ] 2.3 referee 调用层（`run_referee`）：输出契约改 `{category, confidence}`，prompt 注入该 referee 的枚举语义；保留 fail-open
- [ ] 2.4 `orchestrator.py`：单 `create_task` 改为 `asyncio.gather` 并行起全部 referee（与 main streaming 并行，不阻塞）
- [ ] 2.5 新增 decider 规则引擎模块：输入 `{label: category}` + routing_rules → first-match-wins → action（transition / restructure / continue）；referee 缺 category 不命中
- [ ] 2.6 `run_loop.py`：把 §701-730 的 referee-decision 分支替换为「decider 返回 action → 执行」；transition action 复用现有 transition_to / _perform_handoff 逻辑

## 3. isales-engine：重组流 + InterruptText 捕获

- [ ] 3.1 `call_session.py`（打断字段区 ~135 行后）：新增 `interrupt_remaining_text: str | None` + `consecutive_restructure_count: int`
- [ ] 3.2 barge-in 残留捕获：`run_loop.py` `_play_streaming` finally 丢弃路径（~1051-1053），在 `interruption_signaled` 时把**尚未送 TTS 的 sentence buffer 文本**拼接存入 `interrupt_remaining_text`（不改丢弃本身时序/取消语义）
- [ ] 3.3 restructure 执行路径：复用 main streaming→sentence→TTS，但 messages 仅 `[{system: restructure_prompt}, {user: InterruptText}]`（不带 history/用户最新句）；跑完直接回 LISTENING、不过 referee
- [ ] 3.4 InterruptText 来源装配：`source=last_reply` 取 dialog_history 末条 assistant；`source=interrupt_remaining` 取 `interrupt_remaining_text` 并取用即清空（空则退化 last_reply）
- [ ] 3.5 低置信兜底 (c)：primary referee `confidence < 阈值` 时走内置低置信 restructure 规则（替换原静默 continue 分支，**删旧分支不叠加**）
- [ ] 3.6 连续 restructure 封顶：达 `max_continuous_restructure` 改走 default_replies / 既有连续打断策略；正常 main 回复后清零
- [ ] 3.7 未配置 restructure 时 restructure action 退化为 continue（不报错）

## 4. isales-engine：pipeline_trace + 测试

- [ ] 4.1 `run_loop.py` pipeline_trace 写入（~615-639）：写 `referee_results` 数组 + `matched_rule` + `restructure_active/trigger/source_text`
- [ ] 4.2 单测：多 referee gather 并行 + 单个 fail-open 不影响其他
- [ ] 4.3 单测：decider first-match-wins（多规则命中取第一个）+ 无命中默认 continue
- [ ] 4.4 单测：restructure 三触发（last_reply / interrupt_remaining / 低置信）各自 InterruptText 正确、不带 history
- [ ] 4.5 单测：barge-in 残留捕获 → 下一轮 interrupt_remaining 重说；残留空时退化
- [ ] 4.6 单测：连续 restructure 封顶 + 单 referee 向后兼容（等价现状）
- [ ] 4.7 单测：restructure 跑完不再 spawn referee

## 5. isales-api：多 referee CRUD + 规则配置

- [ ] 5.1 `routers/role_configs.py`：去掉「恰好一个 referee」约束，支持 N 行 referee；加 `restructure` kind；写入校验 referee label 唯一非空
- [ ] 5.2 routing_rules 配置 endpoint（read/replace 整组有序规则）+ 校验：referee 指向存在 label、action.to 合法状态、action.source ∈ {last_reply, interrupt_remaining}、goal_achieved 必带 goal_type
- [ ] 5.3 删除 referee 时校验无 routing_rules 仍引用其 label
- [ ] 5.4 api 单测：多 referee CRUD + 规则校验（非法 label/越界 action 被拒）+ 删裁判引用保护

## 6. isales-web：多流路由配置页

- [ ] 6.1 `types/`：RoleKind 加 `restructure`；新增 RoutingRule / RoutingAction 类型；referee 配置改列表
- [ ] 6.2 裁判列表组件：增删 referee（label/model/prompt/枚举语义说明）
- [ ] 6.3 路由规则编辑器：有序增删 + 调序（顺序即优先级）+ 每条选 referee→匹配 category→action
- [ ] 6.4 重组流配置入口：restructure model + prompt 编辑（带「输入是残留/上一句要点」提示）
- [ ] 6.5 主对话流（main）保持 + 整页布局对齐 voxen「多流路由」式（主流+重组流+裁判+规则）
- [ ] 6.6 存量单裁判 campaign 向后兼容呈现（不破坏）
- [ ] 6.7 web 校验体验：删被引用裁判提示、规则引用非法 label 前端拦截
- [ ] 6.8 遵循 STYLE_GUIDE.md（--isales-* token，禁硬编码）；vitest 覆盖规则编辑器交互

## 7. 验证 + 部署 + 收口

- [ ] 7.1 `openspec validate engine-multi-referee-and-restructure --strict` 通过
- [ ] 7.2 `make test-all` 各服务绿（engine/common/api 单测 + web vitest）
- [ ] 7.3 mac dev-no-modem e2e：配 2 裁判（意图有效性 + 拒绝识别）+ 重组流，验证「没接住→复述」「被打断→重说」「低置信→拖一轮」三场景 + goal_achieved 仍正常
- [ ] 7.4 SCP 部署 ECS engine/api + alembic upgrade + 给现网 campaign 跑 data migration seed 默认规则；更新 `deploy/cloud/STATE.md`（alembic head + 新字段）
- [ ] 7.5 RUNBOOK 写「migration 后给每个 campaign seed 默认 routing_rules」步骤
- [ ] 7.6 回写本 tasks.md（HTML 注释标 commit/PR/偏离）→ `/opsx:archive`
