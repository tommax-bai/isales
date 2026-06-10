## Why

The per-campaign barge-in "最小打断字数" (min character) gate is hardcoded to `2` in the engine's backward-compat default-tree synthesis (`runtime_config.py` → `default_rule(min_text_length=2)`), while its sibling "最小打断时长" (`interruption_min_duration_ms`) is a real configurable column. That asymmetry means operators can tune duration but not the字数 gate without dropping into the advanced rule-tree editor. At the same time, the web 打断 editor renders the basic fields and the advanced rule-tree editor simultaneously (divider-separated), which blurs which mode is active. This change promotes the hardcoded字数 threshold to a first-class campaign field and reworks the UI into an explicit basic/advanced mode toggle.

## What Changes

- Add campaign field `interruption_min_chars` (int, NOT NULL, default `2`, `ge=1`). The engine's default-tree synthesis (`interruption_rules == NULL` path) reads this field instead of the hardcoded `2`. Existing campaigns get the `2` default → behavior is byte-for-byte unchanged.
- Web admin (`isales-web`):
  - Rename the interruption card title 「打断保护」→「打断配置」.
  - Replace the always-both-visible basic+advanced layout with a **mutually-exclusive mode toggle**「高级设置 ∣ 非高级设置」. Mode derives from the existing `interruption_rules == NULL` sentinel (NULL = 非高级/basic, non-NULL = 高级/advanced); the two modes can never both be active.
  - 非高级设置 mode exposes: 打断白名单、最小打断时长、**最小打断字数** (binds to the new field).
  - 高级设置 mode shows the existing composable rule-tree editor.
  - 最大连续打断 and 连续打断策略 move below the toggle as **mode-independent** fields, always visible.
- Bump `isales-common` 0.8.7 → 0.8.8; consumers (`engine`, `api`) bump their pins.

No **BREAKING** changes — the new column defaults to `2`, the historical hardcoded value.

## Capabilities

### New Capabilities
<!-- none -->

### Modified Capabilities
- `interruption-detection`: the backward-compat default-tree synthesis (when `interruption_rules` is NULL) derives the `length` leaf from `campaign.interruption_min_chars` (default 2) instead of a hardcoded `2`; the per-campaign barge-in config field set gains `interruption_min_chars`.
- `data-model`: the `campaign` table gains column `interruption_min_chars` (int, NOT NULL, default 2).
- `web-admin-ui`: the 场景打断规则编辑 requirement changes from "default-state hint + seed button" to an explicit 非高级/高级 mode toggle; 非高级 mode exposes the 最小打断字数 field; the card title is 「打断配置」.

## Impact

- **isales-common**: `models/campaign.py` (new column), `schemas/campaign.py` (`CampaignBase`/`CampaignUpdate`), new Alembic migration (down_revision `e6f7a8b9c0d1`), version 0.8.7→0.8.8.
- **isales-engine**: `runtime_config.py` default-tree synthesis reads `campaign.interruption_min_chars`; `isales-common` pin bump; tests.
- **isales-api**: `isales-common` pin bump (schema passthrough — verify no field allowlist blocks it).
- **isales-web**: `types/campaign.ts` (field + `CAMPAIGN_DEFAULTS` + `defaultTreeFrom` signature), `views/Campaigns/Tabs/InterruptionTab.vue` (mode toggle + min-chars input + layout), `views/Campaigns/CampaignDetail.vue` (card title).
- **Deploy**: alembic upgrade on RDS + redeploy api/engine/web on ECS.
