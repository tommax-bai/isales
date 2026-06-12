<!-- DONE 2026-06-12 — engine 423b2f9 (call_session.py + conftest + test) deployed to ECS, engine restarted clean. meta: STATE.md + archive. No common/api/web/alembic. -->

## 1. Engine write-time validation

- [x] 1.1 In `isales_engine/call_session.py`: build a module-level `TypeAdapter(TranscriptEvent)` (import from `isales_common.schemas.jsonb`) and a module `logger`. <!-- 423b2f9: _TRANSCRIPT_EVENT_ADAPTER: TypeAdapter[object] + logger -->
- [x] 1.2 In `append_event`, after assembling `event` and before `full_transcript.append`, validate `event` via the adapter; on `ValidationError` always `logger.error("transcript_event_schema_violation", type, exc.errors(include_url=False))`, and raise only when `os.getenv("ISALES_ENGINE_STRICT_TRANSCRIPT") == "1"` (read in the failure branch). Keep the existing `event_type not in TRANSCRIPT_EVENT_TYPES` `ValueError` guard. Add a comment naming the guard's purpose + that it is a permanent invariant (not a fallback). <!-- 423b2f9 -->

## 2. Test net

- [x] 2.1 In `tests/conftest.py`: set `ISALES_ENGINE_STRICT_TRANSCRIPT=1` at module import (before engine modules load) so the whole suite runs strict. <!-- 423b2f9: os.environ.setdefault(...) -->
- [x] 2.2 Add a unit test: a `wrap_up_completed` event with `reason="rounds_exhausted"` raises under strict and (with strict off) logs `transcript_event_schema_violation` while still appending; a valid event appends with no log/raise. <!-- 423b2f9: tests/test_transcript_write_validation.py -->
- [x] 2.3 Add a test that loads every `tests/golden/*.json` transcript and validates each event against `TranscriptEvent` (regression net for golden drift). <!-- 423b2f9: test_all_golden_transcripts_validate -->

## 3. Verify

- [x] 3.1 Run the full engine suite with strict on; triage and fix at the write site any out-of-contract event surfaced (pre-existing unrelated failures excepted). Run `isales-common` tests for sanity (no change expected). <!-- 425 passed under strict; NO new strict failures = no other latent drift in any engine test path. 1 pre-existing test_gate_fails_open_to_main_on_referee_timeout unrelated. common 189. ruff+mypy clean. -->
- [x] 3.2 `openspec validate engine-transcript-write-validation --strict` passes. <!-- valid -->

## 4. Deploy + archive

- [x] 4.1 scp `call_session.py` to ECS engine source (`/opt/isales/current/isales-engine`), restart `isales-engine`, confirm clean startup (env var stays unset → validate-and-log only). Update `deploy/cloud/STATE.md`. <!-- 423b2f9 deployed; engine active, cloud_edge_grpc_server_started + isales_engine_started clean; ISALES_ENGINE_STRICT_TRANSCRIPT unset in prod (fail-soft). -->
- [x] 4.2 Commit (engine + meta) + push; archive the change after acceptance. <!-- engine 423b2f9 pushed; meta commit + archive this session -->
