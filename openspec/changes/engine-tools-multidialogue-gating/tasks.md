# Tasks — engine-tools-multidialogue-gating (change 3/3)

> Deploy order is a HARD invariant: **common → worker → engine** (CallEnded is enum-validated;
> engine MUST NOT emit `referee_hangup` before worker holds the enum, else CallEnded DLQs).
> All behavior risk is quarantined behind `ENGINE_USE_ROUTER`; production stays OFF until the
> real-machine gate (§9) passes; Phase-4 (§10) flips default ON + deletes legacy in ONE commit.

## 0. Pre-flight — supersede + cherry-forward

- [ ] 0.1 Mark `referee-hangup-action` superseded (do NOT implement as a 4th `DeciderAction.kind`; folded here as `tool:hangup`). Add a SUPERSEDED note to its proposal pointing here; keep folder as release-valve stopgap (blueprint §8).
- [ ] 0.2 Confirm change-2 (`engine-multi-route-dispatch`) is archived and its ai-pipeline ADDED delta is merged into live specs (avoids the multi-referee delta-overlap "互踩" — blueprint §5). ✔ verified pre-propose.
- [ ] 0.3 Re-read `## 6. MUST NOT silently drop` (blueprint) — every item below must survive flag-ON byte-identically except the deliberate behavior changes.
- [ ] 0.4 **Reconcile `call-state-machine-soften-guard` (active, 21/28; code shipped 2cb47bc, spec delta un-archived).** Its delta MODIFIES `状态集合` (advisory + `state_error`→`state_warning`); change-3's call-state-machine delta deliberately does NOT touch `状态集合` (touches `hangup_cause 单一来源` + adds StatusProjector). **soften-guard MUST archive BEFORE change-3's call-state-machine delta** so the live advisory text is in place. Verify no other active change MODIFIES change-3's target requirements before writing the apply.

## 1. isales-common 0.8.0 — schema + additive alembic (DEPLOY FIRST)

- [x] 1.1 `enums.py`: add `RoleKind.PERSONA`, `PromptScopeType.PERSONA`, `HangupCause.REFEREE_HANGUP`. `CallStatus` unchanged (+ projection docstring).
- [x] 1.2 `schemas/jsonb/tool_config.py` NEW: `HangupToolConfig{type:"hangup", closing_phrase?, interrupt?}` + `TransferToolConfig{type:"transfer"}` (NO phrase field — transfer reuses the single-source `campaign.transfer_phrases` via `_perform_handoff`) discriminated union.
- [x] 1.3 `schemas/jsonb/routing_rule.py`: add `RoutePersonaAction{type:"route", to, then_state?}` + `RouteToolAction{type:"tool", tool, then_state?}` + `ThenState` Literal `{LISTENING,WRAPPING_UP,ACTIVATING,TRANSFERRING,END}`; widen action union; keep legacy `transition`/`restructure` via removal-tracked shim (comment the removal trigger).
- [x] 1.4 `models/campaign.py`: `+tools` JSONB, `+persona_fanout_cap` (default 1, ≤3), `+referee_timeout_ms` (default ~600), `+referee_fail_open_route` (default "main").
- [x] 1.5 `models/pipeline_trace.py`: `+selected_route_id` (Text), `+selected_route_kind` (Text), `+persona_candidates` (JSONB). Existing referee_*/restructure_* unchanged. (Spec: transcript delta owns the canonical field enumeration; data-model ADDED records them. `表归属与全表清单` index intentionally NOT reconciled — see design Open Questions.)
- [x] 1.6 `schemas/messages/dial.py`: `+persona_llms[]` (mirror `referee_llms[]`: label + model + prompt_version_id).
- [x] 1.7 `schemas/pipeline.py`: `+PersonaSpec`, `+personas`, `+tools`.
- [x] 1.8 ONE additive alembic migration, down_rev `a7b8c9d0e1f2` (new columns + enum values only; no drops/renames → rollback needs no down-migration).
- [x] 1.9 Bump version `0.7.0 → 0.8.0`; build + publish package.
- [x] 1.10 Unit tests for the union schemas (tool_config / route&tool action discriminators) + alembic up/down smoke.

## 2. isales-worker — REFEREE_HANGUP bucket + pin fix (DEPLOY SECOND)

- [x] 2.1 **FIX stale pin** `isales-common>=0.5,<0.6 → >=0.8,<0.9` (pre-existing bug — worker already uses 0.7-era symbols; new enum requires 0.8).
- [x] 2.2 `lead_state.py`: add `REFEREE_HANGUP` to an **EXPLICIT no-auto-redial set** (do NOT rely on the catch-all "unrecognized cause → failed" fall-through — `apply_lead_state` swallows unknown causes to cause=None → normal/follow-up, the opposite of intent). MUST NOT enqueue retry, MUST NOT enqueue auto follow-up (retry-followup spec § "REFEREE_HANGUP 归入不自动重拨终态").
- [x] 2.3 Verify `callend.py` enum-validates `hangup_cause` against `HangupCause` (the DLQ guard) and now accepts `referee_hangup`.
- [x] 2.4 Tests: REFEREE_HANGUP → no retry + no follow-up; CallEnded with referee_hangup passes validation (no DLQ).

## 3. isales-api — persona/tool validation + tools threading

- [x] 3.1 Pin `isales-common >= 0.8,<0.9`.
- [x] 3.2 `role_configs.py`: add `PERSONA` to `_LABELLED_KINDS`; delete-guard for personas referenced by routing rules.
- [x] 3.3 `routing_validation.py`: `persona_labels_of()`; validate `route→persona` and `tool→alias`; emit `422 routing_rule_unknown_persona` / `422 routing_rule_unknown_tool` / `422 tool_alias_duplicate`.
- [x] 3.4 `campaigns.py`: thread `tools` through nested create/update + the routing-rules PUT path.
<!-- api 81173da (2026-06-08) — 偏离修复: 3.4 只改了 handler (campaigns.py:356 reads
     payload.tools) 但漏了 PATCH schema → CampaignNestedUpdate 没声明 tools/persona_fanout_cap/
     referee_timeout_ms/referee_fail_open_route → AttributeError → 每个 PATCH /campaigns/{id}
     都 500 (test_campaigns_crud.py 4 红). 补 4 字段后 4 红→10 绿. 这 4 个字段原先 create-only
     (AppModel extra='forbid' 下 PATCH 会 422)，补全后可编辑——是 §5.7 web 控件能落地的前提. -->

- [x] 3.5 API tests for the three 422s + tools round-trip.

## 4. isales-scheduler — persona prompt packing

- [x] 4.1 `prompt.py` `pack_prompt_versions`: pack `RoleKind.PERSONA` rows → `persona_llms[]` (label namespace isolated from referee labels). Pin 0.8.
- [x] 4.2 Test: campaign with personas packs `persona_llms[]` correctly; referee packing unchanged.

## 5. isales-web — routing/tools/persona editors + 422 fix

- [x] 5.1 `types/campaign.ts`: `PersonaSpec` / `ThenState` / `RoutePersonaAction` / `RouteToolAction` / `ToolConfig` types + defaults.
- [x] 5.2 `RoutingRulesTab.vue`: action editor gains 路由到角色(persona) + 工具(挂断/转人工) + `then_state` dropdown.
- [x] 5.3 `RoutingRulesTab.vue`: **fix the `goal_type`-on-target-switch 422 bug** — clear stale `goal_type`/branch fields when action target changes (cherry-forward from superseded change). Add `routingRulesTab.test.ts` case.
- [x] 5.4 `RoleConfigTab.vue` / `RoleConfigDialog.vue`: persona kind (label required); persona count cap (≤3) hint.
<!-- web a9c0af7 (2026-06-08) — 升级: 5.4 原本只做了 hint 文案，但 spec §5.4 ADDED 要求 BLOCK
     over-cap enabling (厂商对取消的投机 token 也计费). 现做成硬阻断: RoleConfigTab.onDialogSave
     在 main(1)+已启用人设 > persona_fanout_cap 时拒绝保存并保持 dialog 打开. cap 值由 CampaignEdit
     以 prop 传入 (依赖 §5.7 让 cap 可见可改). -->
- [x] 5.5 `ToolsTab.vue` NEW: hangup (closing_phrase / interrupt) + transfer texts; alias uniqueness.
- [x] 5.6 vitest for the editors; **build → scp → nginx reload** as one atomic step on deploy (don't interleave other commands).
- [x] 5.7 `RoutingRulesTab.vue`: 开口前门控 controls for the 3 orphan gating scalars — `persona_fanout_cap` (stepper [1,3]), `referee_timeout_ms` (number ms), `referee_fail_open_route` (select: main + personas + closing/recovery/restructure). They were in `types/campaign.ts` (§5.1) + rode `{...form}` but had NO input control — operators were stuck on defaults 1/600/"main".
<!-- web a9c0af7 (2026-06-08) — 新增覆盖缺口: §5.x 原无任何任务给这 3 个标量加控件 (data-model §1.4
     + engine §6.7/§6.11 用了它们，web 漏接). 放进 RoutingRulesTab 与同族 primary_referee_label /
     max_continuous_restructure 并列. 依赖 §3.4 修复才能在编辑时存进. -->
- [x] 5.8 Reachability: fix `CampaignList.vue` Edit-button route name `campaign-edit` → `operations-campaign-edit` (the only page mounting RoutingRules/Tools/RoleConfig tabs was unreachable via the button); add 「高级配置」 entry from customer-facing `CampaignDetail.vue` to the full tab editor.
<!-- web a9c0af7 (2026-06-08) — 未被任何任务追踪的 bug: check:routes 之前应能抓到 campaign-edit
     不在定义集合 (22 routes)，修后 route lint clean. CampaignDetail (客户面场景详情) 原先无入口
     进 routing/tools/persona/gating/restructure，加按钮跳 operations-campaign-edit. -->


## 6. isales-engine Phase 3 — routes + gating + projector (behind ENGINE_USE_ROUTER)

> ✅ 2026-06-07 (engine commit `c49c4fb`). Implemented **cohesively in `run_loop._run_gated_turn` + `_select_gated_route`** (reusing `_play_streaming` / `_perform_handoff` / `_run_restructure` / `_await_referees` directly) rather than the separate `routes/*.py` file layout sketched below — the behavior (SelectRouter dispatch, eager generator, then_state) is what the spec requires; the file split is deferred to the Phase-4 cleanup. 365 passed/27 skipped, ruff clean.

- [x] 6.1 Extend dispatch: dialogue routes (`exec=eager`) hand the **live un-drained `sentences()` generator** (AGEN_CREATED via the orchestrator eager-buffer/replay); tool routes (`exec=lazy`) execute-on-select; routes carry `kind` + `then_state`.
- [x] 6.2 Dialogue routes: `main` + `persona:<label>` (eager candidates) + `closing`(MainSpec+WRAP_UP_APPEND, then_state=WRAPPING_UP) + `recovery`(then_state=ACTIVATING, fresh on select).
- [x] 6.3 Restructure route: referee-skipped re-voice (interrupt_remaining / low_confidence), then_state=LISTENING.
- [x] 6.4 Tool routes: `tool:hangup` (set `hangup_cause=REFEREE_HANGUP`, optional TTS closing_phrase, **suppress reply**, → END) + `tool:transfer` (wrap `_perform_handoff` → TRANSFERRING).
- [x] 6.5 `run_referees` as **eval_fn** gating (`_await_referees(timeout_s=referee_timeout_ms/1000)`); `_select_gated_route` maps `decide()` verdict → one route; first-match-wins + `category in match[]` verbatim (`decide()` widened for route/tool + legacy shim).
- [x] 6.6 Build candidate route table from campaign personas/tools/routing_rules (in `_run_gated_turn`; reuses run_loop helpers directly — no import cycle).
- [x] 6.7 **Pre-reply gating**: eager-buffer main + personas on user-final (orchestrator `start_eager`); gate `await`s before releasing audio; timeout `campaign.referee_timeout_ms`; **fail-open to `referee_fail_open_route` ("main")**.
- [x] 6.8 StatusProjector = **`StateMachine` as the synchronous sole writer** (crux2 review: 4-state collapse makes `transition_to` idempotent + trivial, so a sync sole-writer beats a bus subscriber — no async race). Operates on the shipped advisory model (`state_warning`, never raises).
- [x] 6.9 Routes declare `then_state` only; `_run_gated_turn` projects it via the sole writer (WRAPPING_UP→`in_wrap_up`; recovery/main→IN_CALL no-op; transfer→TRANSFERRING; hangup→END). No route calls `transition_to` for driving.
- [~] 6.10 Terminal path: every terminal route sets `session.hangup_cause` (REFEREE_HANGUP / marked_for_handoff / wrap_up_completed) ✅. `session_finalizer` shielded-finalize + DECR snap-to-0 remains the **change-0 follow-up** (dial_consumer layer, needs a Redis double) — still pending.
- [x] 6.11 Wire `persona_fanout_cap` (clamp [1,3]); eager fan-out opt-in (default 1 = main only). (Personas loaded from `RoleKind.PERSONA` RoleConfig rows, not `persona_llms[]`.)
- [x] 6.12 Behind `RuntimeConfig.engine_use_router` (default OFF); `run_session` signature frozen (flag via config).

## 7. isales-engine Phase 3 — tests (must pass before any real dial)

- [x] 7.1 Golden double-flag: byte-stable scenarios (one_turn_hangup/silence) share one fixture across {OFF,ON} (gating columns dropped cross-flag); goal_achieved diverges (closing route) → dedicated `goal_achieved_wrapup.router_on.json`.
- [x] 7.2 `test_eager_dialogue_route_returns_live_generator`: AGEN_CREATED guard (in `tests/test_eager_buffer.py`).
- [~] 7.3 `test_status_projector`: subsumed by `test_state_machine.py` (4-state + idempotent + advisory `state_warning`, no raise) + golden double-flag (StatusChanged sequence). No dedicated file — the sync sole-writer (6.8) has no async write-ordering to test.
- [x] 7.4 `test_gating`: fail-open to main on referee timeout (`tests/test_gating.py`).
- [x] 7.5 `test_gating`: hangup suppresses reply + REFEREE_HANGUP + → END; transfer → handoff; unknown alias fails open.
- [x] 7.6 `test_gating`: persona select-one-cancel-rest, `persona_candidates`/`selected_route_id` in trace; cap clamp to 3.
- [x] 7.7 Full engine suite green (365 passed / 27 skipped) + ruff clean (changed files) + `openspec validate --strict`.

## 8. isales-engine Phase 3 — barge-in async cancel (deferred 2.5/2.7 from change-1)

- [ ] 8.1 Invert barge-in: VAD/partial monitor posts `InterruptRequested`; playback owner self-cancels (replace reach-across `current_speaking_task.cancel()`).
- [ ] 8.2 Update/replace `test_realtime_interruption` (it directly tests the monitor reach-across that this removes).
- [ ] 8.3 Note: this changes interrupt timing (call-143 signal-then-cancel race) — golden doesn't cover it; **MUST be validated on a real dial** (§9.2).

## 9. Real-machine UX gate (SIM7600 Windows rig — confirmed in hand: COM12 AT / COM11 audio)

> **2026-06-07 deploy + trigger-config DONE; real dials (9.2–9.6) PENDING user + phone.**
> - **Deployed to cloud via rsync** (first rsync deploy; see [[reference-ecs-github-egress]]):
>   common `9be81f6` + worker `633977c` + api `6147403` + scheduler `82906e3` (persona,
>   excl wake_event) + engine `67af3b6` (gate-first, **excl** multi-edge `cf59640`) + web
>   `46e5c79`. alembic `a7b8c9d0e1f2→b8c9d0e1f2a3`. Verified: 6 svc active, CallStatus 4-state,
>   gating cols present, engine clean startup (no live ENGINE_USE_ROUTER), SPA 200. Backup
>   `/opt/isales/backups/change3-20260607-192409/pre.sql.gz`. **No rollback flag = git revert.**
>   Full cloud snapshot in `deploy/cloud/STATE.md` 2026-06-07 block.
> - **campaign 1 configured for §9 triggers** (raw SQL, user-approved, schema-validated):
>   `campaign.tools` = `end_call`(hangup+closing_phrase) + `transfer_default`(transfer);
>   `routing_rules` += `customer_hangup→tool:end_call` + transfer migrated to `tool:transfer_default`;
>   main_judge prompt → new `prompt_version 7` adding `customer_hangup` category (old id=5 = rollback).
>   SQL kept at `C:\Users\tianx\codes\_gatefirst_config.sql`.
> - **device 3 (edge-01) reset `dialing→idle`** (call #157 residual).
> - **REMAINING to dial**: (a) user starts edge daemon `_run_daemon_dev.py` (.venv-3.12) → 4 READY +
>   grpc_connected; (b) reset a lead → `new` (only when daemon up + phone in hand — scheduler auto-dials):
>   `UPDATE lead SET status='new',retry_count=0,follow_up_count=0,next_call_at=NULL,last_hangup_cause=NULL WHERE id=2;`
>   (c) dial + say trigger lines; (d) capture pipeline_trace + transcript.
> - **Trigger lines**: hangup = "我不需要，你别再打了，挂了啊，再见。"; transfer = "你是机器人吧？给我转个真人，转人工。"; barge-in = talk over the AI mid-reply. (confidence ≥0.7 needed; speak clearly.)

- [x] 9.1 Deploy common(0.8) → worker → api/scheduler/web → engine. ✅ 2026-06-07 via rsync; gate-first unconditional (no flag — Phase-4 deleted it). Each layer smoked.
- [ ] 9.2 Real dial: **barge-in** mid-reply — verify async self-cancel race (no double-cancel, no lost lossless event), reply restructure works.
- [ ] 9.3 Real dial: **transfer** route → TRANSFERRING → connecting phrase → END.
- [ ] 9.4 Real dial: **referee hangup** route — gate selects `tool:hangup`, reply suppressed, optional closing_phrase, → END with `cause=referee_hangup`; CallEnded reaches worker (no DLQ); lead not auto-redialed.
- [ ] 9.5 Real dial: **eager persona** select-one (if enabling N>1) — verify cancelled-persona token billing acceptable; or keep N=1 for the gate.
- [ ] 9.6 Capture pipeline_trace + transcript from the gate dials; confirm wire contract byte-stable vs legacy.

## 10. Phase 4 — DELETE legacy + ENGINE_USE_ROUTER (engine commit `a7e5576`)

> ⚠️ Sequencing changed (user call 2026-06-07): Phase-4 ran **before** the §9
> real-machine gate. Rationale: git is the rollback (no runtime kill-switch
> needed); legacy code + the flag are a burden on future refactors
> ([[feedback-avoid-multilayer-fallback]]). The §9 real-machine gate is now a
> **deploy gate** (validate on SIM7600 before any customer deploy), not a
> flag-flip gate; rollback = `git revert` + redeploy.

- [x] 10.1 gate-first is now unconditional (no flag to flip — it IS the default).
- [x] 10.2 DELETED the legacy `_main_turn_loop` speak-then-judge body (~300 lines) + the change-2 effect-route adapter (`routes/effects.py` / `routes/selector.py` / `routes/builder.py` / `select_router.Router`+`ExecutableRoute`).
- [~] 10.3 `_await_user_or_silence` is SHARED by gate-first (the pull-loop shell was kept) — NOT deleted. `_ManualHangupRequested`/`request_manual_hangup`/`main.cancel()` already migrated to the bus in change-1 (not present). Also deleted the now-dead `_cancel_referees`.
- [x] 10.4 DELETED `ENGINE_USE_ROUTER` (runtime_config + the settings read; `select_router.py` removed, `Directive` inlined). ✅ The now-dead `engine_use_router` field in `settings.py` was removed in the gRPC-WIP commit `cf59640` (2026-06-07, when that workstream was committed). NB: the **deployed** engine is `67af3b6` (pre-`cf59640`) so it still carries the dead field — harmless (no reader; verified run_loop has no live read), drops on the next engine deploy.
- [x] 10.5 Full suite 347 passed / 27 skipped; golden single-path green; ruff clean (changed files).
- [x] 10.6 Same-commit discipline: the deletion landed in one commit (`a7e5576`).

## 11. Folded-in (2026-06-08): per-keyword 挂断结束语 + 静音空话术直挂

<!-- Folded from the abandoned standalone change `engine-hangup-tool-and-sidecar-rehome`:
     gate-first already defines tool:hangup / tools schema / REFEREE_HANGUP / retry no-redial,
     so only these two genuine deltas land here. -->

- [x] 11.1 isales-common `schemas/jsonb/routing_rule.py`: `RouteToolAction` 增加可选 `closing_phrase?: str`（per-rule，命中时覆盖 `HangupToolConfig.closing_phrase`）。<!-- isales-common 5d72bc9 (0.8.0→0.8.1, additive optional). api routing_validation 单句校验留待 api 侧实装。 -->
- [x] 11.2 engine SelectRouter `tool:hangup`: 结束语按 per-keyword 优先解析（命中规则 `closing_phrase` → 工具配置 → 皆空则直挂）；同一 hangup 工具被不同关键字复用、各带话术。<!-- isales-engine b3f79b1 (flat branch engine-flat-change-0-golden-net): decider.py DeciderAction.closing_phrase + run_loop _GatedSelection.closing_phrase + 解析 sel.closing_phrase or tool_config or "". -->
- [x] 11.3 engine 静音超限挂断: `silence_hangup_phrase` 为空时直接挂断、删除 `outcome.text or "再见。"` 兜底（cause=`silence_max_reached`）。<!-- isales-engine b3f79b1: run_loop:535 `if outcome.text:` 才播 + runtime_config:309 `or ""`（不再 coerce 到默认话术）。 -->
- [ ] 11.4 web `RoutingRulesTab.vue`: 「挂断」动作每条规则可填单句结束语（留空标注"=直接挂断"）；支持同一 hangup 工具多关键字复用。<!-- DEFERRED 2026-06-08: web 正在做大改版，等其改完基于新版实装（用户指定）。 -->
- [x] 11.5 单测: OFFENSIVE/HANGUP 各取对应结束语 + 命中规则与工具配置皆空时直挂 + 静音空话术直挂。<!-- isales-engine b3f79b1: test_decider (carries closing_phrase ×2) + test_gating (per-rule override played / empty direct hangup) + test_run_loop (silence empty direct). engine 全套 381→384 passed, ruff clean. -->

> 11.1–11.3 + 11.5 实装完成 2026-06-08（common 5d72bc9 / engine b3f79b1@flat）。11.4 web 待大改版后实装。engine 改动在 flat 分支，未并回 main（同整套 voxen-flat stack）。

## 12. Archive discipline

- [ ] 12.1 `openspec validate --strict` for this change + `--specs` green before archive.
- [ ] 12.2 Record the two scope decisions (gating reconciliation D1, projector-moved-from-change-2) in this change's design.md (done) so future sessions don't re-litigate.
- [ ] 12.3 Update `project_engine_flat_refactor` memory + STATE.md files if deployment state changes (same commit as the deploy).
- [ ] 12.4 `/opsx:archive engine-tools-multidialogue-gating` — sync specs/, move to archive/.
