# Tasks — engine-spec-terminology-purge

> Pure live-spec terminology reconciliation after the dual-LLM / multi-referee /
> gate-first engine migrations. No code. Targets ONLY requirements no other
> active change modifies (verified: `campaign-fixed-greeting` owns data-model §
> 表归属与全表清单; `arch-cloud-edge-split` owns architecture § 各仓库职责边界 — both
> excluded to avoid delta "互踩").

## 1. Purge stale pipeline terminology

- [x] 1.1 `interruption-detection` § 与 FILLER / WRAPPING_UP 状态的交互 — WRAPPING_UP 简化管线 "单角色 LLM + 润色，不 PK 不裁判" → "仅 main LLM 流式，跳过 referee".
- [x] 1.2 `provider-abc` § 统一错误模型 — 降级路径 "候选淘汰 / 润色失败兜底" → "main LLM 流式异常兜底".
- [ ] 1.3 `openspec validate engine-spec-terminology-purge --strict`.

## 2. Known leftovers (NOT in this change)

- [ ] 2.1 `role-prompt` `## Purpose` "AI 三层管线" — non-Requirement section; OpenSpec deltas can't target Purpose. Fix manually on role-prompt's next substantive revision.
- [ ] 2.2 `data-model` § 表归属与全表清单 pipeline_trace single-referee fields — blocked: `campaign-fixed-greeting` already MODIFIES this requirement. Reconcile when that archives (the authoritative pipeline_trace field set is owned by `transcript` § pipeline_trace, already reconciled by engine-tools-multidialogue-gating).

## 3. Archive

- [ ] 3.1 Archive AFTER `engine-tools-multidialogue-gating` (no requirement overlaps it; archiving order keeps live specs consistent).
