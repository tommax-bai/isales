## Context

This is step 1 of the flat refactor (`engine-flat-refactor-blueprint.md`). The engine's
intra-call coordination today (`run_loop._ListenContext`): `asr_finals_q`/`asr_partials_q`
queues, `hangup_event`/`asr_finished` events, monitors reaching across to
`session.current_speaking_task.cancel()`, and the `request_manual_hangup` → `main.cancel()`
sentinel. The later changes (multi-route SelectRouter, CallStatus projection) need a typed
event substrate; this change builds it without changing behavior.

## Goals / Non-Goals

**Goals:**
- A typed, in-process, two-lane EventBus with per-handler exception isolation.
- Migrate the existing coordination signals onto it with the consumer (`_main_turn_loop`)
  byte-identical (golden-transcript net stays green).

**Non-Goals:**
- No SelectRouter / route dispatch / CallStatus projection (change-2+).
- No Redis replacement; no cross-process bus; no isales-common change.
- Raw PCM stays a DIRECT telephony iterator ↔ sink (off the bus) to avoid hot-path copies.

## Decisions

### D1: Two lanes (lossless + lossy), not voxen's single drop-oldest bus
voxen's bus is uniformly drop-oldest — correct for audio, **catastrophic for a user's ASR
final** (a dropped final = a silently-missed customer turn). So delivery splits by event TYPE:
lossless = unbounded `asyncio.Queue` (`put_nowait` cannot drop); lossy = bounded drop-oldest.
- **Default lane = LOSSLESS** for unknown/unregistered types (safe — never silently drop);
  high-volume lossy events (`AsrPartial`/`VadFrame`) are registered LOSSY explicitly.
- Alternative rejected: a tunable buffer with a configurable drop policy — an unbounded
  lossless queue gives a *provable* never-drop guarantee, not a tuning knob.

### D2: Per-handler exception isolation is the load-bearing hardening
Each handler call is wrapped `try/except Exception` (logged) with `CancelledError` re-raised.
Directly fixes the documented pump-death bug class (one `RtcError` killed the whole uplink
pump). One bad handler can no longer take down the dispatch loop or sibling handlers. The
`CancelledError` re-raise is mandatory — barge-in self-cancel depends on it.

### D3: One dispatcher coroutine per lane
Serialized within a lane (no CallSession-mutation races on the lossless lane), concurrent
across lanes (a partial/audio flood never delays a final). Heavy handlers (the LLM pipeline,
later) MUST post-and-spawn, never run inline in the dispatcher.

### D4: Phase 1 keeps the consumer byte-identical via a bridge
`_main_turn_loop` is NOT rewritten in this change. Producers post bus events; a thin bridge
subscriber feeds `AsrFinal`/`AsrPartial`/`HangupDetected` back into the existing
`asr_finals_q`/`asr_partials_q`/`hangup_event` so the loop is unchanged. This keeps the
golden-transcript net byte-identical and isolates risk. The loop itself is replaced in change-2.

### D5: Bus events are NOT the Redis wire contract
Bus events are cheap `@dataclass(slots=True, frozen=True)`, separate from the pydantic
`EngineEvent` union. A later bridge adapts the publishable subset to `EngineEvent`. This keeps
the hot path off pydantic and lets bus events carry values that never cross Redis.

## Risks / Trade-offs

- **[Forgotten lane registration silently drops]** → mitigated by LOSSLESS-by-default; only an
  explicit `register_lane(LOSSY)` can make an event droppable.
- **[Barge-in cancel timing shifts]** (Phase 1: reach-across `task.cancel()` → event-driven
  self-cancel) → re-validate the signal-then-cancel race (run_loop.py:1459-1461, call-143) on a
  real dial before relying on it; this change keeps the bridge so the legacy path can stay until
  validated. Mitigation: golden net + sync test-bus.
- **[Dispatcher stalls if a handler blocks]** → post-and-spawn rule for heavy handlers; light
  handlers inline-await only.
- **[Lossless drain at close]** → `aclose` drains the lossless lane (bounded to pre-close
  events) before stopping, preserving the shielded-finalize / DECR-snap-to-0 invariant.

## Migration Plan

Phase 0 (done): add `eventbus.py` + `events.py` + `test_eventbus.py` — pure addition, zero wiring.
Phase 1: migrate the pumps/monitors/control to producers + the bridge subscriber; golden net
must stay byte-identical. Rollback = revert the run_loop wiring; the modules are inert additions.
