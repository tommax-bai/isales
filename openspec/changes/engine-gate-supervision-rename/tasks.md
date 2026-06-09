# Tasks — engine-gate-supervision-rename

> 约定：代码标识符（`RoleKind.REFEREE` / `kind='referee'` / `scope_type` / `HangupCause.REFEREE_HANGUP` / DB 列 / JSON key / 类名 / 文件名）**一律保留**，只改中文 display / 注释 / spec 叙述 / 过期契约。完成项用 `<!-- sha 备注 -->` 标注 PR#/commit/偏离。
>
> commit 索引：propose+spec deltas=`9ceb477`(meta) · engine=`44a8cea` · api=`b286a2b` · web=`27be846` · common=`3e9fb61` · meta apply(docs+本文件)=本次提交。

## 1. Spec deltas（本 meta-repo）

- [x] 1.1 `ai-pipeline`：MODIFIED — 删「旁路」、钉死门控语义（await ALL / 超时→release / 永不 fail-closed / release=no-match 默认）、门控监管=纯分类器 + 门控路由=唯一 decider；契约改裸 token <!-- 9ceb477 -->
- [x] 1.2 `role-prompt`：MODIFIED — 「referee MUST 恰好 1 个」→「门控监管 MAY N 行(N≥0)」；门控监管 prompt 只输出闭集裸 category <!-- 9ceb477 -->
- [x] 1.3 `web-admin-ui`：MODIFIED — 删旁路；编辑器提示 JSON→单个 category 词；裁判/referee→门控监管 <!-- 9ceb477 -->
- [x] 1.4 `data-model`：MODIFIED — 叙述 rename；标注保留标识符；`referee_fail_open_route`=「永远 release，不 fail-closed」 <!-- 9ceb477 -->
- [x] 1.5 `transcript`：MODIFIED — rename；删 `low_confidence` fail-open marker（只留 timeout/invalid） <!-- 9ceb477 -->
- [x] 1.6 `openspec validate engine-gate-supervision-rename --strict` 通过；18 MODIFIED 标题全匹配源 spec <!-- 9ceb477 -->

## 2. isales-engine

- [x] 2.1 `referee.py`：`_USER_PRIMER` 去 pass/hold → 中性「分类词」；docstring side-band→gating / pass-hold 示例中性化 / invalid JSON→empty-invalid output <!-- 44a8cea -->
- [x] 2.2 `streaming/types.py`：删 `CONFIDENCE_THRESHOLD` + `effective_category` confidence-floor 死代码 + threshold 形参；docstring 改裸 token <!-- 44a8cea -->
- [x] 2.3 `pipeline/orchestrator.py`：注释 side-band→gating；module docstring 从 play-then-judge → gate-first <!-- 44a8cea -->
- [x] 2.4 `providers/llm_mock.py`：`_REFEREE_PRIMER_MARK`「pass 或 hold」→「分类词」lockstep <!-- 44a8cea -->
- [x] 2.5 `pipeline/__init__.py` docstring 改裸 token；`streaming/__init__.py` 无该串(已是 RefereeResult 措辞)，skip <!-- 44a8cea -->
- [ ] 2.6 engine pytest 全绿 — **directly-affected 53 + 329 collectable passed**；`test_gating`/`test_run_loop`/`test_golden_transcript` 等 10 模块被 **pre-existing `FillerSet` ImportError 阻塞**（filler-single-pool 在途 WIP，非本改动；clean-tree git stash 已复现）；连带改 3 个测试 mirror（test_decider/test_pipeline/test_providers）已绿 <!-- 44a8cea -->

## 3. isales-api

- [x] 3.1 `seed_pipeline_stream_campaign.py`：`REFEREE_PROMPT` 改裸 category 契约（**修 live bug**）；**偏离/扩展**：seed 重建 referee 为 label=NULL 会孤立 migration 装的 routing_rules → 一并加 `label='main_judge'` + `ROUTING_RULES`(3 条,goal_type 移到 goal_achieved action)；3 条经 RoutingRule schema 校验通过 <!-- b286a2b -->
- [ ] 3.2 重新 seed dev + ECS（使门控真正生效）— **部署步骤，未执行**
- [ ] 3.3 api pytest 全绿 — 被 pre-existing `FillerSet` ImportError 阻塞（conftest 导不进）；seed 改动经 `ast.parse` + RoutingRule schema 校验
## 4. isales-web

- [x] 4.1 display rename 旁路监管/裁判→门控监管（6 文件；v-model/prop/filter `referee` 字面量保留） <!-- 27be846 -->
- [x] 4.2 `PipelineTracePanel.vue` + `types/call.ts`：scalar `{referee_decision,...}` → `referee_results[]` + `selected_route_id` + `matched_rule`（修 stale UI；删 hardcoded decisionTag switch） <!-- 27be846 -->
- [x] 4.3 web 测试 + build — **67 vitest passed + vue-tsc/vite build 通过**（连带改 2 测试 mirror campaignEdit/routingRulesTab） <!-- 27be846 -->

## 5. isales-common

- [x] 5.1 注释 side-band→gating：`enums.py` / `models/pipeline_trace.py` / `schemas/pipeline.py` / `schemas/call.py`（枚举值/字段名/类名保留） <!-- 3e9fb61 -->

## 6. meta-repo 根文档（本次 meta apply commit）

- [x] 6.1 `DESIGN.md:14`：referee 旁路决策→referee 门控决策
- [x] 6.2 `IMPLEMENTATION_PLAN.md`(201/203/220/269/343/386)：裁判/旁路→门控监管/门控
- [x] 6.3 grep 确认 DESIGN/IMPLEMENTATION_PLAN 无残留旁路/裁判（历史三层 PK/judge/polish 架构描述除外）；CLAUDE.md 英文 "referee LLMs gating" 已正确，保留

## 7. 验证与部署

- [ ] 7.1 `make test-all` 四仓全绿 — **被 pre-existing `FillerSet` ImportError 阻塞**（filler-single-pool 在途 WIP）；per-repo 实测：engine directly-affected 绿 + web 全绿；待 filler WIP 收口后复跑
- [x] 7.2 全仓 grep `旁路监管/旁路/裁判/side-band` 无残留（各 agent grep clean）；故意保留：历史已废三层架构里的「裁判/润色」、`CHANGELOG.md`、已发 alembic migration docstring（冻结历史）
- [ ] 7.3 ECS 部署（scp + restart，按 STATE.md 流程）+ 更新 seed referee prompt
- [ ] 7.4 真机抽验：确认 seed campaign 门控**首次真正生效**（规则触发挂断/转人工符合预期，非每轮静默放行）；结论写 `deploy/cloud/STATE.md`
- [ ] 7.5 `openspec validate --strict` → archive；协调 `pipeline-stream-realmachine-acceptance` / `web-admin-scene-single-page-config` 两 colliding change 的术语归并

## ⚠️ 阻塞项（非本 change，需用户决断）

- **`filler-single-pool` 在途 WIP 横跨 4 仓未提交**（isales-common 删了 `FillerSet`，engine `call_session.py`/`filler_manager.py`/`runtime_config.py` + 多个 web Tab + 各仓 pyproject bump 半迁移），导致 `FillerSet` ImportError 阻塞 engine 10 个集成测试模块 + api 全量测试。本 change 的提交**未触碰**这些文件。需先把 filler-single-pool 收口（或 stash）才能跑全量 `make test-all` 与 §3.3/§2.6/§7.1。
