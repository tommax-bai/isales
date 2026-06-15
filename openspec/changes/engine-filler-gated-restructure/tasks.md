# Tasks — engine-filler-gated-restructure

Repo legend: [engine] isales-engine · [api] isales-api · [meta] this repo.

> 依赖：`engine-auto-restructure-on-interrupt`（archived 2026-06-15）的开关 / restructure slot / `max_continuous_restructure` / restructure route 执行路径。本变更只收紧"自动改判 restructure"的触发条件 + 加门控信号 + 清残句不变量。**无 isales-common / alembic / isales-web 改动。**
> **OQ 已定（2026-06-15）**：生产 camp1 用 `HANGUP/SUCCESS/CONTINUE` 基线 + 新增 `FILLER`；类别值统一大写 `FILLER`，引擎默认 `restructure_gate_category="FILLER"`。seed 脚本保持自身 `goal_achieved/...` 基线、仅加 `FILLER`（详见 design.md OQ 决议）。
> **代码已 apply + commit（engine `9484274` / api `f50f5de`），未部署。**

## 1. isales-engine — PipelineConfig 保留类别 + 门控占位符注入

- [x] 1.1 [engine] `pipeline/prompt_builder.py` `PipelineConfig`：新增 `restructure_gate_category: str = "FILLER"`。 <!-- 9484274 引擎默认值，v1 不从 campaign 读 -->
- [x] 1.2 [engine] `referee.py` `run_referee`（已持有 `session` 首参）：替换链追加 `{{was_interrupted}}`（`getattr(session,"interrupt_remaining_text",None)` → 是/否）/ `{{interrupted_reply}}`（残句 or ""），**只读不清**；旧 prompt 无占位符 → no-op。 <!-- 9484274 -->
- [x] 1.3 [engine] 确认 `runtime_config.py` 无需改（用 PipelineConfig 默认）。 <!-- 9484274 未动 runtime_config -->

## 2. isales-engine — override 收紧 + 跨轮清残句

- [x] 2.1 [engine] `run_loop.py` `decide()` 调用点：取主门控 FILLER 判定。 <!-- 9484274 **偏离 tasks 原写法**：原方案用 `next(... if r.label==referee_fail_open_route)` 已废（referee_fail_open_route 是路由名非 label，见对抗评审 blocker）。实装用 `gate_filler = any(r.effective_category() == config.pipeline.restructure_gate_category for r in referee_results)`——FILLER 是保留类别、只有主门控 prompt 定义它，其余 referee 枚举不含 FILLER，故 any() 在本设计前提下等价"主门控判 FILLER"且不误触；fail-open referee 的 effective_category()=None ≠ "FILLER" 安全。前提注释已锁在代码里。 -->
- [x] 2.2 [engine] override 分支 = filler-gated（`gate_filler and action.kind=="continue" and 开关 and slot and 残句` → restructure，复用 `restructure_trigger="interrupt_remaining"`）+ `elif 开关 and 残句` → 清空 `interrupt_remaining_text`（D6 跨轮残句卫生）。`decide()` 保持纯函数。 <!-- 9484274 -->

## 3. isales-engine — mock + 测试

- [x] 3.1 [engine] `providers/llm_mock.py` `_referee`：垫词输入（`嗯你继续|嗯嗯|你继续|你说|对对对|继续说`）→ `FILLER`；其余分支不变。 <!-- 9484274 -->
- [x] 3.2 [engine] `tests/test_run_loop.py`：`test_auto_restructure_fires_when_gate_says_filler`（FILLER→fire）改名/语义更新；新增 `test_auto_restructure_skipped_when_gate_says_substantive`（实质→不 fire + 残句清空）；既有 noop/veto 用例仍绿（靠 no-slot / no-remainder / 显式规则）。 <!-- 9484274 -->
- [x] 3.3 [engine] `tests/test_referee.py`：新增 `test_interrupt_placeholders_injected_when_barge_in` / `..._blank_when_no_barge_in`（SimpleNamespace session，断言 是/否 + 残句注入）。 <!-- 9484274 -->
- [x] 3.4 [engine] `pytest -q`：本变更新增/改的测试全绿；engine 全量 436 passed，**唯一失败 `test_gating.py::test_gate_fails_open_to_main_on_referee_timeout` 是 pre-existing**（stash 我的改动后照样红，与本变更无关）。 <!-- 9484274 -->

## 4. isales-api — seed 门控 prompt 改写

- [x] 4.1 [api] `scripts/seed_pipeline_stream_campaign.py` `REFEREE_PROMPT`：保持 seed `goal_achieved/customer_decline/transfer/continue` 基线，新增 `FILLER` + `{{was_interrupted}}`/`{{interrupted_reply}}` 占位符 + FILLER/实质判别准则 + 非打断硬规则 + 10 条 few-shot（含"然后呢/残句进度"与"行行行→goal_achieved"两 disambiguation）。`FILLER` 不入 `ROUTING_RULES`（注释已说明走 override）。 <!-- f50f5de py_compile OK，无测试硬编码该 prompt -->
- [x] 4.2 [api] seed `FILLER` 大写与引擎默认一致；seed 其余标签与 seed `ROUTING_RULES.match` 本就一致（不改）。 <!-- f50f5de **生产 camp1 的 HANGUP/SUCCESS/CONTINUE/FILLER prompt 改在 §5.3 写入 DB**，camp1 routing_rules 是否 ["HANGUP"]/["SUCCESS"] 待 §5.3 ssh 核实 -->

## 5. 验证 + 部署

- [x] 5.1 [meta] `openspec validate engine-filler-gated-restructure --strict` 通过；MODIFIED header 与主 spec 逐字匹配。
- [x] 5.2 [engine] scp `prompt_builder.py`/`run_loop.py`/`referee.py`/`providers/llm_mock.py` → ECS `/opt/isales/current/isales-engine/isales_engine/` + 重启 engine（active、`isales_engine_started` 无 traceback；import 验证 `restructure_gate_category=FILLER` + `gate_filler` in run_loop）。 <!-- 9484274 部署 2026-06-15 15:07 CST -->
- [x] 5.3 [api] camp1（id=1）门控 prompt（`prompt_version` id=9）dollar-quoted SQL 原地 UPDATE → HANGUP/SUCCESS/CONTINUE/FILLER 版（含占位符，1601 字符，旧内容备份 ECS `/tmp/camp1_referee_id9_backup.txt`）；ssh 核实 camp1 已 `auto_restructure_on_interrupt=t` + restructure slot=1 + routing `SUCCESS→closing`/`HANGUP→hangup`（无 transfer）。 <!-- referee label 实为中文「主门控」≠ main_judge → override 用 any() 不 by-label 才对，已实证 -->
- [ ] 5.4 真机抽验合并到 `pipeline-stream-realmachine-acceptance`：①垫词打断（"嗯嗯你说"）→ AI 顺着说完；②实质打断（"那多少钱"）→ AI 正面作答（不重组）；③非打断正常对话不受影响。

## 6. 收尾

- [ ] 6.1 [meta] tasks.md 回写 PR#/commit；按需 bump 文档。
- [ ] 6.2 [meta] `openspec archive engine-filler-gated-restructure`（验证目录已移动，见 `[[feedback-openspec-archive-silent-failure]]`）。
