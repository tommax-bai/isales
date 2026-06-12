## Context

The campaign-level "勿打配置" shipped as a full CRUD surface (DB columns → common/api schemas → web `DoNotCallTab.vue`) ahead of its engine implementation. The engine half — an independent do-not-call LLM judge and an ASR keyword matcher — was deferred in `impl-engine` ("v1 mock") and never built. A 5-agent end-to-end trace + 8 adversarial verifiers (all `claim_holds=true`) confirmed zero behavior-changing runtime consumers of `do_not_call_keywords` / `do_not_call_llm_enabled` / `do_not_call_llm_prompt_version_id` across all 7 repos. This change removes the dead config surface while preserving the genuinely-live `do_not_call` lead-status outcome.

## Goals / Non-Goals

**Goals:**
- Drop the three dead `campaign.do_not_call_*` columns + FK, their schema fields, and the web `DoNotCallTab`.
- Keep the `do_not_call` terminal lead-status path fully intact (it is reachable today via routing-rule `goal_type='do_not_call'`).
- Reframe the `retry-followup` "勿打"识别 spec to describe the surviving marker-driven mechanism instead of the removed config-driven one.

**Non-Goals:**
- Not touching the sibling `transfer_llm_prompt_version_id` dead FK (belongs to the transfer feature whose enable-flag IS live; separate follow-up if desired).
- Not removing the worker `_has_do_not_call_marker` logic, `LeadStatus.DO_NOT_CALL`, the `do_not_call_marked` transcript handling, or the web "免打扰" lead-status display.
- Not building the do-not-call LLM judge (the opposite choice — explicitly rejected per the user's "删干净").

## Decisions

- **Delete config inputs, keep the outcome path.** The precise line: campaign-level *config* (keywords/LLM-enable/prompt-version) is dead and goes; the *outcome* (`lead.status=do_not_call`, set by the worker from a `goal_type`/transcript marker) is live and stays. The marker is produced by the generic routing-rule pipeline, not by anything being removed here.
- **`retry-followup` "勿打"识别 keeps its header name.** The "双重 OR 关系" name still fits: after removal the two OR arms are (1) `call_summary.goal_type=='do_not_call'` and (2) the `do_not_call_marked` transcript event — exactly what worker `lead_state._has_do_not_call_marker` already checks. So the requirement is MODIFIED (reframed body), not RENAMED — avoids the RENAMED+MODIFIED archive footgun.
- **Migration is a plain destructive drop.** New revision `b9c0d1e2f3a4` (down_revision `a8b9c0d1e2f3`): drop FK `fk_campaign_do_not_call_llm_prompt_version_id_prompt_version`, then drop the 3 columns. Downgrade re-adds them with their original `nullable`/`server_default`. Existing column data is discarded — it was never consumed, so there is nothing to migrate out.
- **No engine/scheduler/worker/telephony code change.** Confirmed zero references in those repos. `isales-api` needs no router change either: `update_campaign` is a generic `model_dump→setattr` passthrough and `_load_detail` iterates `Campaign.__table__.columns`, so dropping the columns + schema fields is sufficient.
- **`prompt_version.scope_id` comment scrub.** `models/prompt.py:24-25` lists `do_not_call_llm` as an example scope owner; remove that mention (leave the `transfer_llm` example, which is out of scope).

## Risks / Trade-offs

- [Consumer pins lag the `0.8.14` bump] → bump `isales-common` to `0.8.14`; consumers that import `CampaignBase`/`CampaignUpdate` only need a re-pin, not code changes (they never referenced the removed fields). `make test-all` after re-pin catches any stray reference.
- [`retry-followup` `## Data Schema` table is a free-form section, not a `### Requirement:`] → the openspec delta engine only merges requirement blocks, so the 3 `campaign.do_not_call_*` rows in that table (lines 182-184) will NOT be auto-removed at archive. **Mitigation:** an explicit archive-phase task strips those 3 rows by hand when `openspec/specs/retry-followup/spec.md` is finalized (consistent with the repo's partly-manual archive discipline).
- [Someone relied on the do-not-call config being "almost wired"] → it never worked; removing it changes no runtime behavior. The do-not-call *outcome* still works via routing rules.

## Migration Plan

1. isales-common: edit model/schemas/comment, add migration `b9c0d1e2f3a4`, bump `0.8.14`, update tests, `pytest` + `alembic upgrade head` on a scratch DB.
2. isales-api: drop the 3 schema fields + fix the test, re-pin common `0.8.14`, `pytest`.
3. isales-web: delete `DoNotCallTab.vue`, scrub `CampaignDetail.vue` + `campaign.ts` + test, `vitest`.
4. `make test-all` + `make spec-validate` (`openspec validate remove-do-not-call-campaign-config --strict`).
5. Deploy: run alembic `upgrade head` on the cloud DB during the common deploy; restart api; rebuild/redeploy web. Rollback = `alembic downgrade a8b9c0d1e2f3` + revert common pin.
