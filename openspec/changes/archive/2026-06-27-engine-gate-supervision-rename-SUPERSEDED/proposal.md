> **2026-06-27 SUPERSEDED / 撤回 — DO NOT IMPLEMENT。**
>
> 代码侧（纯分类器契约 + 删 confidence 死代码）已落各仓 origin/main（2026-06-09）并随后续部署上线；
> proposal 强调的 seed referee-prompt live bug 已由 `engine-filler-gated-restructure`（2026-06-15
> 在 prod 直接 SQL UPDATE camp1 referee prompt id=9）顺手修掉。但本 change 的「旁路/裁判→门控监管」
> **spec 改名目标已不可干净达成**：06-09 之后归档的 `engine-wrap-up-bypass-referee`（archive 06-17）、
> `engine-interruption-cover-thinking-window`（archive 06-20）等又把「旁路/裁判」术语大量写回 live
> specs（现存约 37 处），本 change 按 06-09 基线写的 18 条 MODIFIED delta 已与漂移后的 specs 冲突且
> 覆盖不全。撤回此 change；若仍要统一术语，另起一个覆盖新增项的 fresh purge change。

# 门控监管命名统一 + 纯分类器契约收口（engine-gate-supervision-rename）

## Why

「旁路监管 (referee)」这个名字与现行架构矛盾，职责被普遍误读，且其输出契约在多处停留在过期版本——其中一处是 live bug。

1. **命名与现实矛盾**：referee 自 `engine-tools-multidialogue-gating`（2026-06-08）起已是 gate-first **主路径门控**——主回复音频被 hold 到裁决返回才放行（`run_loop._run_gated_turn` 的 `await _await_referees` 严格早于唯一的 `telephony.audio_out`）。它的 LLM 在主对话**并行执行**（p50 ~0ms overlap），但控制流上是主路径**阻塞门**，不是旁路。「旁路 / side-band」是上一代 play-then-judge 架构的残留标签，散落在 4 处 spec/doc 与多处引擎注释。

2. **职责被误读**：referee 实际只输出一个 category；放行 / 选路 / 触发工具（hangup·transfer）全部由确定性 decider（门控路由）按 `routing_rules` first-match-wins 决定。命名与文档让人误以为 referee 自己在「判 pass/hold + 触发工具」两件事——实则它只分类，门控路由才是唯一决策者。

3. **输出契约多处过期（含 1 个 live bug）**：引擎实际已输出**裸 category token**（无 JSON、无 confidence、`json_mode=False`、`confidence` 由引擎钉死 1.0），但：
   - **[live bug]** seed `REFEREE_PROMPT` 仍要求输出 JSON `{decision, goal_type, confidence}` → 解析器取首 token = `{` → 永不命中任何 routing rule → **每轮 fail-open 放行、门控形同虚设**（seed dev/ECS campaign 1，已上线数据）。
   - `referee.py` 的 `_USER_PRIMER` 硬编码「请只输出一个词：pass 或 hold」，覆盖各 campaign 自定义枚举，与「引擎 MUST NOT 硬编码任何 referee 枚举值」相悖。
   - web `PipelineTracePanel.vue` + `types/call.ts` 仍渲染已删除的 scalar `{referee_decision, referee_goal_type, referee_confidence}`；spec `web-admin-ui` / `ai-pipeline` / `role-prompt` / `transcript` 仍写 `json_mode=True` / `{decision,goal_type,confidence}` / `{category,confidence}` JSON / `confidence < 0.7` / `low_confidence` 等已废契约（`streaming/types.py` 的 `CONFIDENCE_THRESHOLD` 已是死代码）。

## What Changes

把命名、概念、契约一次性对齐到现实，并按用户拍板的**方向 A**（fail-open-to-release / 工具触发 best-effort）钉死门控语义。

1. **rename 显示术语** 旁路监管 / 裁判 → **门控监管**（全仓 UI 文案 + 注释 + 文档 + spec 叙述）。
   **代码标识符一律保留**：`RoleKind.REFEREE` / `kind='referee'` / `PromptScopeType.REFEREE` / `HangupCause.REFEREE_HANGUP` / DB 列名（`referee_timeout_ms` 等）/ JSON key（`referee_results` / `referee_llms[]`）/ 类名（`RefereeSpec`）/ 文件名（`referee.py`）全部不动——改它们需 isales-common 版本 bump + alembic 枚举迁移 + 6 个消费方 pin，收益为零。

2. **删「旁路 / side-band」概念**：4 处含「旁路」的 spec/doc + 引擎英文注释 side-band → gating，统一表述为「门控监管 LLM 在主路径上并行执行、由门控路由裁决放行」。保留「并行执行」这一性能事实，只去掉「旁路」这一控制流位置的误导。

3. **钉死门控语义**（多为现状的正式化）：N 个门控监管并行；门控 SHALL `await` **全部** enabled 门控监管完成**或**超时；超时 / 失败一律 **fail-open 到 release**（默认 `referee_fail_open_route` = main），**永不 fail-closed / hold**，即使下游本应是 hangup / transfer（**best-effort，方向 A**）；无规则命中 → 默认 release（release 是 no-match 的默认动作）。

4. **门控监管 = 纯分类器；门控路由 = 唯一确定性 decider**：门控监管 prompt 只输出**一个闭集 category token**（无 JSON、无 confidence、无 pass/hold/放行 等决策动词）；放行 / 选路 / 工具触发全部由 `routing_rules` + decider 决定。落地包括：
   - 改 seed `REFEREE_PROMPT` 为裸 category 契约（**修 live bug**）；
   - 去掉 `_USER_PRIMER` 的 pass/hold 硬编码（枚举完全来自各 campaign prompt）+ 同步 `llm_mock.py` 的 dispatch mark；
   - 删 `streaming/types.py` 的 `CONFIDENCE_THRESHOLD` / `effective_category` confidence-floor 死代码（decider 侧已删，types 侧漏删——遵循「多层兜底是问题味道」）；
   - web `PipelineTracePanel.vue` + `types/call.ts` 改为渲染 `referee_results[]` 数组（**修 stale UI**）；
   - spec（ai-pipeline / role-prompt / web-admin-ui / transcript）契约文字统一为裸 token，删 `json_mode=True` / `{decision,goal_type,confidence}` / `{category,confidence}` / `confidence<0.7` / `low_confidence` / `decision="transfer"` 残留；修 `role-prompt` 「referee MUST 恰好 1 个」这条与多裁判矛盾的 stale 约束（门控监管 MAY N 行）。

## Impact

- **Specs**：`ai-pipeline`（主）、`role-prompt`、`web-admin-ui`、`data-model`、`transcript`。
- **Code**：`isales-engine`（`referee.py` / `pipeline/orchestrator.py` / `streaming/types.py` / `providers/llm_mock.py`：注释 + 死代码 + primer）、`isales-api`（`scripts/seed_pipeline_stream_campaign.py`）、`isales-web`（6 个 Vue：`PipelineTracePanel.vue` / `RoleConfigDialog.vue` / `RoleConfigTab.vue` / `CampaignDetail.vue` / `ToolsTab.vue` / `RoutingRulesTab.vue` + `types/call.ts`）、`isales-common`（注释 / docstring）。
- **无 DB 迁移、无 isales-common 版本 bump**（代码标识符全保留）。
- **协调**：与活跃 change `pipeline-stream-realmachine-acceptance`（ai-pipeline）、`web-admin-scene-single-page-config`（web-admin-ui）同 capability，requirement 不重叠；后归档者需把其 1–2 处 referee 措辞改为新术语。
- **行为影响**：修 seed live bug 后，seed campaign 的门控**首次真正生效**——需在部署后真机抽验，确认门控按预期触发（而非此前每轮静默放行）。
