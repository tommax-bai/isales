# impl-real-at acceptance log (2026-05-17)

**Status**: Code-ship complete; hardware acceptance deferred to `windows-client-core` §9.

This change introduced `SerialATClient` (production `ATClient` implementation),
env-driven dispatch in `modem_controller/main.py`, the `at_smoke.py` real-
hardware smoke script, the canonical `HangupCause` vocabulary alignment, and
the corresponding `device-hardware` + `call-state-machine` spec deltas. The
final task in this change — task 3.4 "real-hardware 5-call acceptance" — is
deferred and documented below.

## PRs landed (isales-telephony)

| Task | Commit | Subject |
|---|---|---|
| §1 SerialATClient + hangup_cause alignment (incl. §4.3) | `fa3167c` | `PR #1 (impl-real-at): SerialATClient + canonical hangup_cause vocabulary` |
| §2 env dispatch + handlers cleanup | `3c7ffe8` | `PR #2 (impl-real-at): env-driven ATClient dispatch; no silent mock fallback` |
| §3.1–3.3 smoke script + README | `acff6aa` | `PR #3 (impl-real-at): scripts/at_smoke.py + README hardware smoke section` |

## Unit + integration tests (as-landed)

Per tasks.md §1.9 recorded at PR #1 (`fa3167c`) landing time on the
Linux/macOS rigs of that period:

- `pytest tests/modem_serial/test_serial_at_client.py` — **11 passed** in 0.24 s
  (covers AT+CLCC active → connected; NO CARRIER → user_hangup; BUSY →
  user_busy; NO ANSWER → no_answer; NO DIALTONE → network_out_of_order; ATD
  ACK timeout → immediate remote_hangup; local hangup → manual_hangup;
  unknown call_id hangup idempotent; concurrent dial rejection; signal/iccid/
  imei passthrough; `_clcc_has_active_call` parsing).
- Full modem-related suite (`tests/modem_serial/` + `tests/test_modem_dial.py`
  + `tests/test_modem_pump_cancel.py` + `tests/test_fake_modem_e2e.py` +
  `tests/test_modem_ipc.py`) — **50 passed**.

### Re-run attempt on this Windows dev box (2026-05-17)

Running `pytest` against the same suite on this Windows dev machine fails at
**collection** time:

```
isales_telephony\modem_controller\at_client.py:24: in <module>
    import fcntl
E   ModuleNotFoundError: No module named 'fcntl'
```

This is the exact platform-layer issue D1 `windows-client-core` §3 footer
(tasks.md line 28) and §8.3 footer commit `f39e75b` explicitly defer to a
follow-up PR: extracting `fcntl` to a Linux/macOS-only platforms layer (and
providing a `msvcrt.locking` / no-op equivalent on Windows). Until that
follow-up lands, `SerialATClient` cannot import on Windows and no Windows-
hosted pytest covers `tests/modem_serial/`.

## Spec deltas

Both deltas validated via `openspec validate impl-real-at --strict` and
inspected via `openspec change show impl-real-at --json --deltas-only`
(task §4.1, §4.2 done):

- `device-hardware`: ADDED Requirement "ATClient 实现策略" (`SerialATClient` =
  v1 prod impl, `MockATClient` limited to CI/dev, `main.py` strict env
  dispatch, no silent fallback) + URC → ATEvent translation contract.
- `call-state-machine`: ADDED Requirement "真硬件 URC 驱动状态转换" + new
  Requirement "hangup_cause 单一来源" (canonical `isales_common.enums.
  HangupCause` enum; `manual_hangup` excluded from retry-followup retry
  list).

## Post-A2/D1 scope retraction (re: task 3.4)

A1 was proposed under the v1 "single-host" deployment assumption — modem-
controller co-resident with engine/api/scheduler/worker on a single Linux or
macOS box. design.md § Migration Plan #4 reads "用 A7670E + 国内 SIM，跑
at_smoke.py 拨自己手机" and § Impact targets "deploy/linux + deploy/macos".

That assumption has been **superseded** by:

- A2 `arch-cloud-edge-split` — engine / api / scheduler / worker / web move to
  Aliyun ECS (Linux); only `modem-controller` + `audio-bridge` stay on the edge.
- D1 `windows-client-core` — the edge host is retargeted from Mac mini to
  customer-owned Windows PCs. macOS is retired from the v1.0 prod path
  (retained only as historical QA reference).

In v1.0 prod, `SerialATClient` therefore runs **only on Windows**.
Linux/macOS hardware acceptance (A1 task §3.4 literal) has lost its prod-
value rationale on the platforms A1 scopes. The corresponding hardware
validation work for `SerialATClient`'s real-modem path now lives in:

- **D1 §3 follow-up PR** (footer line 28) — Windows ATClient platform-layer
  refactor (`fcntl` → `msvcrt.locking` / no-op), making `SerialATClient`
  Windows-importable.
- **D1 §9 端到端验证** — actual 5-call acceptance on Windows + SIM7600G-H
  rig (this developer's hardware), including the symptoms task §3.4 calls out
  (manual_hangup / no_answer / user_busy) plus tray + activation UX.

The reverse cross-link will be added to `windows-client-core/acceptance.md`
when D1 archives.

## Out-of-scope deferred items

- **§3.4** (real-hardware 5-call acceptance) — deferred to
  `windows-client-core/acceptance.md` § "端到端验证 (§9)". Rationale above.
- **§4.4** (this acceptance log) — satisfied by the present file, minus the
  hardware-log section that §3.4 would have produced.
- **§5.1** (`openspec archive impl-real-at`) — to be invoked via
  `/opsx:archive impl-real-at` by the user.
- **§5.2** (v1-roadmap.md A1 status update from "待开" to "已归档") — done in
  the same commit as this file (see git log for refs).

## Forward-looking notes

- When D1 §3 follow-up PR lands the Windows platform-layer split, the
  Windows pytest job in `isales-telephony/.github/workflows/ci.yml`
  (`windows-tests`, currently scoped to `tests/windows tests/test_platforms_
  dispatch.py tests/modem_audio`) should be widened to also cover
  `tests/modem_serial/` + `tests/test_modem_*.py`. That CI scope expansion
  is **explicitly noted** in D1 §8.3 inline footer (`f39e75b`).
- If D1 §9 hardware turns up a `SerialATClient` *design* issue (not just
  platform shim), follow-up should be a new OpenSpec change rather than
  re-opening this archive — per project convention (precedent:
  `archive/2026-05-12-impl-deploy-macos` deferring 12.4/12.5 to a separately
  proposed `impl-real-at`).
