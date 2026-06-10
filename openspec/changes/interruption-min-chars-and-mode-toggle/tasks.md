# Tasks — interruption-min-chars-and-mode-toggle

Repo legend: [common] isales-common · [engine] isales-engine · [api] isales-api · [web] isales-web · [meta] this repo.

## 1. isales-common — new column + schema + migration

- [x] 1.1 [common] `models/campaign.py`: add `interruption_min_chars: Mapped[int] = mapped_column(Integer, nullable=False, server_default="2", default=2)` next to `interruption_min_duration_ms`. <!-- done -->
- [x] 1.2 [common] `schemas/campaign.py`: `CampaignBase` += `interruption_min_chars: int = Field(default=2, ge=1)`; `CampaignUpdate` += `interruption_min_chars: int | None = Field(default=None, ge=1)`. (`CampaignCreate`/`CampaignRead` inherit.) <!-- done -->
- [x] 1.3 [common] Migration `alembic/versions/f7a8b9c0d1e2_add_campaign_interruption_min_chars.py`: `add_column` NOT NULL `server_default="2"`; downgrade drops. `down_revision="e6f7a8b9c0d1"`; `alembic heads` → single head `f7a8b9c0d1e2`, no id collision. <!-- done -->
- [x] 1.4 [common] Bump `pyproject.toml` version 0.8.7 → 0.8.8. <!-- done -->
- [x] 1.5 [common] `pytest -q` green (182 passed). Updated `tests/test_schemas_dto.py` fixture (unflushed ORM had None for the NOT NULL field). <!-- common 9a6f5be -->

## 2. isales-engine — read the field in default-tree synthesis

- [x] 2.1 [engine] `runtime_config.py`: `default_rule(min_text_length=campaign.interruption_min_chars)` (was hardcoded 2); comment updated. <!-- done -->
- [x] 2.2 [engine] Bump `isales-common` pin `>=0.8.8,<0.9`; reinstalled editable (pip reports 0.8.8). <!-- done -->
- [x] 2.3 [engine] Added `test_default_rule_honors_custom_min_text_length`; `pytest -k interruption` green (30 passed). Full suite 397 passed + 1 PRE-EXISTING unrelated fail (`test_gating::test_gate_fails_open_to_main_on_referee_timeout`, confirmed failing on clean tree). Also fixed stale `≥2` comment in run_loop.py (review nit). <!-- engine 71ce573 -->

## 3. isales-api — pin bump + passthrough verification

- [x] 3.1 [api] Bump `isales-common` pin `>=0.8.8,<0.9`; reinstalled editable (0.8.8). <!-- done -->
- [x] 3.2 [api] FOUND hand-maintained allowlist: `schemas.py CampaignNestedUpdate` mirrors CampaignBase fields → added `interruption_min_chars: int | None = Field(default=None, ge=1)` (else PATCH would silently drop it). `CampaignNestedCreate(CampaignBase)` + `CampaignDetailRead(CampaignRead)` inherit automatically. <!-- done -->
- [x] 3.3 [api] `pytest -q` → 107 passed + 2 PRE-EXISTING env fails (`test_campaign_start_pause` Redis-queue steal by legacy /opt/isales LaunchDaemons; zero refs to changed code). Added `test_interruption_min_chars_create_default_and_patch` round-trip (review finding). <!-- api 007a5ed -->

## 4. isales-web — types, mode toggle, rename

- [x] 4.1 [web] `types/campaign.ts`: CampaignBase += `interruption_min_chars`; CAMPAIGN_DEFAULTS=2; `defaultTreeFrom(whitelist, minDurationMs, minChars)` 3rd arg → `length` leaf value. <!-- done -->
- [x] 4.2 [web] `CampaignDetail.vue`: 「打断保护」→「打断配置」. <!-- done -->
- [x] 4.3 [web] `InterruptionTab.vue`: el-radio-button mode toggle 「高级设置 ∣ 非高级设置」 derived from `interruption_rules == null`; advanced→`seedDefault()` (passes min_chars), basic→`restoreDefault()`. Guard: re-clicking 高级 doesn't re-seed/clobber an edited tree. <!-- done -->
- [x] 4.4 [web] 非高级 body: 白名单 + 最小时长 + **最小打断字数** (`el-input-number` `:min="1"`). 高级 body: `InterruptionRuleEditor`. <!-- done -->
- [x] 4.5 [web] 最大连续打断 + 连续打断策略 moved below toggle (mode-independent, always rendered). <!-- done -->
- [x] 4.6 [web] vitest 85 passed; `npm run build` (vue-tsc + vite) green. Added confirm-guard tests + edited-tree-clearing tests; updated `interruptionRuleEditor.test.ts` (defaultTreeFrom arity + replaced old null-state-UI assertions) and `campaignDetail.test.ts` (title). Confirm-guard on 高级→非高级 added per review medium finding. <!-- web 6ab90df -->

## 5. Validate + commit + deploy

- [x] 5.1 [meta] `openspec validate interruption-min-chars-and-mode-toggle --strict` passes. <!-- done -->
- [x] 5.2 Touched repos green (common/engine/api/web); only pre-existing unrelated fails noted in 2.3 / 3.3. <!-- done -->
- [x] 5.3 Committed: common 9a6f5be · engine 71ce573 · api 007a5ed · web 6ab90df · meta (this commit). Push next. <!-- done -->
- Review: 5-dim adversarial review (workflow) verdict=ship, 0 blockers; folded in 1 medium (web confirm-guard) + 1 low (api round-trip test) + 2 nits (engine comment, spec 800→400).
- [ ] 5.4 [deploy] `alembic upgrade head` on RDS; redeploy api/engine/web on ECS (scp + systemctl restart). Update `deploy/cloud/STATE.md` (alembic head + common 0.8.8) in the same deploy commit. **(needs user go-ahead — prod migration)**
- [ ] 5.5 [deploy] Smoke: PATCH a campaign's `interruption_min_chars` via api, GET back; confirm web 非高级 mode shows/saves.

## 6. Archive

- [ ] 6.1 [meta] `/opsx:archive interruption-min-chars-and-mode-toggle` — merge deltas into `openspec/specs/`. At merge, also append `interruption_min_chars` to the `interruption-detection` § Configuration table and (optionally) the `data-model` 全表清单 campaign row, since those informational tables are not covered by requirement-level deltas. Verify the change dir actually moved to `archive/` (openspec archive is silent-failure on abort).
