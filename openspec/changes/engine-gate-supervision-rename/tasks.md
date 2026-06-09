# Tasks — engine-gate-supervision-rename

> 约定：代码标识符（`RoleKind.REFEREE` / `kind='referee'` / `scope_type` / `HangupCause.REFEREE_HANGUP` / DB 列 / JSON key / 类名 / 文件名）**一律保留**，只改中文 display / 注释 / spec 叙述 / 过期契约。完成项用 `<!-- sha 备注 -->` 标注 PR#/commit/偏离。

## 1. Spec deltas（本 meta-repo）

- [ ] 1.1 `ai-pipeline`：MODIFIED — 删「旁路」(§AI 管线编排/Purpose 随文件)、钉死门控语义（await ALL / 超时→release / 永不 fail-closed / release=no-match 默认）、门控监管=纯分类器 + 门控路由=唯一 decider；契约改裸 token（删 `json_mode=True`→False、`{category,confidence}` JSON、`confidence<0.7`、`low_confidence`、`decision="transfer"`）
- [ ] 1.2 `role-prompt`：MODIFIED — 改「referee MUST 恰好 1 个」为「门控监管 MAY N 行(N≥0)」；门控监管 prompt 只输出闭集裸 category（无 JSON / 无 pass-hold）；术语 rename
- [ ] 1.3 `web-admin-ui`：MODIFIED — 删「referee 决策旁路 LLM」的旁路；编辑器提示从 JSON `{decision,goal_type,confidence}` 改为「单个 category 词」；裁判/referee display → 门控监管
- [ ] 1.4 `data-model`：MODIFIED — 叙述性 referee→门控监管；显式标注 `referee_timeout_ms`/`referee_fail_open_route`/`REFEREE_HANGUP`/`referee_results` 等为保留标识符；`referee_fail_open_route` 语义注明为「永远 release，不 fail-closed」
- [ ] 1.5 `transcript`：MODIFIED — referee→门控监管；删 `low_confidence` fail-open marker（只留 timeout/invalid）
- [ ] 1.6 `openspec validate engine-gate-supervision-rename --strict` 通过

## 2. isales-engine

- [ ] 2.1 `referee.py`：删 `_USER_PRIMER` 的 pass/hold 硬编码（枚举全部来自 campaign prompt）；docstring side-band→gating、pass/hold 示例改中性、`invalid JSON`→`empty/invalid output`
- [ ] 2.2 `streaming/types.py`：删 `CONFIDENCE_THRESHOLD` / `effective_category` confidence-floor 死代码 + 相关 threshold 形参；docstring「category + confidence」→「裸 category token」
- [ ] 2.3 `pipeline/orchestrator.py`：注释 side-band→gating；module docstring 修正（play-then-judge 残留 → gate-first）
- [ ] 2.4 `providers/llm_mock.py`：`_REFEREE_PRIMER_MARK` 与 2.1 的 primer 改动 lockstep（换 enum-agnostic marker，保证 `_decide()` 仍识别 referee 调用）
- [ ] 2.5 `pipeline/__init__.py` / `streaming/__init__.py`：docstring「category + confidence」→「裸 category token」
- [ ] 2.6 `cd ../isales-engine && .venv/bin/python -m pytest -q` 全绿

## 3. isales-api

- [ ] 3.1 `scripts/seed_pipeline_stream_campaign.py`：`REFEREE_PROMPT` 改为裸 category 契约（**修 live bug**）——指示模型只输出闭集枚举里的一个词，无 JSON、无 decision/goal_type/confidence；`goal_type` 语义移到 goal_achieved 的 routing-rule action（prompt 不再产出 goal_type）
- [ ] 3.2 重新 seed / 更新现有 campaign 1 的 referee prompt（dev + ECS），使门控真正生效
- [ ] 3.3 `cd ../isales-api && .venv/bin/python -m pytest -q` 全绿

## 4. isales-web

- [ ] 4.1 display rename 旁路监管/裁判→门控监管：`PipelineTracePanel.vue`、`RoleConfigDialog.vue`(:17,:29,:135)、`RoleConfigTab.vue`(:86)、`CampaignDetail.vue`(:185,:189,:190)、`ToolsTab.vue`(:5,:13,:14,:19,:23,:41,:176)、`RoutingRulesTab.vue`(:5,:19,:24,:51,:52,:57,:59,:73)（v-model/prop/filter 的 `referee` 字面量保留）
- [ ] 4.2 `PipelineTracePanel.vue`(:57-66,122-137) + `types/call.ts`(:48-51)：从 scalar `{referee_decision,goal_type,confidence}` 改为渲染 `referee_results[]`（`{label,category,confidence,duration_ms}`）+ `selected_route_id`（**修 stale UI**）
- [ ] 4.3 `cd ../isales-web && npm run test` 全绿 + build 通过

## 5. isales-common

- [ ] 5.1 注释 side-band→gating：`enums.py`(:28)、`models/pipeline_trace.py`(:10,:61)、`schemas/pipeline.py`(:8-9,:38-39)、`schemas/call.py`(:80)（枚举值/字段名/类名保留）

## 6. meta-repo 根文档（同 commit 收口）

- [ ] 6.1 `DESIGN.md`(:14)：referee 旁路决策→referee 门控决策
- [ ] 6.2 `IMPLEMENTATION_PLAN.md`(:201,203,220,269,343,386)：裁判/旁路→门控监管/门控
- [ ] 6.3 复核 `README.md` / `CLAUDE.md` / `architecture` 概述无残留「旁路」（CLAUDE.md:15 英文 "referee LLMs gating" 已是 gating，保留）

## 7. 验证与部署

- [ ] 7.1 `make test-all` 四仓全绿
- [ ] 7.2 全仓 `grep -ri "旁路监管\|旁路\b\|裁判\|side-band"` 无残留（历史已废架构描述中的「裁判/润色」除外，per design D2/审计注）
- [ ] 7.3 ECS 部署（scp + restart，按 STATE.md 流程）+ 更新 seed referee prompt
- [ ] 7.4 真机抽验：确认 seed campaign 门控**首次真正生效**（规则触发挂断/转人工符合预期，非每轮静默放行）；结论写 `deploy/cloud/STATE.md`
- [ ] 7.5 `openspec validate engine-gate-supervision-rename --strict` → archive；协调 2 个 colliding change 的术语归并
