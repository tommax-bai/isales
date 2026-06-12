<!-- a3da1c8 isales-common §1 | 721b032 isales-api §2 | e6cd9e1 isales-web §3 — code applied + each repo self-tested green; §5 deploy/archive pending -->

## 1. isales-common — schema + model + migration

- [x] 1.1 `models/campaign.py`: delete the three `do_not_call_*` columns (the `# do-not-call (under retry-followup)` block) including the FK. <!-- a3da1c8 -->
- [x] 1.2 `models/prompt.py`: scrub the `do_not_call_llm` mention in the `scope_id` comment, keep `transfer_llm`. <!-- a3da1c8 -->
- [x] 1.3 `schemas/campaign.py`: delete the 3 fields from `CampaignBase` and from `CampaignUpdate`. <!-- a3da1c8 -->
- [x] 1.4 `tests/test_schemas_dto.py`: remove the 3 `do_not_call_*` keys (dict + kwargs blocks). <!-- a3da1c8 -->
- [x] 1.5 New alembic migration `b9c0d1e2f3a4` (down_revision `a8b9c0d1e2f3`): upgrade drops FK + 3 columns; downgrade re-adds. Confirmed `a8b9c0d1e2f3` was the sole head (no collision); new single head `b9c0d1e2f3a4`. <!-- a3da1c8 -->
- [x] 1.6 Bump `pyproject.toml` version `0.8.13 → 0.8.14`. <!-- a3da1c8 -->
- [x] 1.7 pytest **189 passed**; migration up→down→up round-trip on scratch DB `isales_migtest_dnc` verified (cols dropped → re-added → dropped), scratch DB dropped. <!-- a3da1c8 -->

## 2. isales-api — schema + test + re-pin

- [x] 2.1 `isales_api/schemas.py`: delete the 3 `do_not_call_*` fields from `CampaignUpdate`. <!-- 721b032 -->
- [x] 2.2 `tests/test_campaigns_crud.py`: remove the `do_not_call_llm_enabled` key. <!-- 721b032 -->
- [x] 2.3 Re-pin `isales-common>=0.8.14,<0.9` + reinstall editable common 0.8.14 in venv. <!-- 721b032 -->
- [x] 2.4 pytest: touched `test_campaigns_crud.py` **12/12 passed**. (2 failures in untouched `test_campaign_start_pause.py` = legacy `_isales` daemon Redis-steal, pre-existing/environmental, not this change.) <!-- 721b032 -->

## 3. isales-web — delete tab + scrub references

- [x] 3.1 Delete `src/views/Campaigns/Tabs/DoNotCallTab.vue`. <!-- e6cd9e1 -->
- [x] 3.2 `CampaignDetail.vue`: removed `import DoNotCallTab`, the 勿打 `card--gray` block, and scrubbed the 勿打 mention in the form comment. <!-- e6cd9e1 -->
- [x] 3.3 `src/types/campaign.ts`: removed the 3 fields from `CampaignBase` + `CAMPAIGN_DEFAULTS`. <!-- e6cd9e1 -->
- [x] 3.4 `tests/campaignDetail.test.ts`: removed the `"DoNotCallTab"` stub + dropped 勿打 from the section-title list + renamed `9 → 8`. <!-- e6cd9e1 -->
- [x] 3.5 vitest **90/90 passed**; `npm run build` (tsc) green. <!-- e6cd9e1 -->

## 4. Spec deltas + validation

- [x] 4.1 `specs/data-model/spec.md` (MODIFIED `表归属与全表清单`, campaign row minus 3 cols) + `specs/retry-followup/spec.md` (MODIFIED "勿打"识别, marker-driven) written.
- [x] 4.2 `openspec validate remove-do-not-call-campaign-config --strict` passes; `make spec-validate` PASS.
- [x] 4.3 `make test-all`: common/telephony/worker/web green; api(2)/scheduler(3)/engine(1) failures all pre-existing — 5× legacy-`_isales`-daemon Redis-queue-steal (engine:dial / campaign:control), 1× known engine gate-timeout test in untouched engine code. None caused by this change.

## 5. Deploy + finalize

- [ ] 5.1 Deploy: scp updated common/api to cloud, `alembic upgrade head` on cloud DB, restart `isales-api`; rebuild + redeploy `isales-web`. Verify campaign GET/PATCH still 200 and the 勿打 tab is gone. Update `deploy/cloud/STATE.md` (alembic head → `b9c0d1e2f3a4`, common → 0.8.14).
- [ ] 5.2 Doc sync: check meta-repo root docs (`DESIGN.md` / `IMPLEMENTATION_PLAN.md` / `README.md`) for any do-not-call config mention and reconcile in the same commit.
- [ ] 5.3 Archive prep: `openspec archive remove-do-not-call-campaign-config` (verify dir actually moved — archive is silent-failure). **During archive, ALSO hand-strip the 3 `campaign.do_not_call_*` rows from `openspec/specs/retry-followup/spec.md`'s free-form `## Data Schema` table — the requirement-only delta engine does not touch that section.**
