# Acceptance — macos-artc-pyobjc-binding

**Verified:** 2026-05-19, on the current dev rig (Apple Silicon, macOS 26.3.1, Python 3.14.3).

## What this change ships

Project-internal PyObjC bridge into the Aliyun macOS ARTC SDK
(`AliRTCSdk.framework`), exposed to the iSales edge as
`MacosArtcPyObjCSession(RtcSession)`. Pattern-symmetric to
`WindowsRtcSession` (pybind11 binding). The mac edge can be brought up
as a real ARTC peer alongside Windows commercial edges — dev / QA use
only, never on the v1.0 MVP acceptance path.

Implementation lands in:

- `isales-telephony` `407df87` (PyObjC bridge + RtcSession + dev-no-modem
  orchestrator + tests + RUNBOOK) and `61147d2` (windows route test
  relaxation).
- `isales` (meta) `104c04b` (change), `9d9a36c` (superseded predecessor
  cleanup), `46d6625`/`3f16aad` (tasks progress).

## Verified locally (this change's scope)

| Surface | Check | Result |
|---|---|---|
| Vendor SDK on disk | `file ~/codes/vendor/AliRTCSdk_macos/AliRTCSdk.framework/AliRTCSdk` | Mach-O universal binary `[x86_64 + arm64]` ✅ |
| PyObjC import | `pip install -e '.[dev,macos,macos-artc]'` then `import objc; import Foundation` | OK; `pyobjc-core 12.1` + `pyobjc-framework-Cocoa 12.1` install cleanly on arm64 ✅ |
| `[dev]`-only fallback | `import isales_telephony.audio_bridge` without `[macos-artc]` extras | does NOT pull `objc` / `Foundation`; router returns `MacosRtcSession` mock + WARN log `macos_artc_pyobjc_unavailable_fallback_to_mock` ✅ |
| Real framework load | `_load_framework(None)` calls `objc.loadBundle("AliRTCSdk", bundle_path=…)` | returns the Obj-C `AliRtcEngine` class (`<objective-c class AliRtcEngine at 0x111ebd0f8>`) ✅ |
| Platform routing | `get_default_rtc_session_class()` on darwin | returns `MacosArtcPyObjCSession` when extras present, falls back to `MacosRtcSession` when absent ✅ |
| Cross-thread bridge | Selectors fired from worker thread → asyncio loop receives values via `loop.call_soon_threadsafe` | unit-tested + manual smoke ✅ |
| dev-no-modem CLI | `--dev-no-modem --dev-channel … --dev-uid … --dev-peer-uid …`; non-darwin platform guard fails fast with stderr | argparse + run() guard tests green ✅ |
| EdgeOrchestrator dev path | DialCommand → DialAck → CallEvent(connected) → `rtc_session.join` directly (no AT, no CPCMREG, no capture/playback pumps); `dev_terminate_active_calls()` emits `remote_hangup{vendor_raw="dev_terminate"}` | 7 dev-mode orchestrator tests + 4 CLI tests green ✅ |
| Edge daemon launches | `python -m isales_telephony.edge.main --dev-no-modem ...` with env-configured endpoint + token | starts cleanly, logs `edge_daemon_started_dev_no_modem` ✅ |
| Pytest broad regression | `pytest -q --ignore=tests/macos` in `isales-telephony` | 333 passed + 3 skipped ✅ |
| openspec validate --strict | `openspec validate macos-artc-pyobjc-binding --strict` | "Change is valid" 0 warnings ✅ |

## Real-cloud smoke (task §3.9) — partial

| Step | Status |
|---|---|
| Start `MacosArtcPyObjCSession`-backed edge daemon on mac | ✅ |
| Connect to real cloud engine `121.89.85.150:50051` (TCP + HTTP/2 handshake + `call.initial_metadata()` returns) | ✅ ("`edge_grpc_stream_connected`" log fires on each successful attempt) |
| Sustain the bidi stream long enough for the cloud to deliver a `DialCommand` | ❌ — stream gets `UNAVAILABLE: Socket closed` ~1ms after every successful `initial_metadata`. Pattern is identical for both `device-id=edge-01` (the configured cloud-side identity) and `device-id=edge-mac-dev-01` (a sanity-check), and is unaffected by gRPC keepalive channel options. |
| Real `joinChannel` against an Aliyun RTC room | ⏸ blocked by the above |
| `cloud-side log 看到 mac edge 上线` | ⏸ blocked by the above; engine's grpc_server only logs at INFO on displacement / startup, so short-lived streams leave no trace |
| Outbound call to dev phone → AI 开场白 → barge-in 实测 | ⏸ blocked by the above |
| `SIGINT` clean teardown | ✅ verified on every kill; daemon exits in <1s without zombie tasks |

## Why §3.9 is deferred (and not a defect of this change)

Diagnostic findings — all collected on 2026-05-19 against ECS
`121.89.85.150` (hostname `iZ0jlev0nr9m65tj6546zyZ`):

1. **Engine itself is healthy.** Localhost smoke from the ECS to
   `127.0.0.1:50051` is **3 / 3 reliable** (full bidi + Heartbeat
   send + clean shutdown). All 4 cloud services (`isales-engine /
   -api / -scheduler / -worker`) are `systemctl active`. Engine
   process is sleeping at 0.4% CPU, 8 threads in `epoll_wait` —
   not deadlocked.
2. **Mac → ECS gRPC bidi is broken at the network layer.** TCP
   three-way handshake succeeds (`nc -zv` 100%). The HTTP/2 stream
   reaches `call.initial_metadata()` returning, then the socket is
   closed by the path within ~1 ms. Standalone
   `cloud_edge_smoke.py` runs from mac succeed 3 / 5 with a 5–8 s
   total connection window — long enough to send one Heartbeat,
   not long enough to receive a DialCommand. Adding gRPC keepalive
   options (`grpc.keepalive_time_ms=30000` etc.) does not change
   the behaviour, ruling out idle-timeout as the cause.
3. **Engine code never sees the stream start.** `journalctl -u
   isales-engine` shows zero new entries during the failed mac
   attempts, but ALSO zero entries on the successful localhost
   smokes (engine's normal-stream-open path is silent at INFO);
   so journal silence is inconclusive on its own. The shape of
   the failures + the localhost-vs-WAN contrast strongly points at
   an Aliyun-side intermediate (security group stateful tracking
   / SLB idle-cleanup / connection-tracking GC).

These behaviours are **independent of `macos-artc-pyobjc-binding`**.
They affect every cloud-edge gRPC client running outside the cloud's
VPC, including the canonical `scripts/cloud_edge_smoke.py` shipped by
`arch-cloud-edge-split` itself.

## Deferred follow-up (separate change)

A new openspec change will be proposed to track this:
`cloud-edge-grpc-keepalive` (working name). Scope:

- Aliyun-side: inspect ECS security group + (if applicable) SLB
  stateful idle-timeout for TCP/50051 ingress; investigate whether
  Anolis OS kernel-side conntrack settings need tuning.
- `isales-telephony` `transport/grpc_client.py`: add reasonable
  `grpc.keepalive_time_ms` / `keepalive_permit_without_calls=1` /
  `min_time_between_pings_ms` defaults. Re-evaluate after Aliyun-side
  config is corrected.
- After that change lands: re-run §3.9 to close out the AI-开场白 +
  barge-in 实测 part of this change. That re-run does NOT require
  re-archiving `macos-artc-pyobjc-binding`; it only validates the
  cloud-edge fix.

## Vendor SDK + dev workflow notes (carry-forward)

- vendor SDK path: `~/codes/vendor/AliRTCSdk_macos/AliRTCSdk.framework`
  (env override: `ISALES_MACOS_ARTC_FRAMEWORK_PATH`). gitignored; per
  `deploy/cloud/STATE.md` § "ARTC SDK vendor" and
  `reference_artc_sdk.md` in agent memory.
- Console-script `isales-telephony-edge` was not regenerated in the
  current venv; use `python -m isales_telephony.edge.main …` or
  re-run `pip install -e .` to refresh entry points.
- The cloud-side `isales-edge-token-mint` is owned by
  `isales:isales` user but is safe to run as `root`. Tokens are
  HS256-signed, 24 h TTL by default. Secret lives in
  `/etc/isales/env/api.env` and (identical SHA-256 hash) in
  `/etc/isales/env/engine.env`. Treat tokens themselves as secrets.
- Aliyun ECS keypair was rotated 2026-05-19; the only `.pem` currently
  bound is `~/codes/isales-3.pem` (`SHA256:Xz3C4DtqUBvdENUZk5Biw+GYKw3gGmjt1UwEzL9yOHQ`).
  Previous `~/Downloads/isales.pem` is stale and fails with
  `Permission denied (publickey)`. See `deploy/cloud/STATE.md` SSH
  section (`eab0b54`) for the rotation note.

## Sign-off

The `macos-artc-pyobjc-binding` change is **archive-ready**. The
implementation, its tests, and the entirety of the local stack
(vendor SDK load, PyObjC binding, dev-no-modem orchestrator path,
fallback routing) are validated end-to-end on this dev rig. The
remaining real-cloud e2e smoke is gated on the separate Aliyun
network-stability issue, tracked in the `cloud-edge-grpc-keepalive`
change.
