# iSales Engine → voxen-style EventBus + Multi-Route Refactor Plan

> Status: **✅ EXECUTED (2026-06-07) / superseded** — this is the earlier decision-journey
> record (evolved into `engine-flat-refactor-blueprint.md`, which is itself now
> executed). The refactor shipped: EventBus + multi-route + gate-first + CallStatus
> 11→4 + Phase-4 legacy/flag deletion (engine commit `a7e5576`). For as-built truth
> see the archived changes + `openspec/changes/engine-tools-multidialogue-gating/`;
> the file-layout / phasing / open-tuning-knobs below are **historical planning**, not
> current state.
>
> _Original header (historical): "planning / pre-proposal"; 5-agent study of
> `voxen-main` + `isales-engine` 2026-06-06; superseded `referee-hangup-action` (§9)._

## 0. Locked decisions

The user has chosen the **full voxen model** (not the earlier hybrid). Locked:

1. **Referee-gating**: the engine **asks the referee BEFORE it speaks**, and the referee
   verdict selects which route emits. (Not iSales-today's "main streams immediately,
   referee judged after".)
2. **Small/fast referee model + tight timeout + fail-open**: referee is a cheap classifier
   that outputs a short label; bounded by a hard timeout (voxen uses 1.0s; iSales target
   **~500–700ms**), and on timeout/error **fails open to `continue`/main**.
3. **Eager speculative multi-dialogue**: N dialogue personas run **in parallel**, the
   referee picks one, the rest are **cancelled**. Opt-in per campaign; N defaults to 1.
4. **EventBus** (in-process, typed, asyncio) replaces the hand-wired `Queue + Event +
   direct task-cancel` intra-call coordination.
5. **Hangup / transfer are lazy tool routes** (voxen `tool_sip_hangup.go` /
   `tool_transfer_operator.go` model), not `if/elif` branches.

### Why gating does NOT regress latency (corrected from earlier analysis)

Gating's added first-audio cost = `max(0, referee_done − dialogue_first_sentence_ready)`,
because the dialogue runs **eager (parallel)** and buffers tokens while the referee
classifies:

- small referee → short label → `referee_done ≈ 150–450ms`
- iSales main first sentence → `~500–1100ms` (measured `first_audio_ms` 678–1106)
- ⇒ referee finishes **before** the dialogue's first sentence is even ready ⇒ **gating adds
  ~0ms at p50**. The only tax is referee **tail latency**, capped by the timeout + fail-open.

Gating is also **cleaner for hangup**: the verdict lands before any audio, so "hangup
replaces the reply" is natural (don't emit a dialogue, run the hangup tool) — **no
mid-sentence preemption** (the UX risk of the rejected hybrid).

### The one real cost being accepted

Eager N-dialogue speculation bills **N× main-LLM tokens** (N−1 discarded; vendors bill
generated tokens even after cancel). Mitigation: **single dialogue by default** (no extra
cost), persona fan-out **opt-in** + **hard cap (≤2–3)** + cancel-on-select + reuse
`token_budget_per_call` alarms.

---

## 1. Motivation

The engine today is a single 1665-line `run_loop.py` whose `_main_turn_loop` is one giant
`while` with an inline `if/elif` decision ladder. The decision logic (`decide()` in
`pipeline/decider.py`) is already a pure first-match-wins function, and the orchestrator
(`PipelineStream`) already spawns N referees in parallel — **iSales is already ~80% of
voxen's pattern**, just scattered and hard-coded. The refactor **extracts** that into
clean, extensible abstractions (EventBus + SelectRouter + tools), unlocking:

- **Extensibility**: new turn outcomes (hangup, schedule-callback, …) = register a tool, no
  core-loop surgery.
- **Multi-persona dialogue**: referee picks the dialogue persona per situation (砍价/逼单/安抚).
- **Robustness**: per-handler exception isolation fixes the documented "one `RtcError` kills
  the whole pump" bug class.
- **Cleaner hangup semantics**: replace-the-reply instead of append-after-reply.

---

## 2. Target architecture — three pillars

```
                          ┌──────────────────────── EventBus (in-process, typed) ───────────────────────┐
 telephony audio_in ─► ASR producer ─► asr.partial(lossy) / asr.final(lossless) ─► turn orchestrator    │
 telephony events   ─► ev producer  ─► hangup/connected(lossless)                                        │
 partial/VAD monitor ─► InterruptRequested(lossless)                                                      │
                          └──────────────┬─────────────────────────────────────────────────────────────┘
                                         ▼ (a user turn finishes)
                       ┌──────────────────────── SelectRouter.route(input, eval_fn) ─────────────────────┐
                       │ start EAGER routes: dialogue personas (1..N) ── stream LLM, buffer              │
                       │ run eval_fn: referees (parallel, small model, ~500ms timeout, fail-open)        │
                       │ Decider.decide()  ◄── reuse pipeline/decider.py (first-match over routing_rules)│
                       │ Selector → route id(s); cancel unselected dialogues                              │
                       │ selected = dialogue → hand LIVE generator to _play_streaming → TTS               │
                       │ selected = tool     → execute lazy tool (hangup / transfer)                      │
                       └──────────────┬─────────────────────────────────────────────────────────────────┘
                                      ▼
                       CallStatus FSM (advisory) ── driven by a single EventBus subscriber
                                      ▼
                       transcript / pipeline_trace / engine:events (unchanged external contracts)
```

### 2.1 EventBus (in-process, typed, asyncio) — **two lanes**

Replaces `run_loop._ListenContext` (`asyncio.Queue` + `asyncio.Event` + reach-across
`session.current_speaking_task.cancel()`).

- **Lossless lane** (unbounded `asyncio.Queue`, `await put`): `asr.final`, `InterruptRequested`,
  `HangupRequested`, `connected`, lifecycle, control. **A user's final utterance MUST NEVER
  be dropped** (voxen's drop-oldest is catastrophic here).
- **Lossy lane** (bounded, drop-oldest): `asr.partial`, audio chunks, VAD/RMS.
- **Per-handler exception isolation** (try/except per handler, re-raise `CancelledError`):
  directly fixes the "`bridge.py` 抛 `RtcError` → 整条 pump 暴毙" class.
- One dispatcher coroutine **per lane** (serialized within a lane, concurrent across lanes);
  a partial/audio flood can never delay a final.
- Heavy handlers (the LLM pipeline) **post-and-spawn**, never run inline in the dispatcher.
- **NOT a Redis replacement**: Redis stays the inter-service boundary. The bus is a NEW
  *intra-process* channel — gets one entry in `service-communication/spec.md` per the
  channel-discipline rule (realtime / lossy-OK or lossless-lane / single-CallSession-scoped
  / never-cross-process).

```python
# sketch — the bus is generic over @dataclass(slots=True) event types
class EventBus:
    def register_lane(self, event_type: type, lane: Lane) -> None: ...   # lossless default for *Final/*Request*
    def subscribe[T](self, t: type[T], handler: Callable[[T], Awaitable|None]) -> Unsub: ...
    def post(self, event: object) -> None: ...        # non-blocking; lossless lane never drops
    async def aclose(self) -> None: ...               # drain lossless, then stop
# every handler is wrapped:  try: await h(ev)  except CancelledError: raise  except Exception: log+isolate
```

### 2.2 SelectRouter — Python port of `core/selectrouter`

```python
class ExecutableRoute(Protocol):              # dialogues / referees / tools all implement this
    def route_id(self) -> str: ...
    def metadata(self) -> dict: ...
    async def execute(self, ctx, input) -> Any: ...   # dialogue → async-generator; tool → dataclass

class Router:   # Router[Input, EvalResult, DeciderOutput]
    async def route(self, ctx, input, eval_fn) -> list[RouteResult]:
        self._cancel_and_reset_previous()
        for r in self._eager: r.start_eager(ctx, input)   # dialogues begin streaming NOW
        ev = await eval_fn(ctx)                            # referees (parallel, timeout, fail-open)
        decision = self._decider.decide(ev)               # reuse pipeline/decider.py verbatim
        ids = self._selector(decision)
        self._cancel_unselected(ids)
        return [await self._consume(i, ctx, input) for i in ids]
```

Mapping to existing iSales code:
- **Decider** = `pipeline/decider.py:decide()` reused **verbatim** (already first-match-wins;
  keeps iSales's exact `category in match[]` matching — strictly better than voxen's
  `strings.Contains` substring). Add one new action kind `select_dialogue{to:<label>}`.
- **Referees** = the `eval_fn` (like voxen `ExecuteReferees`), small model, **parallel**,
  **non-streaming**, **~500–700ms timeout**, **fail-open to continue**.
- **Dialogues = EAGER**, and the route's output is the **live `stream.sentences()` async
  generator handed un-consumed to `_play_streaming`** — ⚠️ the ONE deliberate deviation from
  voxen's literal `getResult` (which drains to completion); draining in the router would
  consume all sentences with no TTS attached. Must be loudly documented + regression-tested.
- **Tools = LAZY** (hangup / transfer / state-transition effects); execute only when selected.

### 2.3 CallStatus state machine — survives as an **advisory subscriber**

The 11-state FSM does NOT dissolve (api/web/transcript consume the states). Change:
`transition_to` is called by a **single EventBus subscriber** (single-writer FSM), not by the
turn loop directly. Advisory semantics preserved: illegal transitions **warn, not throw**;
every transition emits a transcript event so transcript stays state-aligned.

---

## 3. The turn, end to end (target)

1. `asr.final` (lossless) → turn orchestrator wakes (replaces `asr_finals_q.get()`).
2. `router.route(input=user_text, eval_fn=run_referees)`:
   - eager dialogue persona(s) start streaming (buffer tokens);
   - referees classify in parallel (small model, timeout, fail-open);
   - `decide()` → action; selector → route id.
3. Selected route:
   - **dialogue** → hand live generator to `_play_streaming` → sentence-split → TTS → audio;
   - **hangup tool** → (optional `closing_phrase` via fixed-string TTS) → END,
     `hangup_cause=referee_hangup`; **the normal reply is never emitted** (clean replace);
   - **transfer tool** → `_perform_handoff`;
   - **transition** (goal_achieved / customer_decline) → FSM transition as today.
4. Barge-in: monitor `post(InterruptRequested)` (lossless) → playback owner cancels **itself**
   (replaces reach-across `current_speaking_task.cancel()`); un-spoken remainder captured →
   `interrupt_remaining_text` → next-turn restructure (feedback loop preserved).
5. Turn trace → `pipeline_trace` (per-route metadata); status changes → FSM subscriber.

---

## 4. Hard constraints — **MUST NOT silently drop** (the "做得彻底" checklist)

Each was added for a hard-won real-call reason; dropping any is a regression.

- **final-coalescing debounce** — else the "AI floods user with backlogged replies" bug returns.
- **barge-in remainder capture → `interrupt_remaining` restructure** feedback loop (1 of 3
  restructure triggers).
- **shielded finalize** + **DECR snap-to-0** — global concurrency counter must not leak;
  post-call persistence/LPUSH runs exactly once even under cancellation.
- **fail-open referees** + exactly **ONE** removal-tracked streaming fallback (`chat_stream→chat`)
  + the separate never-go-silent `default_reply` guard. **Do not stack a second fallback layer**
  (multi-layer-fallback anti-pattern).
- **pre-synth producer/consumer TTS pipeline** (maxsize=2 lookahead + cancel-and-aclose hygiene)
  — a naive TTS sink loses the first-audio win and leaks vendor connections on barge-in.
- **pipeline_trace schema + enum-validated transcript event vocabulary** — external contracts
  (api/web/worker read them).
- **cross-turn counters**: `consecutive_interruption_count`, `consecutive_restructure_count` (cap),
  `silence_activation_count`, `wrap_up_round_count`, `interrupt_remaining_text`.
- **greeting non-interruptible** ordering (pumps start after greeting).
- **text-length ≥ 2 gate** + **wall-clock speech anchor** (both fixed documented real-call regressions).
- **wrap-up mode flag** disabling referees/transfer/filler + dual rounds+seconds counter.
- **post-call extractor stays offline** (engine emits `extracted={}` inline; do not re-add inline).
- **manual-hangup / transfer control** arrives over Redis Pub/Sub → `post()` as lossless event
  (retires the `request_manual_hangup` `main.cancel()` sentinel hack).

---

## 5. Migration — strangler-fig, 5 phases, behavior-frozen

Freeze the `run_session()` end-to-end contract + a **golden-transcript regression test**
(byte-identical `full_transcript` + `pipeline_trace` before/after) throughout. A
**sync test-mode bus** (inline drain) keeps event-sequence assertions deterministic.

| Phase | Work | Behavior change | Gate |
|---|---|---|---|
| **0** | Add EventBus + Router abstractions **alongside** existing loop | none | unit tests for new abstractions |
| **1** | Migrate signals (ASR/interrupt/TTS/lifecycle) → EventBus; consumers unchanged | none | golden-transcript identical |
| **2** | Dispatch via `router.route()`; **effects still in run_loop** (temp adapter) | none | golden-transcript identical |
| **3** | Add tools[hangup/transfer] + **referee-gating** + **eager multi-dialogue** | **yes** (gating, hangup-replaces, personas) | new behavior tests + real-dial UX |
| **4** | Delete legacy `if/elif` + temp adapter | none (equivalent) | golden-transcript identical |

- **Kill-switch** `ENGINE_USE_ROUTER` env flag spans Phases 2–3 (old ladder as fallback);
  **removal trigger = the Phase-4 deletion commit** (every fallback names its removal condition).
- Phase 2's "decision-in-Router, effects-in-run_loop" adapter is itself temporary two-layer
  indirection — **its removal MUST be part of the Phase-4 commit**, not deferred.

### Ship as a SEQUENCE of 3 OpenSpec changes (not one mega-change)

Disjoint spec clusters so deltas don't overwrite (the exact failure the archived multi-referee
work flagged). Archive change N before opening N+1's overlapping delta.

1. **`engine-eventbus-foundation`** (Phases 0–1) — zero behavior risk; soak on ECS first.
   Spec: `service-communication` (new in-process channel-type), `architecture` (co-location note).
2. **`engine-multi-route-dispatch`** (Phase 2 + the Router/ExecutableRoute extraction) —
   Spec: `ai-pipeline` (decider→Router), `call-state-machine` (FSM-as-subscriber).
3. **`engine-tools-multidialogue-gating`** (Phase 3–4) — hangup/transfer tools, referee-gating,
   eager multi-dialogue. **Hangup folds in here.** Spec: `ai-pipeline` (gating + tools +
   multi-dialogue), `data-model` (ToolConfig + multi-dialogue config + `HangupCause.REFEREE_HANGUP`),
   `web-admin-ui`, `retry-followup`.

---

## 6. Spec impact

| capability | change |
|---|---|
| `ai-pipeline` | **major** — referee二级决策 from post-reply judge → **pre-reply gating selector**; routing decider → SelectRouter; tools; multi-dialogue |
| `service-communication` | **NEW in-process EventBus channel-type** (lossless/lossy lanes; never-cross-process) |
| `call-state-machine` | FSM **survives** but becomes a single-writer EventBus subscriber; advisory semantics unchanged |
| `data-model` | `ToolConfig` (hangup/transfer), multi-dialogue persona config, `HangupCause.REFEREE_HANGUP` |
| `web-admin-ui` | action editor: hangup tool + closing_phrase + persona/dialogue config + goal_type 422 fix |
| `retry-followup` | `referee_hangup` = no-auto-redial classification |
| `architecture` | engine-session co-location note (barge-in in-process, not Redis) |

---

## 7. Open tuning knobs (decide during `/opsx:explore`)

- **Referee timeout**: target ~500–700ms (voxen uses 1.0s). Tighter = fewer tail-latency taxes,
  more fail-opens. Measure on mac-dev + real dial.
- **Persona fan-out cap N**: ≤2–3. Eager (latency) vs the rejected lazy (cost) — locked as eager
  per user; cap controls the token blast radius.
- **Fail-open target**: referee timeout/error → `continue` (keep talking) vs `main` persona.
- **Terminal-verdict UX**: gating means hangup/transfer suppress the reply entirely — validate
  it doesn't feel abrupt vs a one-line acknowledgement before acting.

---

## 8. Risks

- **Barge-in cancel timing** shifts from direct `task.cancel()` to event-driven self-cancel —
  re-validate the signal-then-cancel race (run_loop.py:1459-1461, call-143 evidence) on a real
  call before shipping Phase 3.
- **Eager persona token cost** (Phase 3) — bounded by cap + budget alarms; vendors bill
  cancelled tokens.
- **FSM-as-subscriber ordering** — a route-completion event and its transition could interleave;
  enforce single FSM-writer + golden-transcript asserts transition/trace ordering.
- **Eager-generator deviation** — if a future maintainer "fixes" the router to await eager routes
  to completion (matching Go), every dialogue turn silently consumes its own sentences with no
  audio. Loud doc + regression test.
- **Cross-repo version bump** (change 3: `isales-common` ToolConfig + HangupCause) needs lockstep
  pin of engine/api/scheduler.

---

## 9. Supersedes `referee-hangup-action`

The active `referee-hangup-action` change (commit `b3b9051`) models hangup as a 4th
`DeciderAction.kind` `if/elif` branch — which **Phase 4 deletes**. Shipping it first builds
throwaway scaffolding (CLAUDE.md anti-pattern).

- **Fold** hangup into change 3 as a **lazy `tools[hangup]` ExecutableRoute** (voxen
  `tool_sip_hangup.go` model).
- **Cherry-forward the architecture-independent parts now** (optional, low-risk): the web
  `goal_type`-on-target-switch **422 fix** (already a real bug), and reserve `HangupCause.REFEREE_HANGUP`
  + retry-followup classification for change 3.
- **Release valve**: if change 2/3 slips > ~2 weeks and "customer says stop-calling → must hang up"
  becomes an urgent compliance gap, ship the original additive proposal as a clean-rollback stopgap
  (cost: one throwaway `if`-branch).
