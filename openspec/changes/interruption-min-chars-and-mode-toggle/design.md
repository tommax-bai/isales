## Context

Barge-in判定 in `isales-engine` runs an ASR-partial through a composable rule tree (`isales_engine.realtime.interruption_rules`). When a campaign has not configured `interruption_rules` (the column is NULL — the common/default case), `runtime_config` synthesizes a backward-compat default tree:

```
AND( NOT keyword(match="exact", interruption_whitelist), length(value=2), duration(value_ms=interruption_min_duration_ms) )
```

`interruption_whitelist` and `interruption_min_duration_ms` are real campaign columns; the `length` leaf's `2` is a **hardcoded literal** (`default_rule(min_text_length=2)`). The `engine-interruption-rule-tree` change deliberately left it un-promoted. This change promotes it.

On the web side (`isales-web/.../InterruptionTab.vue`), the editor today shows the four basic fields AND the advanced rule-tree editor at the same time, separated by an `el-divider`; "mode" is implicit in whether `interruption_rules` is null. The card title is 「打断保护」.

## Goals / Non-Goals

**Goals:**
- Make the字数 (min-char) gate a first-class, per-campaign configurable field, symmetric with `interruption_min_duration_ms`.
- Preserve exact current behavior for every existing campaign (default `2`).
- Replace the implicit basic/advanced split with an explicit, mutually-exclusive UI mode toggle, keeping 最大连续打断 / 连续打断策略 as mode-independent fields.
- Rename the card 「打断保护」→「打断配置」.

**Non-Goals:**
- No change to the rule-tree evaluation engine, the `length` leaf semantics, or the advanced editor's node types.
- No Role-level or global override of the field (Campaign-level only, per the existing config-granularity rule).
- No change to `interruption_whitelist` / `interruption_min_duration_ms` / `max_continuous_interruptions` / `continuous_interruption_strategy` semantics.

## Decisions

**D1 — New column `interruption_min_chars` (not a frontend-only synthesis).**
The null-rule sentinel is the cleanest mode model: 非高级 = `interruption_rules` NULL + scalar columns drive the engine's synthesis; 高级 = explicit tree. To make字数 configurable in 非高级 mode *without* abandoning the null sentinel, the value must persist somewhere the engine reads — i.e. a real column. Alternative considered: have 非高级 mode synthesize and persist a tree (no new column). Rejected — it kills the null sentinel, forces shape-detection/reverse-extraction on load (round-trip ambiguity between basic and advanced), and leaves `min_chars` asymmetric with the already-real `min_duration_ms`. A real column is the consistent extension.

**D2 — Column shape: `Integer, NOT NULL, server_default="2", default=2`, schema `Field(ge=1)`.**
Mirrors `interruption_min_duration_ms` (NOT NULL + default). `server_default="2"` backfills existing rows at migration time so the NOT NULL add is safe and the engine never sees NULL. `ge=1` because a `length(value=0)` leaf would match the empty string (every silence partial), which is never a sensible barge-in gate; `1` is the floor. Default `2` reproduces today's hardcoded value byte-for-byte.

**D3 — Engine reads the column in the synthesis path only.**
`runtime_config` swaps `min_text_length=2` for `min_text_length=campaign.interruption_min_chars`. The advanced path (explicit `interruption_rules`) is untouched — a campaign that configured its own `length` leaf keeps that leaf. So `interruption_min_chars` affects *only* null-rule campaigns, exactly matching the 非高级 UI mode.

**D4 — UI mode toggle reuses the null sentinel; no new "mode" field.**
The segmented control 「高级设置 ∣ 非高级设置」 is pure presentation over `interruption_rules == null`. Switching to 高级 seeds the tree via `defaultTreeFrom(whitelist, minDurationMs, minChars)` (so the two modes are never simultaneously active); switching to 非高级 sets `interruption_rules = null`. This keeps a single source of truth and avoids a redundant persisted mode flag that could disagree with the rule state. `defaultTreeFrom` gains a third `minChars` arg so the seeded tree's `length` leaf matches what the engine would synthesize.

**D5 — Toggle order & default.** Display order follows the user's stated 「高级设置 ∣ 非高级设置」; the *selected* mode is derived from data, so a fresh campaign (rules null, default) lands on 非高级设置. 最大连续打断 + 连续打断策略 render below the toggle unconditionally.

## Risks / Trade-offs

- [Existing campaigns with a hand-built `length` leaf ≠ 2 in advanced mode] → unaffected: the field only feeds the null-rule synthesis; advanced trees keep their own leaf. No migration of tree contents.
- [NOT NULL column add on a populated `campaign` table] → `server_default="2"` backfills in the same DDL; no separate data migration, no NULL window.
- [api silently strips the unknown field] → verify `isales-api` uses common's `CampaignUpdate`/`CampaignRead` directly with no field allowlist; covered as an explicit apply task.
- [Web min-chars edited in 非高级 then user switches to 高级] → the seed uses the current min-chars value, so the advanced tree starts consistent with what basic showed; no surprise reset.

## Migration Plan

1. `isales-common` 0.8.7→0.8.8: model + schema + Alembic migration (down_revision `e6f7a8b9c0d1`). `make test` green.
2. `isales-engine` + `isales-api`: bump pin to 0.8.8, engine reads field, tests green.
3. `isales-web`: types + `InterruptionTab.vue` + `CampaignDetail.vue`; `npm run build` + vitest green.
4. Deploy: `alembic upgrade head` on RDS, redeploy api/engine/web on ECS, smoke a campaign PATCH round-trip of `interruption_min_chars`.

**Rollback:** the change is additive and default-preserving; `alembic downgrade -1` drops the column, and reverting the common pin restores the hardcoded `2`. No data loss for null-rule campaigns (they fall back to `2`).

## Open Questions

None — scope confirmed with the user (full-stack, real field).
