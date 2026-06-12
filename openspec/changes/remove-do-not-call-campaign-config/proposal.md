## Why

The campaign-level "勿打配置" (`do_not_call_keywords` / `do_not_call_llm_enabled` / `do_not_call_llm_prompt_version_id`) is dead config: stored, exposed in the admin UI (`DoNotCallTab.vue`), but read by nothing at runtime. A 5-agent end-to-end trace plus 8 adversarial verifiers confirmed there is no behavior-changing consumer in engine / scheduler / worker — the keyword arm has no ASR matcher, the independent-LLM-judge arm was deferred in `impl-engine` ("v1 mock") and never built, and the prompt-version FK cannot even reach the engine (`PromptVersionsSnapshot` has no slot; scheduler `pack_prompt_versions` only walks `role_config`). Operators can toggle these controls and select a prompt version, and it silently does nothing. Removing the surface eliminates a confusing, misleading config panel and a dead FK.

## What Changes

- **BREAKING (DB schema)**: drop `campaign.do_not_call_keywords`, `campaign.do_not_call_llm_enabled`, `campaign.do_not_call_llm_prompt_version_id` and the FK `fk_campaign_do_not_call_llm_prompt_version_id_prompt_version`.
- Remove these three fields from `isales-common` `CampaignBase` / `CampaignUpdate` schemas and `isales-api` `CampaignUpdate`.
- Delete the web `DoNotCallTab.vue` panel, its mount + "勿打" card in `CampaignDetail.vue`, and the three fields from the `CampaignBase` TS type + `CAMPAIGN_DEFAULTS`.
- Scrub the `do_not_call_llm` mention in the `prompt_version` `scope_id` model comment.
- New alembic migration (`down_revision = a8b9c0d1e2f3`) dropping the FK + 3 columns; bump `isales-common` `0.8.13 → 0.8.14`.
- **Preserved (not a removal)**: the `do_not_call` terminal `lead.status` outcome path stays fully intact — `LeadStatus.DO_NOT_CALL`, worker `_has_do_not_call_marker` + Priority-1 branch, `do_not_call_marked` transcript handling, the web "免打扰" lead-status display, the `webhook-callback` `lead.status=do_not_call` trigger, and the `goal_type='do_not_call'` routing-rule path. Do-not-call as an *outcome* remains reachable via a routing rule; only the dead campaign-level *config inputs* go away.

## Capabilities

### New Capabilities
<!-- none -->

### Modified Capabilities
- `retry-followup`: the "勿打"识别 requirement currently mandates two config-driven detection mechanisms (keyword match + independent LLM judge) keyed off `campaign.do_not_call_*`. Both are removed; the requirement is reframed so `do_not_call` is a terminal `lead.status` reached when a do-not-call marker is present (`call_summary.goal_type=='do_not_call'` from a routing rule, OR a `do_not_call_marked` transcript event), with worker clearing future schedule and MAY emitting `do_not_call_marked` for CRM callback. The three `campaign.do_not_call_*` rows are removed from the config field table.
- `data-model`: the `campaign` row drops the `do_not_call_keywords`, `do_not_call_llm_enabled`, `do_not_call_llm_prompt_version_id` columns.

## Impact

- **isales-common**: `models/campaign.py`, `schemas/campaign.py`, `models/prompt.py` (comment), new alembic migration, `pyproject.toml` version, `tests/test_schemas_dto.py`. Consumers must bump their pin to `0.8.14`.
- **isales-api**: `schemas.py`, `tests/test_campaigns_crud.py`. No router logic change (`update_campaign` is a generic `model_dump → setattr` passthrough; `_load_detail` iterates `__table__.columns`, so the read DTO drops the columns automatically).
- **isales-web**: delete `views/Campaigns/Tabs/DoNotCallTab.vue`; edit `views/Campaigns/CampaignDetail.vue`, `types/campaign.ts`, `tests/campaignDetail.test.ts`.
- **No change** to isales-engine / isales-scheduler / isales-worker / isales-telephony (zero references confirmed by grep).
- **Migration risk**: dropping NOT-NULL columns + a `use_alter` FK on `campaign`; data in those columns is discarded (it was never consumed). Downgrade re-adds the columns with their original defaults.
