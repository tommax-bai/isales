## Why

Changes 1 (`engine-eventbus-foundation`) and 2 (`engine-multi-route-dispatch`) landed
the flat event/role-driven scaffolding **byte-identically** — the EventBus is live and
`SelectRouter` dispatches `decide()`'s effects behind a default-OFF `ENGINE_USE_ROUTER`
kill-switch, but no behavior has changed yet. This change is where the voxen-flat
refactor finally pays off: the referee moves from a **post-reply** judge to a
**pre-reply gate**, dialogue personas run **eager and speculative**, and hangup/transfer
become **lazy tool routes** instead of bespoke FSM branches. All behavior risk for the
entire refactor is deliberately quarantined here behind the same kill-switch, then the
legacy `_main_turn_loop` if/elif ladder, the flag, and the effect-route adapter are
**deleted in the same Phase-4 commit** — completing the strangler migration in one
momentum session (per the blueprint §5 discipline).

## What Changes

- **Pre-reply referee GATING** (ai-pipeline): referees move from judging *after* the
  reply to gating *before* speaking. Small fast model, **~600ms timeout (down from 2.0s),
  fail-open to the `main` persona**. Eager dialogue buffering means gating adds ~0ms p50.
- **Eager speculative multi-dialogue personas** (ai-pipeline + data-model): N personas
  run in parallel, the referee picks one, the rest are cancelled. **Opt-in, cap ≤ 3,
  N defaults to 1.** The router hands the **live `sentences()` generator un-drained**
  (the documented "eager-generator deviation" — a future "fix" to drain it silences every
  turn).
- **Hangup / transfer = lazy tool routes** (ai-pipeline + data-model): `tool:hangup`
  (closing_phrase → END, `cause=referee_hangup`, **reply suppressed**) and `tool:transfer`
  (wraps `_perform_handoff` → TRANSFERRING). Gating-verdict-lands-before-audio →
  hangup **replaces** the reply cleanly (no mid-sentence preemption).
- **CallStatus becomes a projected label** (call-state-machine): a single `StatusProjector`
  EventBus subscriber becomes the **sole writer** of `session.state` (sole caller of
  `transition_to`) + sole emitter of `StatusChanged`; routes only declare `then_state`. NOTE
  the `LEGAL_TRANSITIONS` **advisory** downgrade (warn + `state_warning`, never raise) is NOT
  this change's doing — it **already shipped** in `call-state-machine-soften-guard` (engine
  commit `2cb47bc`, 2026-06-02), flag-independent; change-3 only adds the single-writer
  projection on top. The api/web/transcript/worker wire contracts stay byte-stable.
- **Sales soft-outcomes are routes** (ai-pipeline): `goal_achieved` → `closing` persona,
  `customer_decline` → `recovery` persona — each carrying a `then_state` side-effect the
  projector reads. (iSales-native; voxen has no sales FSM.)
- **`REFEREE_HANGUP` HangupCause** (data-model + retry-followup): new enum value;
  referee-initiated hangups land in worker's **no-auto-redial** bucket.
- **Web admin** (web-admin-ui): routing-rule action editor gains 路由到角色(persona) +
  工具(挂断/转人工) + `then_state` dropdown; new ToolsTab; persona role kind; **fixes the
  `goal_type`-on-target-switch 422 bug**.
- **Phase-4 deletion (same commit as flag-on)**: delete `_main_turn_loop` while+if/elif,
  `_await_user_or_silence`, the `_ManualHangupRequested` sentinel, the temp effect-route
  adapter, and the `ENGINE_USE_ROUTER` flag itself.
- **Supersedes `referee-hangup-action`** (blueprint §8): mark superseded — hangup is folded
  here as a tool route, not implemented as a 4th `DeciderAction.kind` branch.

## Capabilities

### New Capabilities
<!-- None. Tools and personas are folded into ai-pipeline (as SelectRouter routes) and
     data-model (as schema), per blueprint §2/§8 — they do not warrant standalone specs. -->

### Modified Capabilities
- `ai-pipeline`: referee post-reply→**pre-reply gating** (timeout 2.0s→~600ms, fail-open
  to `main`); eager speculative **multi-dialogue personas** (cap ≤3, opt-in, live-generator
  deviation); **hangup/transfer lazy tool routes**; `goal_achieved`/`customer_decline` as
  `closing`/`recovery` routes with `then_state`. Builds on change-2's SelectRouter
  effect-dispatch requirement.
- `call-state-machine`: controller→projection. `StatusProjector` becomes the sole
  `session.state` writer (sole `transition_to` caller); routes declare `then_state` only. The
  `LEGAL_TRANSITIONS` advisory downgrade is NOT re-done here (already shipped in
  `call-state-machine-soften-guard`); change-3 only registers `REFEREE_HANGUP` into the
  `hangup_cause 单一来源` enum + adds the projector requirement. Wire contract (CallStatus
  enum, `state_warning` event, transitions observed by api/web/transcript) unchanged.
  **Pre-flight: `call-state-machine-soften-guard` MUST archive first** (both touch this
  capability; disjoint requirements, but archive-ordering avoids the overlap hazard).
- `ai-pipeline`: referee post-reply→pre-reply gating; eager personas; hangup/transfer tool
  routes; `goal_achieved`/`customer_decline` as `closing`/`recovery` routes with `then_state`;
  decider action→route mapping (no direct `sm.transition_to`); REMOVES change-2's kill-switch
  requirement. (Already listed above; expanded here for the decider/referee/default-reply
  requirements that move off the post-reply model.)
- `goal-achievement`: `goal_achieved` re-expressed as the `closing` route (then_state=
  WRAPPING_UP, projector-written, gated pre-reply) instead of post-TTS `sm.transition_to`.
- `transcript`: `pipeline_trace` field enumeration gains `selected_route_id` /
  `selected_route_kind` / `persona_candidates` (the authoritative field-constraint owner).
- `data-model`: `RoleKind.PERSONA`, `HangupCause.REFEREE_HANGUP`, `tools` JSONB
  (HangupToolConfig/TransferToolConfig), `routing_rules` route/tool actions + `then_state`,
  campaign `persona_fanout_cap`/`referee_timeout_ms`/`referee_fail_open_route`,
  `pipeline_trace` persona/route fields. One additive alembic; isales-common 0.7.0→0.8.0.
- `web-admin-ui`: routing-rule persona/tool/`then_state` action editor; ToolsTab; persona
  role kind (label required); `goal_type`-on-target-switch 422 fix.
- `retry-followup`: `REFEREE_HANGUP` routes to the no-auto-redial bucket.

## Impact

- **isales-engine** (~40 items): pre-reply gating in `orchestrator.py`/`run_referees`;
  eager dialogue routes + live-generator hand-off; `tool:hangup`/`tool:transfer` routes;
  `StatusProjector` subscriber; `state_machine.py`→passive projector; **Phase-4 deletion**
  of the legacy ladder + flag + adapter. Flips `ENGINE_USE_ROUTER` default to ON, then
  removes the flag.
- **isales-common** (~13 items): enums, `tool_config.py`, `routing_rule.py` route/tool
  actions, campaign + pipeline_trace columns, one additive alembic (down_rev
  `a7b8c9d0e1f2`), **version 0.7.0→0.8.0**.
- **isales-api** (~5): PERSONA in `_LABELLED_KINDS` + delete-guard; route→persona / tool→alias
  validation (`422 routing_rule_unknown_persona`/`_unknown_tool`/`tool_alias_duplicate`);
  thread `tools` through campaign create/update; pin →0.8.
- **isales-web** (~5): RoutingRulesTab/RoleConfig/ToolsTab + types; 422 fix.
- **isales-scheduler** (~1): `pack_prompt_versions` packs `RoleKind.PERSONA` → `persona_llms[]`.
- **isales-worker** (~4): `REFEREE_HANGUP` no-auto-redial bucket; **fix stale pin
  `>=0.5,<0.6`→`>=0.8,<0.9`**. **Deploy order: common → worker → engine** — CallEnded is
  enum-validated; engine MUST NOT emit `referee_hangup` before worker has the enum, or
  CallEnded DLQs.
- **Real-machine gate**: barge-in cancel timing (sync→async self-cancel) and transfer must
  be re-validated on the physical SIM7600 Windows rig (confirmed in hand: COM12 AT / COM11
  audio) before flipping the flag on.
