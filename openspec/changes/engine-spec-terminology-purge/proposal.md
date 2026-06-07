## Why

The dual-LLM (`pipeline-stream-and-referee`), multi-referee
(`engine-multi-referee-and-restructure`), and flat/gate-first
(`engine-tools-multidialogue-gating`) migrations replaced the old engine
architecture but left **stale "AI 三层管线 / N 角色 PK / N×M 裁判 / 1 润色"
terminology in live specs that no active change otherwise touches**. This
actively misleads future readers and refactors. The engine code, top-level docs
(CLAUDE.md / README.md / IMPLEMENTATION_PLAN.md), and the planning blueprint were
already de-staled directly; the specs owned by `engine-tools-multidialogue-gating`
are reconciled inside that change. This change purges the leftover terminology
from the two specs neither of those touches.

## What Changes

- `interruption-detection` § 与 FILLER / WRAPPING_UP 状态的交互: the WRAPPING_UP
  simplified pipeline "单角色 LLM + 润色，不 PK 不裁判" → "仅 main LLM 流式，跳过 referee".
- `provider-abc` § 统一错误模型: the degradation path "候选淘汰 / 润色失败兜底" →
  "main LLM 流式异常兜底".

Pure terminology reconciliation — **no behavior change**, no code, no schema, no
deploy.

## Impact

- Specs: `interruption-detection`, `provider-abc` (MODIFIED, terminology only).
- Out of scope (handled elsewhere / blocked): `architecture` § 各仓库职责边界
  (already de-staled by the active `arch-cloud-edge-split`); `data-model` §
  表归属与全表清单 pipeline_trace row (already MODIFIED by the active
  `campaign-fixed-greeting` — would conflict; and it is a denormalized index whose
  authoritative field set lives in `transcript` § pipeline_trace, reconciled by
  `engine-tools-multidialogue-gating`); `role-prompt` `## Purpose` line (a
  non-Requirement section OpenSpec deltas cannot target — fix on that spec's next
  substantive revision). The `transcript` / `call-state-machine` / `ai-pipeline`
  terminology leftovers are folded into `engine-tools-multidialogue-gating`'s
  deltas (specs it already owns).
