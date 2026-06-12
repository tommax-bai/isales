## Why

`CallSession.append_event` (isales-engine) only checks the event *discriminator*
(`event_type in TRANSCRIPT_EVENT_TYPES`) — it never validates the event's
*fields* against the `TranscriptEvent` contract. So engine-vs-schema drift (a
wrong literal value, an extra key, a missing/typed field) is silently persisted
into `call_record.transcript` JSONB and only explodes later as a pydantic
`ValidationError` when `isales-api` reads it back (`CallRecordRead` validates
with `extra="forbid"`), 500-ing the whole 外呼记录 list page. This same root
cause has now caused **three** production `GET /calls` 500 incidents
(2026-06-10 `ai_reply.interrupted` + `interruption.{rms,source,voice_active_ms}`;
2026-06-12 `wrap_up_completed.reason`). The drift is invisible at the source and
expensive to diagnose at the sink — close the gap where it is written.

## What Changes

- `CallSession.append_event` validates each constructed event against the
  `isales_common` `TranscriptEvent` discriminated union (full field / literal /
  extra-key / required-field contract), in addition to the existing
  discriminator check.
- On a contract violation the engine **always** logs a structured
  `transcript_event_schema_violation` error (event type + validation errors).
- Behaviour on violation is **fail-soft in production, fail-fast in CI**:
  - Production (default): log the violation and **still persist** the event — the
    transcript is observability data and `append_event` runs in the hot path of
    live customer calls; a logging-contract bug MUST NOT drop a call.
  - Strict mode (`ISALES_ENGINE_STRICT_TRANSCRIPT=1`, set by the engine test
    conftest): **raise**, so every existing engine test that drives a real flow
    becomes a drift detector and any out-of-contract event fails the suite.
- New tests: a focused unit test (bad event raises under strict, logs under
  non-strict) + a test that loads every `tests/golden/*.json` transcript and
  validates each event against `TranscriptEvent`.
- This deliberately does NOT make the `isales-api` reader lenient — that would
  mask data corruption instead of surfacing it.

## Capabilities

### New Capabilities
<!-- none -->

### Modified Capabilities
- `transcript`: add a requirement that the engine MUST validate transcript
  events against the `TranscriptEvent` contract at write time, MUST log a
  structured violation on failure, MUST NOT abort an in-progress call on such a
  violation in production (fail-soft), and that CI/strict mode MUST fail on it.

## Impact

- **isales-engine** only: `isales_engine/call_session.py` (validation + logging),
  `tests/conftest.py` (enable strict mode), new tests.
- No `isales-common` / `isales-api` / `isales-web` / `scheduler` / `worker`
  changes. No Alembic migration, no DB schema change.
- New optional env var `ISALES_ENGINE_STRICT_TRANSCRIPT` (default off in prod).
- Mild per-event validation cost on the write path; transcript events are
  per-turn (low frequency), so negligible.
