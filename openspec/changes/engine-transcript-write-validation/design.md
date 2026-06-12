## Context

`CallSession.append_event` (`isales-engine/isales_engine/call_session.py`) is the
single chokepoint through which every transcript event is written. Today it only
guards the discriminator:

```python
if event_type not in TRANSCRIPT_EVENT_TYPES:
    raise ValueError(...)
event = {"type": event_type, "ts": ts_ms, **fields}
self.full_transcript.append(event)
```

The field payload (`**fields`) is never checked against the `TranscriptEvent`
discriminated union in `isales_common`. The api side IS strict
(`CallRecordRead.transcript: list[TranscriptEvent]` with `extra="forbid"`), so
any field drift becomes a `GET /calls` 500 — but only at read time, often days
later, for an unrelated session. Three incidents to date share this exact shape
(`ai_reply.interrupted`, `interruption.{rms,source,voice_active_ms}`,
`wrap_up_completed.reason`). The write site is where the contract should be
enforced.

## Goals / Non-Goals

**Goals:**
- Catch transcript contract drift at the write site, at the source repo, before
  it ships — ideally as a failing test in CI.
- Make any drift that does reach production immediately visible in engine logs at
  the moment it is written, not as a downstream api 500.
- Zero risk to live calls: validation must never abort an in-progress call in
  production.

**Non-Goals:**
- Making the `isales-api` reader lenient / skipping bad rows. That masks data
  corruption; the contract stays strict on read.
- Validating high-frequency audio-frame paths — only discrete transcript events
  go through `append_event`.
- Backfilling / re-validating historical rows (handled per-incident by data
  migrations; out of scope here).

## Decisions

**D1 — Validate against `TypeAdapter(TranscriptEvent)` inside `append_event`,
before the append.** A module-level `TypeAdapter` is built once at import. The
constructed `event` dict is validated with `validate_python` immediately after
it is assembled and before `full_transcript.append(event)` / dialog mirroring, so
a strict-mode raise leaves no partial state. _Alternative considered:_ a separate
lint/CI script that greps `append_event` call sites — rejected: it cannot see
runtime values (the wrap_up `reason` came from a function return, not a literal).

**D2 — Fail-soft in production, fail-fast in CI.** On `ValidationError`:
- Always `logger.error("transcript_event_schema_violation", type, errors)` using
  `exc.errors(include_url=False)` for compact logs.
- Raise **only** when `os.getenv("ISALES_ENGINE_STRICT_TRANSCRIPT") == "1"`. The
  env var is read inside the failure branch (not captured at import) to avoid
  import-order fragility. In production (var unset) the engine logs and still
  appends the event.

_Rationale:_ `append_event` runs in the hot path of real customer calls. A raise
there would propagate into `run_loop` and end the call as
`engine_internal_error` — turning a cosmetic logging-contract bug into a dropped
customer call, strictly worse than the current read-time 500. The transcript is
observability data; preserving the (slightly-wrong) event while screaming in the
logs is the correct production behaviour. _Alternative considered:_ always raise
— rejected for the live-call risk. _Alternative considered:_ drop the invalid
event in prod — rejected: silent data loss, and the api 500 is prevented far
more cheaply by the CI net (D3) than by mutilating the transcript at runtime.

**D3 — Strict-on in the engine test suite turns every existing test into a drift
detector.** `tests/conftest.py` sets `ISALES_ENGINE_STRICT_TRANSCRIPT=1`. Because
hundreds of engine tests drive real flows through `append_event`, any test that
produces an out-of-contract event now fails loudly — the broadest possible net
for the least code. Augmented by two focused tests: (a) a bad event
(`wrap_up_completed` with `reason="rounds_exhausted"`) raises under strict and is
logged under non-strict; (b) every `tests/golden/*.json` transcript validates
against `TranscriptEvent` (this alone would have caught the 2026-06-12 incident —
the golden fixture pinned the bad value).

**D4 — This is a guard, not a fallback.** Per the repo's "multi-layer fallback is
a code smell" principle: this layer surfaces the error rather than masking it,
provides no alternative success path, and is a permanent invariant (no removal
trigger). It is the opposite of a fallback.

## Risks / Trade-offs

- **[Strict mode reveals latent drift in other test paths]** → That is the
  intended outcome; fix any such event at its write site as part of this change
  (run the full engine suite with strict on during apply and triage every
  failure).
- **[Per-event validation cost on the write path]** → Transcript events are
  per-turn, not per-frame; validating a small dict against a discriminated union
  is microseconds. Negligible versus LLM/TTS latency.
- **[A future legitimately-new field logs errors until the schema is updated]** →
  Desired: the loud log is the signal to update `TranscriptEvent` in
  `isales-common`. Prod keeps working (fail-soft) meanwhile.

## Migration Plan

- Pure engine code + tests; no DB, no Alembic, no common/api/web changes.
- Deploy: scp `call_session.py` to the ECS engine source (shared
  `/opt/isales/current/isales-engine`) and restart `isales-engine`. The env var
  stays unset in prod, so behaviour is validate-and-log only.
- `conftest.py` and new tests are repo-only (not deployed).
- Rollback: scp the previous `call_session.py` and restart `isales-engine`.
