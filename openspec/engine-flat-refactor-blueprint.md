# iSales Engine — Flat Event/Role-Driven Refactor (Master Blueprint)

> Status: **planning / pre-proposal**. The authoritative plan for flattening `isales-engine`
> to a fully event/role-driven (voxen-flat) architecture. Evolves
> `engine-voxen-refactor-plan.md` (which captured the decision journey).
> Source: 6-agent exhaustive blueprint (2026-06-06), ~130 concrete changes across 6 repos.
> Supersedes the active `referee-hangup-action` change (§8).

## 0. Locked decisions

1. **Flatten**: delete the central FSM-as-controller (`while session.state is not END` +
   the `if/elif` ladder + ~20 `sm.transition_to` *driving* calls). Replace with **events +
   routes + flat flags** (voxen `deps.State`).
2. **Referee GATING**: ask the referee BEFORE speaking; small fast model, **~500–700ms
   timeout, fail-open to the `main` persona**. Eager dialogue buffering → gating adds ~0ms p50.
3. **Eager speculative multi-dialogue personas**: N run in parallel, referee picks one, rest
   cancelled. Opt-in, **cap ≤ 3, N defaults to 1**.
4. **Two-lane in-process EventBus**: lossless (asr.final / interrupt / hangup / lifecycle —
   never drop) + lossy (partials / audio / VAD). **Per-handler exception isolation** (fixes
   the "one `RtcError` kills the whole pump" bug class).
5. **Hangup / transfer = lazy tool routes**. Hangup gating-verdict-lands-before-audio →
   **replaces the reply cleanly** (no mid-sentence preemption).
6. **CallStatus is NOT deleted** — it becomes a **projected observability label** written by a
   single `StatusProjector` EventBus subscriber. api / web / transcript / worker contracts stay
   byte-stable. (This is "flatten done right".)
7. **Sales soft-outcomes are routes** (route B): `goal_achieved` → `closing` persona,
   `customer_decline` → `recovery` persona, each carrying a `then_state` side-effect the
   projector reads. voxen has no sales FSM — this part is iSales-native design, not copied.

## 1. The core inversion

```
TODAY (pull loop, FSM controller)            FLAT (push, events drive routes)
_main_turn_loop:                             on_user_final(AsrFinal):     ← the turn IS an event handler
  text = await asr_finals_q.get()              text = coalesce(pending_finals)
  ... 300-line if/elif ladder ...              router.cancel()
  sm.transition_to(...) ×20  ← FSM drives      results = await router.route(input, eval_fn=run_referees)
                                               for r in results: apply(r)   ← dialogue→play / tool→exec / route→then_state
CallStatus = the controller                  CallStatus = a projected label (StatusProjector subscriber)
```

Three pillars: **EventBus** (2-lane) + **SelectRouter** (eager dialogues + referee eval_fn +
lazy tools, `decide()` reused verbatim) + flat **TurnState** (booleans + counters).

## 2. Role / Route / Tool catalog

| route id | kind | exec | then_state | notes |
|---|---|---|---|---|
| `main` | dialogue (default persona) | eager | LISTENING | fail-open target |
| `persona:<label>` | dialogue (RoleKind.PERSONA) | eager | LISTENING | opt-in, cap ≤3, speculative |
| `closing` | dialogue (MainSpec + WRAP_UP_APPEND) | eager | WRAPPING_UP | replaces goal_achieved transition |
| `recovery` | dialogue (persona-by-label) | eager | ACTIVATING | replaces customer_decline |
| `restructure` | dialogue (referee-skipped) | eager | LISTENING | interrupt_remaining / low_confidence |
| `tool:hangup` | lazy tool | lazy | END | closing_phrase → END, cause=referee_hangup, **reply suppressed** |
| `tool:transfer` | lazy tool | lazy | TRANSFERRING | wraps `_perform_handoff` |
| referees | eval_fn (not a route) | parallel | — | small model, ~600ms, fail-open |

`routing_rules.action` evolves: `{type: route, to: <persona>, then_state?}` /
`{type: tool, tool: <alias>, then_state?}` — keeping iSales's exact `category in match[]`
first-match-wins (better than voxen `strings.Contains`). `decide()` reused verbatim.

## 3. CallStatus projection (the contract firewall)

A single `StatusProjector` subscriber is the **sole writer** of `session.state` + sole emitter
of `StatusChanged`. Mapping:

| event / route activity | projected CallStatus |
|---|---|
| Connected | GREETING → LISTENING |
| AsrFinal + referees running | PROCESSING |
| dialogue route first audio | SPEAKING |
| InterruptRequested | INTERRUPTED |
| `closing` route (then_state) | WRAPPING_UP |
| `recovery` route (then_state) | ACTIVATING |
| `tool:transfer` (then_state) | TRANSFERRING |
| `tool:hangup` / terminal | END |

`LEGAL_TRANSITIONS` survives as an **advisory validator** (warn + `state_warning`, never block).
`call_record.status` (binary INIT→END), `transcript`, `pipeline_trace`, `EngineEvent` union,
`CallEnded.hangup_cause` — **all frozen on the wire**.

## 4. Change inventory by repo (~130 items; substantive groups)

### isales-engine (~40)
- **NEW**: `eventbus.py` (2-lane, per-handler isolation), `events.py`/`event_types.py` (~28
  typed events), `select_router.py` (Router + ExecutableRoute + the **live-generator
  deviation**), `turn_state.py` (flat flags), `turn_controller.py` (`on_user_final` driver),
  `handlers.py`, `status_projector.py`, `fsm_subscriber.py`, `redis_bridges.py` (control-in +
  event-out), `call_terminator.py` (one terminal path for all 6 hangup sources),
  `session_finalizer.py` (shielded finalize), `routes/dialogue.py`, `routes/tools.py`,
  `routes/restructure.py`, `routes/referees.py`, `routes/selector.py`, `routes/builder.py`.
- **TRANSFORM**: `_asr_pump`/`_ev_pump`/`_partial_monitor`/`_vad_monitor` → bus producers
  (detection logic verbatim; replace reach-across `current_speaking_task.cancel()` with
  `post(InterruptRequested)` + playback-owner self-cancel). `state_machine.py` → passive
  projector. `decider.py` → reused verbatim + `route`/`then_state` fields. `orchestrator.py`
  → `start_buffering()` + referee-as-eval_fn (timeout 2.0s → ~600ms, gating). `_await_referees`
  → `run_referees` eval_fn.
- **DELETE** (Phase 4): `_main_turn_loop` while+if/elif, `_await_user_or_silence`,
  `_ManualHangupRequested` + `request_manual_hangup` + `main.cancel()` sentinel, the temp
  adapter, the `ENGINE_USE_ROUTER` flag.
- **KEEP verbatim** (the must-not-drop machinery, §6): `_play_streaming`/`_SynthJob` pre-synth
  pipeline, `_assemble_interrupt_text`, final-coalescing, cross-turn counters, greeting
  ordering, text≥2 gate, the ONE `chat_stream→chat` fallback + `default_reply` guard.

### isales-common (~13)
- `enums.py`: `RoleKind.PERSONA`, `PromptScopeType.PERSONA`, `HangupCause.REFEREE_HANGUP`;
  `CallStatus` **unchanged** (+ projection docstring).
- `schemas/jsonb/tool_config.py` **NEW** (HangupToolConfig / TransferToolConfig union);
  `routing_rule.py`: `RoutePersonaAction` + `RouteToolAction` + `ThenState` Literal + widened
  union (legacy `transition`/`restructure` kept via removal-tracked shim).
- `models/campaign.py`: `+tools JSONB`, `+persona_fanout_cap`, `+referee_timeout_ms`,
  `+referee_fail_open_route`. `models/pipeline_trace.py`: `+selected_route_id/kind`,
  `+persona_candidates`. `schemas/messages/dial.py`: `+persona_llms[]`. `schemas/pipeline.py`:
  `+PersonaSpec`, `+personas`, `+tools`. One **additive alembic** (down_rev `a7b8c9d0e1f2`).
  Version **0.7.0 → 0.8.0**.

### isales-api (~5)
- `role_configs.py`: PERSONA in `_LABELLED_KINDS` + delete-guard for referenced personas.
- `routing_validation.py`: `persona_labels_of` + validate route→persona / tool→alias
  (`422 routing_rule_unknown_persona` / `_unknown_tool` / `tool_alias_duplicate`).
- `campaigns.py`: thread `tools` through nested create/update + routing-rules PUT. Pin → 0.8.

### isales-web (~5)
- `RoutingRulesTab.vue`: action editor gains 路由到角色(persona) + 工具(挂断/转人工) +
  then_state dropdown; **fix the goal_type-on-target-switch 422 bug** (cherry-forward now).
- `RoleConfigTab.vue`/`RoleConfigDialog.vue`: persona kind (label required).
- `ToolsTab.vue` **NEW** (hangup closing_phrase/interrupt, transfer texts).
- `types/campaign.ts`: persona / ThenState / Route*Action / ToolConfig types + defaults.

### isales-scheduler (~1)
- `prompt.py` `pack_prompt_versions`: pack `RoleKind.PERSONA` rows → `persona_llms[]`.

### isales-worker (~4)
- `lead_state.py`: `REFEREE_HANGUP` → no-auto-redial bucket. Verify `callend.py` enum-validates.
- **FIX stale pin** `isales-common>=0.5,<0.6 → >=0.8,<0.9` (pre-existing bug — worker already
  uses 0.7-era symbols; the new enum requires 0.8). **Deploy order: common → worker → engine**
  (CallEnded is enum-validated; engine must not emit `referee_hangup` before worker has the enum).

### isales (meta specs)
- `service-communication`: NEW in-process two-lane EventBus channel-type row + discipline.
- `call-state-machine`: **major rewrite** controller → projection (wire contract unchanged).
- `ai-pipeline`: decider→SelectRouter; referee post-reply→pre-reply gating; tools; personas.
- `data-model` / `web-admin-ui` / `retry-followup`: tools, personas, then_state, REFEREE_HANGUP.

## 5. Execution — 3 sequenced changes + change-0, ONE momentum session

> "一口气" = complete all three **back-to-back in one session** (not a mega-change, not N
> restart-sessions). Safety = disjoint spec-delta clusters (avoid the documented multi-referee
> "互踩" overlap) + a frozen `run_session()` contract + a NEW byte-identical **golden-transcript
> net** built FIRST.

| # | change | phases | behavior | spec cluster |
|---|---|---|---|---|
| **0** | scaffolding (no OpenSpec) | — | none | `test_golden_transcript.py` (full_transcript+pipeline_trace byte-identical) + `test_run_session_contract.py` (frozen sig + finalize-once) + sync test-bus. **MUST exist before change 1.** |
| **1** | `engine-eventbus-foundation` | 0–1 | **none** (byte-identical) | service-communication, architecture. Soak on ECS first. |
| **2** | `engine-multi-route-dispatch` | 2 | **none** (kill-switch) | ai-pipeline, call-state-machine. SelectRouter + projector; effects still in run_loop. |
| **3** | `engine-tools-multidialogue-gating` | 3–4 | **YES** | ai-pipeline, data-model, web-admin-ui, retry-followup. Gating + eager personas + hangup/transfer tools; **all behavior risk quarantined here behind `ENGINE_USE_ROUTER`**; Phase-4 deletes legacy ladder + flag + adapter in the same commit. |

Discipline: **archive change N before writing N+1's overlapping ai-pipeline delta** (multi-referee
tasks.md §0.4). All behavior change is in change 3 → changes 1–2 are zero-risk.

## 6. MUST NOT silently drop (golden-transcript must capture all)

final-coalescing debounce · barge-in remainder→restructure feedback · shielded finalize +
DECR snap-to-0 · ONE removal-tracked `chat_stream→chat` fallback + `default_reply` guard ·
pre-synth producer/consumer TTS (maxsize=2) · pipeline_trace + transcript event vocabulary ·
cross-turn counters (interruption/restructure/silence/wrap-up) · greeting non-interruptible
ordering · text≥2 gate + wall-clock speech anchor · wrap-up disables referees/transfer/filler ·
post-call extractor stays offline · every terminal route MUST set `session.hangup_cause`.

## 7. Top risks

- **Eager-generator deviation** — router hands the LIVE `sentences()` generator un-drained
  (unlike voxen `getResult`). A future "fix" to drain it → every turn goes silent. Loud doc +
  `test_eager_dialogue_route_returns_live_generator` (AGEN_CREATED assert).
- **Barge-in cancel timing** — sync `task.cancel()` → async event self-cancel; re-validate the
  signal-then-cancel race (run_loop.py:1459-1461, call-143) on a **real dial** before change 3.
- **Worker pin lag + enum-validated CallEnded** — deploy common → worker → engine; engine must
  not emit `referee_hangup` before worker has the enum, else CallEnded DLQs.
- **StatusProjector single-writer ordering** — route-completion vs barge-in race; single writer
  on the serialized lossless lane + golden asserts ordering.
- **Eager persona token cost** — vendors bill cancelled tokens; cap ≤3 + opt-in + budget alarms.
- **Real-dial UX gate for change 3** needs the physical SIM7600 Windows rig; if unavailable,
  write a handoff memory rather than ship gating unverified.

## 8. Supersedes `referee-hangup-action`

Mark superseded (do not implement as the 4th `DeciderAction.kind` branch — Phase 4 deletes it).
**Fold hangup into change 3** as a lazy `tools[hangup]` route. **Cherry-forward NOW** (low risk,
architecture-independent): the web `goal_type`-on-target-switch **422 fix**. Keep the folder as a
**release-valve stopgap** if changes 2/3 slip > ~2 weeks and hangup becomes an urgent compliance
gap (precedent: `2026-05-29-prompt-template-vars-SUPERSEDED`).
