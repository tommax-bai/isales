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

- [ ] 1.1 `enums.py`: add `RoleKind.PERSONA`, `PromptScopeType.PERSONA`, `HangupCause.REFEREE_HANGUP`. `CallStatus` unchanged (+ projection docstring).
- [ ] 1.2 `schemas/jsonb/tool_config.py` NEW: `HangupToolConfig{type:"hangup", closing_phrase?, interrupt?}` + `TransferToolConfig{type:"transfer"}` (NO phrase field — transfer reuses the single-source `campaign.transfer_phrases` via `_perform_handoff`) discriminated union.
- [ ] 1.3 `schemas/jsonb/routing_rule.py`: add `RoutePersonaAction{type:"route", to, then_state?}` + `RouteToolAction{type:"tool", tool, then_state?}` + `ThenState` Literal `{LISTENING,WRAPPING_UP,ACTIVATING,TRANSFERRING,END}`; widen action union; keep legacy `transition`/`restructure` via removal-tracked shim (comment the removal trigger).
- [ ] 1.4 `models/campaign.py`: `+tools` JSONB, `+persona_fanout_cap` (default 1, ≤3), `+referee_timeout_ms` (default ~600), `+referee_fail_open_route` (default "main").
- [ ] 1.5 `models/pipeline_trace.py`: `+selected_route_id` (Text), `+selected_route_kind` (Text), `+persona_candidates` (JSONB). Existing referee_*/restructure_* unchanged. (Spec: transcript delta owns the canonical field enumeration; data-model ADDED records them. `表归属与全表清单` index intentionally NOT reconciled — see design Open Questions.)
- [ ] 1.6 `schemas/messages/dial.py`: `+persona_llms[]` (mirror `referee_llms[]`: label + model + prompt_version_id).
- [ ] 1.7 `schemas/pipeline.py`: `+PersonaSpec`, `+personas`, `+tools`.
- [ ] 1.8 ONE additive alembic migration, down_rev `a7b8c9d0e1f2` (new columns + enum values only; no drops/renames → rollback needs no down-migration).
- [ ] 1.9 Bump version `0.7.0 → 0.8.0`; build + publish package.
- [ ] 1.10 Unit tests for the union schemas (tool_config / route&tool action discriminators) + alembic up/down smoke.

## 2. isales-worker — REFEREE_HANGUP bucket + pin fix (DEPLOY SECOND)

- [ ] 2.1 **FIX stale pin** `isales-common>=0.5,<0.6 → >=0.8,<0.9` (pre-existing bug — worker already uses 0.7-era symbols; new enum requires 0.8).
- [ ] 2.2 `lead_state.py`: add `REFEREE_HANGUP` to an **EXPLICIT no-auto-redial set** (do NOT rely on the catch-all "unrecognized cause → failed" fall-through — `apply_lead_state` swallows unknown causes to cause=None → normal/follow-up, the opposite of intent). MUST NOT enqueue retry, MUST NOT enqueue auto follow-up (retry-followup spec § "REFEREE_HANGUP 归入不自动重拨终态").
- [ ] 2.3 Verify `callend.py` enum-validates `hangup_cause` against `HangupCause` (the DLQ guard) and now accepts `referee_hangup`.
- [ ] 2.4 Tests: REFEREE_HANGUP → no retry + no follow-up; CallEnded with referee_hangup passes validation (no DLQ).

## 3. isales-api — persona/tool validation + tools threading

- [ ] 3.1 Pin `isales-common >= 0.8,<0.9`.
- [ ] 3.2 `role_configs.py`: add `PERSONA` to `_LABELLED_KINDS`; delete-guard for personas referenced by routing rules.
- [ ] 3.3 `routing_validation.py`: `persona_labels_of()`; validate `route→persona` and `tool→alias`; emit `422 routing_rule_unknown_persona` / `422 routing_rule_unknown_tool` / `422 tool_alias_duplicate`.
- [ ] 3.4 `campaigns.py`: thread `tools` through nested create/update + the routing-rules PUT path.
- [ ] 3.5 API tests for the three 422s + tools round-trip.

## 4. isales-scheduler — persona prompt packing

- [ ] 4.1 `prompt.py` `pack_prompt_versions`: pack `RoleKind.PERSONA` rows → `persona_llms[]` (label namespace isolated from referee labels). Pin 0.8.
- [ ] 4.2 Test: campaign with personas packs `persona_llms[]` correctly; referee packing unchanged.

## 5. isales-web — routing/tools/persona editors + 422 fix

- [ ] 5.1 `types/campaign.ts`: `PersonaSpec` / `ThenState` / `RoutePersonaAction` / `RouteToolAction` / `ToolConfig` types + defaults.
- [ ] 5.2 `RoutingRulesTab.vue`: action editor gains 路由到角色(persona) + 工具(挂断/转人工) + `then_state` dropdown.
- [ ] 5.3 `RoutingRulesTab.vue`: **fix the `goal_type`-on-target-switch 422 bug** — clear stale `goal_type`/branch fields when action target changes (cherry-forward from superseded change). Add `routingRulesTab.test.ts` case.
- [ ] 5.4 `RoleConfigTab.vue` / `RoleConfigDialog.vue`: persona kind (label required); persona count cap (≤3) hint.
- [ ] 5.5 `ToolsTab.vue` NEW: hangup (closing_phrase / interrupt) + transfer texts; alias uniqueness.
- [ ] 5.6 vitest for the editors; **build → scp → nginx reload** as one atomic step on deploy (don't interleave other commands).

## 6. isales-engine Phase 3 — routes + gating + projector (behind ENGINE_USE_ROUTER)

- [ ] 6.1 Extend `select_router.py`: dialogue routes (`exec=eager`) hand the **live un-drained `sentences()` generator**; tool routes (`exec=lazy`) execute-on-select; routes carry `kind` + `then_state`; Router does NOT swallow exceptions.
- [ ] 6.2 `routes/dialogue.py`: `main` + `persona:<label>` + `closing`(MainSpec+WRAP_UP_APPEND, then_state=WRAPPING_UP) + `recovery`(then_state=ACTIVATING) eager dialogue routes.
- [ ] 6.3 `routes/restructure.py`: referee-skipped restructure route (interrupt_remaining / low_confidence), then_state=LISTENING.
- [ ] 6.4 `routes/tools.py`: `tool:hangup` (set `hangup_cause=REFEREE_HANGUP`, optional TTS closing_phrase, **suppress reply**, → END) + `tool:transfer` (wrap `_perform_handoff(trigger_type="referee_decision")`, then_state=TRANSFERRING).
- [ ] 6.5 `routes/referees.py` + `routes/selector.py`: `run_referees` as **eval_fn** (gating); selector maps `decide()` verdict → one route; first-match-wins + `category in match[]` verbatim.
- [ ] 6.6 `routes/builder.py`: build route table from campaign personas/tools/routing_rules; `EffectContext` injects run_loop helpers (avoid import cycle).
- [ ] 6.7 **Pre-reply gating**: `orchestrator.py` `start_buffering()` — eager-buffer main + personas on user-final; `_await_referees` → `run_referees` eval_fn; timeout 2.0s → `campaign.referee_timeout_ms` (~600ms); **fail-open to `referee_fail_open_route` ("main")** not "continue".
- [ ] 6.8 `status_projector.py` NEW: single subscriber on the **lossless lane**, sole writer of `session.state` (sole `transition_to` caller) + sole emitter of `StatusChanged`; projection map (blueprint §3). Operates ON the already-shipped advisory model (soften-guard / 2cb47bc: `transition_to` writes `state_warning`, never raises) — do **NOT** re-introduce raising or `state_error`.
- [ ] 6.9 `state_machine.py` → passive projector; remove `transition_to` *driving* calls from routes/decider (routes declare `then_state` only; decider maps action→route, never direct `sm.transition_to` — fixes the live `路由规则引擎`/`goal-achievement` contradiction).
- [ ] 6.10 `call_terminator.py`: one terminal path for all hangup sources; every terminal route sets `session.hangup_cause`. `session_finalizer.py`: shielded finalize + DECR snap-to-0 (the change-0 follow-up).
- [ ] 6.11 Wire `persona_fanout_cap` (clamp ≤3), `persona_llms[]` consumption; eager fan-out opt-in (N defaults to 1 = main only, no speculation).
- [ ] 6.12 Keep behind `RuntimeConfig.engine_use_router` (still default OFF in prod); `run_session` signature frozen (flag via config, not a new param).

## 7. isales-engine Phase 3 — tests (must pass before any real dial)

- [ ] 7.1 Golden double-flag: 3 deterministic scenarios × {OFF, ON} byte-identical for the byte-stable paths; new persona/tool/gating scenarios get dedicated golden entries.
- [ ] 7.2 `test_eager_dialogue_route_returns_live_generator`: assert generator handed off AGEN_CREATED (the eager-generator deviation guard — blueprint risk #1).
- [ ] 7.3 `test_status_projector`: single-writer ordering; route-completion vs barge-in race; `StatusChanged` sequence; unusual transition → advisory `state_warning` (no raise — inherited from soften-guard, NOT re-implemented).
- [ ] 7.4 `test_gating`: fail-open to main on timeout/invalid/low-confidence; p50 ~0ms (gate lands before first audio in the mock harness).
- [ ] 7.5 `test_tool_routes`: hangup suppresses reply + sets REFEREE_HANGUP + → END; transfer → TRANSFERRING via `_perform_handoff`.
- [ ] 7.6 `test_eager_personas`: N parallel, select-one-cancel-rest, `persona_candidates`/`selected_route_id` in pipeline_trace; cap ≤3 clamp.
- [ ] 7.7 Full engine suite green (current baseline 349 passed / 27 skipped) + ruff clean + `openspec validate --strict`.

## 8. isales-engine Phase 3 — barge-in async cancel (deferred 2.5/2.7 from change-1)

- [ ] 8.1 Invert barge-in: VAD/partial monitor posts `InterruptRequested`; playback owner self-cancels (replace reach-across `current_speaking_task.cancel()`).
- [ ] 8.2 Update/replace `test_realtime_interruption` (it directly tests the monitor reach-across that this removes).
- [ ] 8.3 Note: this changes interrupt timing (call-143 signal-then-cancel race) — golden doesn't cover it; **MUST be validated on a real dial** (§9.2).

## 9. Real-machine UX gate (SIM7600 Windows rig — confirmed in hand: COM12 AT / COM11 audio)

- [ ] 9.1 Deploy common(0.8) → worker → api/scheduler/web → engine (flag still OFF). Smoke each layer.
- [ ] 9.2 Real dial: **barge-in** mid-reply — verify async self-cancel race (no double-cancel, no lost lossless event), reply restructure works.
- [ ] 9.3 Real dial: **transfer** route → TRANSFERRING → connecting phrase → END.
- [ ] 9.4 Real dial: **referee hangup** route — gate selects `tool:hangup`, reply suppressed, optional closing_phrase, → END with `cause=referee_hangup`; CallEnded reaches worker (no DLQ); lead not auto-redialed.
- [ ] 9.5 Real dial: **eager persona** select-one (if enabling N>1) — verify cancelled-persona token billing acceptable; or keep N=1 for the gate.
- [ ] 9.6 Capture pipeline_trace + transcript from the gate dials; confirm wire contract byte-stable vs legacy.

## 10. Phase 4 — flip default ON + DELETE legacy (ONE commit, after §9 passes)

- [ ] 10.1 Flip `ENGINE_USE_ROUTER` default ON.
- [ ] 10.2 DELETE `_main_turn_loop` while + if/elif effect ladder (run_loop.py 838-906) + the change-2 effect-route adapter.
- [ ] 10.3 DELETE `_await_user_or_silence`, the `_ManualHangupRequested` sentinel + `request_manual_hangup` + `main.cancel()` sentinel path.
- [ ] 10.4 DELETE the `ENGINE_USE_ROUTER` flag itself (no more double-path / double-flag).
- [ ] 10.5 Re-run full suite + golden (now single-path) green; ruff clean.
- [ ] 10.6 Same-commit discipline (blueprint §5 "strike while iron is hot"): flag-on + deletion land together, not split across sessions.

## 11. Archive discipline

- [ ] 11.1 `openspec validate --strict` for this change + `--specs` (22/22) green before archive.
- [ ] 11.2 Record the two scope decisions (gating reconciliation D1, projector-moved-from-change-2) in this change's design.md (done) so future sessions don't re-litigate.
- [ ] 11.3 Update `project_engine_flat_refactor` memory + STATE.md files if deployment state changes (same commit as the deploy).
- [ ] 11.4 `/opsx:archive engine-tools-multidialogue-gating` — sync specs/, move to archive/.
