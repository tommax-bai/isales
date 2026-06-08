## Context

This is **change 3 of 3** in the engine flat event/role-driven refactor (authoritative
plan: `openspec/engine-flat-refactor-blueprint.md`). Changes 1 and 2 landed the scaffolding
**byte-identically**:

- **change-1 `engine-eventbus-foundation`** (archived) — two-lane in-process `EventBus`
  (lossless + lossy, per-handler exception isolation) + the typed `events.py` signal
  vocabulary + control bridges. Manual-hangup/transfer migrated off the
  `_ManualHangupRequested` / `main.cancel()` sentinel onto the bus.
- **change-2 `engine-multi-route-dispatch`** (archived) — `SelectRouter` extracts the
  `decide()`-**effect** dispatch (goal_achieved / transfer / customer_decline / restructure)
  out of the `_main_turn_loop` if/elif ladder (run_loop.py 838-906) into an effect-route
  table, behind `ENGINE_USE_ROUTER` (default **OFF**). The `decide()`/dialogue/play/referees
  path stays inline verbatim. **Two scope-narrowings were forced and recorded in change-2's
  design.md**: (a) `StatusProjector` + the call-state-machine controller→projection rewrite
  could not be byte-identical under a kill-switch, so they were **moved here**; (b) "Shape B"
  — the Router only does post-`decide()` effect dispatch, not the whole user turn.

A third active change matters here: **`call-state-machine-soften-guard`** (21/28 tasks; engine
code shipped as commit `2cb47bc` on 2026-06-02, spec delta un-archived) already softened
`LEGAL_TRANSITIONS` from raising `IllegalTransition` to an advisory `state_warning` + proceed.
The blueprint pre-dated this and mis-attributed the advisory downgrade to change-3; the design
below corrects that (D3) and sequences soften-guard to archive first.

Change-3 is where **all behavior actually changes**. It is still gated by the **same
`ENGINE_USE_ROUTER` kill-switch**, so production stays on the legacy path until the
real-machine UX gate passes; the **Phase-4 deletion of the legacy ladder + the flag + the
effect-route adapter happens in the same commit that flips the default ON** (strangler
completion in one momentum session). The physical **SIM7600 Windows rig is confirmed in
hand** (COM12 AT / COM11 audio) — the real-dial barge-in/transfer gate can run this session.

Current reality this change inverts: iSales today **speaks first, then judges** — the referee
runs in parallel with main streaming but its verdict is consumed **after** TTS finishes
(`ai-pipeline` § "referee 决策驱动状态机": `await asyncio.wait_for(referee_task, timeout=2.0)`
fires when SPEAKING exits). voxen, by contrast, **gates before speaking**. Reconciling these
two is the central design problem below.

## Goals / Non-Goals

**Goals:**
- Invert referee from a **post-reply judge** to a **pre-reply gate** (~600ms timeout,
  fail-open to the `main` persona, ~0ms p50 added latency via eager buffering).
- **Eager speculative multi-dialogue personas**: N run in parallel, referee picks one, rest
  cancelled. Opt-in, cap ≤3, N defaults to 1.
- **Hangup / transfer = lazy tool routes** (`tool:hangup` reply-suppressed → END
  `cause=referee_hangup`; `tool:transfer` → TRANSFERRING via `_perform_handoff`).
- **CallStatus → projected label**: single `StatusProjector` subscriber is the sole writer of
  `session.state`; `LEGAL_TRANSITIONS` downgraded to advisory. Wire contract byte-stable.
- Sales soft-outcomes as routes (`goal_achieved`→`closing`, `customer_decline`→`recovery`)
  carrying `then_state`.
- `HangupCause.REFEREE_HANGUP` + worker no-auto-redial bucket.
- Web admin: persona/tool/then_state editor + ToolsTab + persona role kind + 422 fix.
- **Phase-4**: delete `_main_turn_loop` ladder, `_await_user_or_silence`,
  `_ManualHangupRequested`, the effect-route adapter, and `ENGINE_USE_ROUTER` — same commit.

**Non-Goals:**
- Changing any **wire contract**: `CallStatus` enum, transcript event vocabulary,
  `pipeline_trace` existing columns, `CallEnded.hangup_cause` union, `call_record.status`
  binary, `EngineEvent` union — all frozen.
- Re-doing the EventBus (change-1) or the SelectRouter effect-dispatch scaffold (change-2).
- The multi-Edge gRPC routing WIP (a separate uncommitted workstream — not touched).
- Per-rule hangup disposition (do-not-call vs plain no-redial) — v1 fixes REFEREE_HANGUP to
  the no-auto-redial bucket; per-rule disposition is deferred (inherited from the superseded
  `referee-hangup-action` non-goals).

## Decisions

### D1 — Gating reconciliation: eager-buffer-then-gate, fail-open to `main`

The referee becomes an **`eval_fn`** the router calls *before* releasing audio, **not** a
post-TTS consumer. To keep p50 latency at ~0ms despite gating, dialogue routes start
generating **eagerly and speculatively** the moment the user's final lands — `main` (always)
plus any opt-in personas. The router awaits `run_referees` (small model, ~600ms) and, when the
verdict lands, **selects one buffered dialogue route to release** and cancels the rest.

Because the referee is a small fast model and the dialogue's pre-synth pipeline needs time to
produce its first playable sentence anyway, the gate verdict typically lands **before** the
first audio chunk is ready → gating is free at p50. If the referee times out (>~600ms) or
returns invalid/low-confidence, the router **fails open to the `main` persona** (not voxen's
"continue") — `main` is already buffered, so fail-open is also ~0ms.

- **Alternative considered — keep post-reply judge, bolt hangup on as a 4th action** (this is
  what the superseded `referee-hangup-action` did). Rejected: hangup-after-speaking means the
  AI delivers a full reply and *then* hangs up mid-courtesy, which reads worse than a clean
  replace; and it cements the FSM-controller shape Phase-4 deletes.
- **Alternative considered — drain the dialogue generator before gating** (voxen `getResult`
  shape). Rejected and **explicitly forbidden** — see D2.

### D2 — The eager-generator deviation (LOUD)

Unlike voxen's `getResult` (which drains the model output before the router sees it), the
iSales router hands the **live, un-drained `sentences()` async-generator** to the playback
owner. Draining it in the router would (a) destroy the streaming token→sentence→TTS pipeline
that is the whole latency story, and (b) make gating *not* free because the router would block
on full generation. A well-meaning future refactor that "tidies" this by awaiting the
generator will **silence every turn**.

Mitigation: a loud module docstring at the hand-off site **and** a guard test
`test_eager_dialogue_route_returns_live_generator` asserting the generator is handed off
un-started (AGEN_CREATED, not AGEN_CLOSED/SUSPENDED). This is the blueprint's #1 risk.

### D3 — `StatusProjector` as sole `session.state` writer

A single `StatusProjector` EventBus subscriber on the **serialized lossless lane** becomes the
only writer of `session.state` and the only emitter of `StatusChanged`. Mapping (blueprint §3):
Connected→GREETING→LISTENING; AsrFinal+referees→PROCESSING; dialogue first-audio→SPEAKING;
InterruptRequested→INTERRUPTED; `closing` then_state→WRAPPING_UP; `recovery`→ACTIVATING;
`tool:transfer`→TRANSFERRING; `tool:hangup`/terminal→END.

**Ground-truth correction (verified, not in the blueprint):** the `LEGAL_TRANSITIONS`
advisory downgrade — illegal transition **warns + appends `state_warning`**, never raises
`IllegalTransition`, proceeds — **already shipped** in `call-state-machine-soften-guard`
(engine commit `2cb47bc`, 2026-06-02; `state_machine.py:158` emits `state_warning`), and it is
**flag-independent** (not behind `ENGINE_USE_ROUTER`). The blueprint's framing of this as
change-3's "controller→projection rewrite" pre-dated that work. So change-3 does **NOT**
re-introduce the advisory downgrade and MUST NOT regress the wire event back to `state_error`.

What change-3 actually adds (and IS new + flag-gated) is the **single-writer projection**: the
`StatusProjector` becomes the sole caller of `transition_to` / sole `session.state` writer, and
routes stop driving transitions (they declare `then_state`). The advisory behavior underneath
is inherited from soften-guard.

- **Why single-writer on the lossless lane**: the documented projector hazard (change-2) is
  async write-ordering — if two events race to write state, history/`previous_state` corrupts.
  One subscriber on the serialized lossless lane gives a total order; the golden net asserts
  the `StatusChanged` sequence.
- **Alternative — let each route write its own state** (today's shape). Rejected: that *is* the
  controller pattern; it reintroduces the race and the if/elif ladder.
- **Archive ordering**: `call-state-machine-soften-guard` is active (21/28 tasks) and its spec
  delta MODIFIES `状态集合`; change-3's call-state-machine delta deliberately does **not** touch
  `状态集合` (it touches `hangup_cause 单一来源` + adds the projector requirement) to avoid the
  overlap, but soften-guard MUST archive first so the live advisory text is in place.

### D4 — Hangup/transfer are *lazy* tool routes; dialogue routes are *eager*

Tool routes are **lazy**: instantiated but only `execute()`d if selected — they have no
speculative cost and no live generator. `tool:hangup` sets `session.hangup_cause =
REFEREE_HANGUP`, optionally TTS-plays `closing_phrase`, **suppresses the dialogue reply**, and
drives → END. `tool:transfer` wraps the existing `_perform_handoff` → TRANSFERRING. Because the
gate verdict lands before audio, a selected hangup **replaces** the buffered dialogue cleanly —
no mid-sentence preemption. Every terminal route MUST set `session.hangup_cause` (blueprint §6).

### D5 — `routing_rules.action` widening (additive, shimmed)

`action` gains `{type: route, to: <persona-label | closing | recovery | restructure>,
then_state?}` and `{type: tool, tool: <alias>, then_state?}`, keeping iSales's exact
`category in match[]` first-match-wins. `closing`/`recovery`/`restructure` are operator-nameable
`to`-targets (the verdict-mapped dialogue routes) alongside persona labels. `then_state ∈
{LISTENING, WRAPPING_UP, ACTIVATING, TRANSFERRING, END}` is the side-effect the projector reads.

Legacy `{type: transition}` / `{type: restructure}` are kept via a **removal-tracked shim**
(removal trigger = a later cleanup change once all campaigns migrate). The shim maps legacy
transition targets to route + then_state so they ALSO flow through the projector (never a direct
`sm.transition_to`): `to: goal_achieved` → `closing` route (then_state=WRAPPING_UP, `goal_type`
carried); `to: transfer` → `tool:transfer` (then_state=TRANSFERRING, reuses `_perform_handoff`);
`to: customer_decline` → `recovery` route (then_state=ACTIVATING). `decide()` is reused
verbatim; only the action→route mapping widens. The decider/route MUST NOT call `transition_to`
directly — that's the StatusProjector's job (D3).

### D6 — Schema & versioning

`isales-common` 0.7.0 → **0.8.0**, one **additive** alembic (down_rev `a7b8c9d0e1f2`):
`RoleKind.PERSONA`, `PromptScopeType.PERSONA`, `HangupCause.REFEREE_HANGUP`; `tools` JSONB
(HangupToolConfig/TransferToolConfig union) on campaign; campaign `persona_fanout_cap` /
`referee_timeout_ms` / `referee_fail_open_route`; `pipeline_trace` `selected_route_id` /
`selected_route_kind` / `persona_candidates`; `dial` message `persona_llms[]`. `CallStatus`
**unchanged** (+ projection docstring). Downstream pins: api/scheduler/worker → `>=0.8,<0.9`.

## Risks / Trade-offs

- **[Eager-generator "fix" silences every turn]** → loud docstring + AGEN_CREATED guard test
  (D2). Highest-severity latent footgun.
- **[Barge-in cancel timing regression]** → change-1 deferred tasks 2.5/2.7 (monitor posts
  `InterruptRequested` + playback self-cancels, replacing sync `current_speaking_task.cancel()`
  reach-across). The signal-then-cancel race (run_loop.py:1459-1461, observed call-143) MUST be
  re-validated **on a real dial** before flipping the flag. Golden doesn't cover it.
- **[Worker pin lag + enum-validated CallEnded → DLQ]** → **deploy order common → worker →
  engine**. Worker's `isales-common` pin is stale (`>=0.5,<0.6`); bump to `>=0.8,<0.9` and ship
  worker *before* engine, or an engine-emitted `referee_hangup` CallEnded fails enum validation
  and dead-letters. Fix the pin in this change.
- **[StatusProjector ordering race]** → single writer on the serialized lossless lane (D3) +
  golden asserts the `StatusChanged` sequence + route-completion vs barge-in ordering test.
- **[Eager persona token cost]** → vendors bill cancelled tokens; cap ≤3 + opt-in (N defaults
  to 1) + budget alarms. Speculative fan-out is off by default.
- **[Behavior change shipped unverified]** → all risk behind `ENGINE_USE_ROUTER`; golden runs
  **both** flag states; production stays OFF until the real-machine gate passes; only then does
  the Phase-4 commit flip default ON + delete the legacy path.

## Migration Plan

1. **isales-common 0.8.0** — additive alembic (down_rev `a7b8c9d0e1f2`), publish package.
2. **isales-worker** — bump pin `>=0.8,<0.9`, add `REFEREE_HANGUP` no-auto-redial bucket,
   verify `callend.py` enum-validates. **Deploy worker before engine.**
3. **isales-api / isales-scheduler / isales-web** — pin 0.8; persona/tool validation; persona
   packing; UI editors + 422 fix. (Order-independent vs engine once common is out.)
4. **isales-engine** — implement gating + eager personas + tool routes + StatusProjector behind
   `ENGINE_USE_ROUTER` (still default OFF). Golden double-flag green. Deploy with flag OFF.
5. **Real-machine UX gate** (SIM7600 rig): real-dial barge-in + transfer + a referee-hangup
   call; verify the async cancel race and reply-suppression.
6. **Phase-4 commit** — flip `ENGINE_USE_ROUTER` default ON, delete `_main_turn_loop` ladder /
   `_await_user_or_silence` / `_ManualHangupRequested` / the effect-route adapter / the flag.
7. **Rollback**: pre-Phase-4, set `ENGINE_USE_ROUTER=OFF` — this restores the byte-identical
   legacy **router/gating/persona/tool/projector** path (the flag-gated surface). It does NOT
   restore the pre-soften `IllegalTransition`-raising behavior — that advisory downgrade shipped
   independently in soften-guard and is not part of this change's flag. Post-Phase-4, rollback =
   revert the engine release (legacy code is gone). common's alembic is additive → no
   down-migration needed for rollback.

## Open Questions

- **Persona prompt packing shape** — `persona_llms[]` mirrors `referee_llms[]`; confirm
  scheduler `pack_prompt_versions` handles the `PERSONA` kind's `label` the same way referee
  labels are packed (no collision with referee label namespace).
- **Gate timeout default** — blueprint says ~500–700ms; default `referee_timeout_ms` proposed
  at 600. Tune against the real-dial first-audio measurement during the UX gate.
- **`closing` vs `tool:hangup` overlap** — `closing` (goal_achieved → WRAPPING_UP, keeps
  talking) vs `tool:hangup` (terminate now). The web copy must make the operator distinction
  obvious; carried from the superseded change's "运营文档" note.
- **`recovery` route → ACTIVATING vs silence-driven ACTIVATING** — the `recovery` route
  (customer_decline soft-outcome) reuses the **existing** `customer_decline → ACTIVATING`
  mapping already in the live ai-pipeline decider (not new in this change). Open: confirm during
  apply that referee-driven (recovery) ACTIVATING does NOT increment `max_silence_activations`
  and uses the recovery persona's generated text rather than `silence_phrases` — i.e. the
  silence-activation counter/phrase machinery applies only to silence-driven entries. This
  interaction is unchanged from today; no silence-activation spec delta unless apply surfaces a
  real conflict.
- **`data-model` 全表清单 catalog NOT reconciled (intentional)** — the new columns
  (campaign.tools / persona_fanout_cap / referee_timeout_ms / referee_fail_open_route;
  pipeline_trace.selected_route_id / selected_route_kind / persona_candidates) are normatively
  defined in this change's data-model ADDED requirements + the transcript `pipeline_trace`
  field delta (the authoritative field-constraint owner). The `表归属与全表清单` denormalized
  index is deliberately NOT rewritten here — it already lags the multi-referee change (still
  lists single-referee `referee_decision/referee_goal_type/...` that transcript long since
  replaced with `referee_results[]`), so a full catalog reconciliation is a separate cleanup,
  out of change-3's scope. Flagged so the omission is a documented decision, not an oversight.
