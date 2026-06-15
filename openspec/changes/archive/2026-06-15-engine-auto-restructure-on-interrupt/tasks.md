# Tasks — engine-auto-restructure-on-interrupt

> **2026-06-15 归档**：代码与 spec 已部署上线（common 0.8.11，alembic a8b9c0d1e2f3）；剩余打断真机验收（5.6）已合并至 `pipeline-stream-realmachine-acceptance` §3.2。7.7 是显式 out-of-scope 备注（vestigial cap 列留待后续 cleanup change）。

Repo legend: [common] isales-common · [engine] isales-engine · [api] isales-api · [web] isales-web · [meta] this repo.

## 1. isales-common — new column + schema + migration

- [x] 1.1 [common] `models/campaign.py`: add `auto_restructure_on_interrupt: Mapped[bool] = mapped_column(Boolean, nullable=False, server_default=sa.false(), default=False)` near the restructure columns (`max_continuous_restructure` ~L55) with a comment tying it to ai-pipeline § 被打断自动重组开关.
- [x] 1.2 [common] `schemas/campaign.py`: `CampaignBase` += `auto_restructure_on_interrupt: bool = False`; `CampaignUpdate` += `auto_restructure_on_interrupt: bool | None = None`. (`CampaignCreate` / `CampaignRead` inherit.) Confirm `extra="forbid"` base still validates — field MUST be present in all三 variants.
- [x] 1.3 [common] Migration `alembic/versions/a8b9c0d1e2f3_add_campaign_auto_restructure_on_interrupt.py`: `add_column` Boolean NOT NULL `server_default=sa.false()`; downgrade drops. `down_revision="f7a8b9c0d1e2"`. **MUST** run `alembic heads` first → confirm single head `f7a8b9c0d1e2` and chosen revision id does NOT collide (see `[[feedback-alembic-revision-id-collision]]`); pick a different id if `a8b9c0d1e2f3` is taken.
- [x] 1.4 [common] Bump `pyproject.toml` version 0.8.10 → 0.8.11.
- [x] 1.5 [common] `pytest -q` green; fix any ORM fixture that constructs Campaign without the new NOT NULL field (unflushed ORM returns None → schema validation).

## 2. isales-engine — thread field + call-site override

- [x] 2.1 [engine] `pipeline/prompt_builder.py` `PipelineConfig`: add `auto_restructure_on_interrupt: bool = False` (alongside `routing_rules` / `restructure` / `max_continuous_restructure`).
- [x] 2.2 [engine] `runtime_config.py` (`load_runtime_config`, ~L211-237): thread `campaign.auto_restructure_on_interrupt` into the engine `PipelineConfig(...)` (mirror `max_continuous_restructure=campaign.max_continuous_restructure`).
- [x] 2.3 [engine] `run_loop.py` decide() call site (~L1296, `_run_gated_turn`): immediately after `action = decide(...)` and **before** `_select_gated_route(action, config)`, add the single override branch:
  ```python
  if (
      action.kind == "continue"
      and config.pipeline.auto_restructure_on_interrupt
      and config.pipeline.restructure is not None
      and session.interrupt_remaining_text
  ):
      # auto_restructure_on_interrupt: when the prior turn was barge-in
      # interrupted (interrupt_remaining_text set) and NO explicit routing rule
      # vetoed (decide() fell through to continue), resume the cut-off line
      # instead of replying. Removal trigger: drop when restructure routing is
      # made first-class per-rule with a default template. (ai-pipeline §
      # 被打断自动重组开关; engine-auto-restructure-on-interrupt)
      action = DeciderAction(
          kind="restructure",
          source="interrupt_remaining",
          restructure_trigger="interrupt_remaining",
      )
      logger.info("auto_restructure_on_interrupt fired (call=%s)", session.call_id)
  ```
  `decide()` stays pure (NOT touched). Downstream `_select_gated_route` + `max_continuous_restructure` cap apply unchanged.
- [x] 2.4 [engine] Bump `isales-common` pin `>=0.8.11,<0.9`; reinstall editable.
- [x] 2.5 [engine] Tests:
  - `tests/test_run_loop.py`: (a) switch ON + restructure slot + `interrupt_remaining_text` set + no rule match → restructure fires (`restructure_trigger="interrupt_remaining"`, `matched_rule is None`); (b) switch ON but an explicit rule matches → explicit route wins, NO override (veto); (c) switch ON but no restructure slot → continue, no error; (d) switch ON but `interrupt_remaining_text` empty → continue; (e) switch OFF → continue (byte-for-byte unchanged).
  - `tests/test_decider.py`: assert `decide()` itself is unchanged (still returns `continue` on no-match) — the override is call-site only.
  - `pytest -q` green (note any pre-existing unrelated fails, e.g. `test_gating::test_gate_fails_open_to_main_on_referee_timeout`).

## 3. isales-api — pin bump + allowlist passthrough

- [x] 3.1 [api] Bump `isales-common` pin `>=0.8.11,<0.9`; reinstall editable.
- [x] 3.2 [api] `schemas.py` `CampaignNestedUpdate` (hand-maintained allowlist mirroring CampaignBase): add `auto_restructure_on_interrupt: bool | None = None` — else PATCH silently drops it (same trap as `interruption-min-chars-and-mode-toggle` 3.2). `CampaignNestedCreate` / `CampaignDetailRead` inherit.
- [x] 3.3 [api] `pytest -q` green (note pre-existing Redis-steal env fails if present); add `test_auto_restructure_on_interrupt_create_default_and_patch` round-trip.

## 4. isales-web — type + toggle + test

- [x] 4.1 [web] `types/campaign.ts`: `CampaignBase` += `auto_restructure_on_interrupt: boolean;` (near `continuous_interruption_strategy`); `CAMPAIGN_DEFAULTS` += `auto_restructure_on_interrupt: false`.
- [x] 4.2 [web] `views/Campaigns/Tabs/InterruptionTab.vue`: add an `el-form-item` with `<el-switch v-model="form.auto_restructure_on_interrupt" />` **below the mode toggle**, mode-independent (always rendered, next to 最大连续打断 / 连续打断策略). Add a `.hint` with both作用与代价文案 (per web-admin-ui spec; no engine-internal terms).
- [x] 4.3 [web] No change needed in `CampaignDetail.vue buildPayload()` — it whitelists `Object.keys(CAMPAIGN_DEFAULTS)`, so the new key flows to PATCH automatically. Verify.
- [x] 4.4 [web] `tests/campaignTabs.test.ts`: add an InterruptionTab test mirroring the TransferTab switch pattern — mount, find the auto-restructure `el-switch`, click, assert `form.auto_restructure_on_interrupt` flips; assert the toggle renders in both modes. `vitest` + `npm run build` (vue-tsc + vite) green.

## 5. Validate + commit + deploy

- [x] 5.1 [meta] `openspec validate engine-auto-restructure-on-interrupt --strict` passes.
- [x] 5.2 Touched repos green: common 183p · engine 412p+1 pre-existing (`test_gate_fails_open_to_main_on_referee_timeout`, confirmed failing on stashed clean tree) · api 111p+2 pre-existing (`test_campaign_start_pause` Redis-steal by 3 legacy blpop daemons) · web vitest 90p + build green. <!-- done -->
- [x] 5.3 Committed: common cb108c9 · engine d0a5f1f · api 4a685a0 · web 1b3be9a · meta (this commit). Push next. <!-- done -->
<!-- 5.4-5.6 below: deploy + acceptance pending explicit go-ahead (prod RDS schema mutation). -->

- [x] 5.4 [deploy] Deploy to ECS/RDS: scp migration → `alembic upgrade head` (f7a8b9c0d1e2 → new) → scp common/engine/api → restart 4 services; web build rsync + nginx reload. Update `deploy/cloud/STATE.md` (alembic head) in the same commit. <!-- done 2026-06-12 09:43 CST: alembic f7a8b9c0d1e2->a8b9c0d1e2f3; 4 svc restart; web rsync entry index-CrRHl5l3.js; STATE.md updated -->
- [x] 5.5 [deploy] Smoke: alembic current = new head; column boolean NOT NULL default false; campaigns backfilled false; openapi has `auto_restructure_on_interrupt`; /health 200, /campaigns 401, SPA 200; engine + api boot clean. <!-- done: column boolean NOT NULL default false; camp 1+2 backfilled f; openapi has field; /api/docs 200 /api/campaigns 401 SPA 200; engine cloud_edge_grpc_server_started, 4 svc active -->
- [ ] 5.6 [accept] Real-machine / mac-dev演练: 用垫词("嗯""你继续")打断 → AI 自动续说被切的话; 真异议("我没空""多少钱")打断 → AI 正常回应 (验 veto). 记录到 acceptance.

## 7. Retire restructure routing action (folded-in cleanup, user decision 2026-06-12)

Restructure becomes switch-only; restructure is no longer a routing-rule action.
Verified 0 production campaigns use it before removal.

- [x] 7.1 [common] `routing_rule.py`: remove `RestructureAction` + `RestructureSource` from the union + `__init__` export + `__all__`; RoutePersonaAction docstring builtin = closing/recovery. bump 0.8.12 → 0.8.13. tests: restructure action now rejected (`test_routing_rule` / `test_pipeline_schemas` swapped to route). <!-- 189 passed -->
- [x] 7.2 [engine] `decider.py`: drop `atype=="restructure"` branch + `restructure_enabled` param (decide() never returns kind=restructure now). `run_loop.py`: drop `restructure` from `_BUILTIN_THEN` + drop `restructure_enabled` kwarg at call site; KEEP `kind=="restructure"` branch (switch produces it). pin 0.8.13. tests: removed obsolete rule-driven fires/caps + degrade tests. <!-- 412 passed +1 pre-existing gate -->
- [x] 7.3 [api] `routing_validation.py`: drop `restructure` from `_BUILTIN_ROUTES` (`route to=restructure` → 422). pin 0.8.13. `test_route_to_restructure_now_422`. <!-- 113 passed +2 pre-existing redis-steal -->
- [x] 7.4 [web] `RoutingRulesTab.vue`: remove 重组 route target + legacy restructure action option + source selector + fail-open restructure + onActionTypeChange restructure branch + intro text. `types/campaign.ts`: remove `RestructureAction`/`RestructureSource`. tests updated. <!-- vitest 90 + vue-tsc/build green -->
- [x] 7.5 [meta] spec deltas: ai-pipeline (decider 切重组流 scenario → restructure-不再是路由动作; 重组流 restructure MODIFIED → switch-triggered; InterruptText-source MODIFIED → interrupt_remaining only), data-model (routing_rules action MODIFIED — restructure removed). `openspec validate --strict` valid.
- [x] 7.6 [deploy] Re-deploy removal: diff-verify then scp common(routing_rule+__init__+pyproject)+engine(decider+run_loop)+api(routing_validation) → restart 4 svc; web rsync + nginx reload. **No new alembic** (schema-only, no DB column change). STATE.md updated. <!-- done 2026-06-12 11:19 CST: diff-verified 5 files identical→scp→restart 4 svc; import sanity (RestructureAction gone, type=restructure rejected, decide() 2-arg); web entry index-Bvjb8_tv.js; route to=restructure→422 path confirmed; switch kind==restructure branch intact -->
- [ ] 7.7 [followup] `max_continuous_restructure` cap column is now largely vestigial (switch restructure is one-shot — consumes interrupt_remaining_text, doesn't self-accumulate). Left in place; flag as a candidate for a later drop-column cleanup change. (Not removed here — out of scope.)

## 6. Archive

- [ ] 6.1 [meta] `openspec validate engine-auto-restructure-on-interrupt --strict` clean → `/opsx:archive engine-auto-restructure-on-interrupt`. At merge, also append `auto_restructure_on_interrupt` to the `data-model` 全表清单 campaign row (informational table not covered by requirement-level deltas). **Verify the change dir actually moved to `archive/`** (openspec archive is silent-failure on abort — see `[[feedback_openspec_archive_silent_failure]]`).
