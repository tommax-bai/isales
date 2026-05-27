# Acceptance — engine-artc-sdk-thread-model

**Archived 2026-05-27 as SUPERSEDED.**

This change is archived **not because its own acceptance criteria
went green**, but because the entire problem domain it addressed was
overtaken at the root by `engine-rtc-dingrtc-migration` before the
sidecar thread model could be e2e-verified. The strict spec language
in § 5.6 (`MUST NOT archive` until § 5.3–5.5 PASS) is preserved as
historical evidence; the supersession path below replaces it.

## What this change set out to do

Fix `_AliyunArtcChannel._do_join` in `isales-engine/isales_engine/transport/aliyun_rtc.py`
so the vendor `AliRTCEngineImpl`'s `__recvCoroutine` had a persistent
asyncio loop to drive — by spawning a dedicated SDK driver thread per
channel and dispatching all vendor calls through it. Root-caused on
2026-05-25 from ECS sidecar logs (18 HTTP requests, all to httpdns,
zero to `gw.rtn.aliyuncs.com` → roomserver silent → 30 s timeout).

Implementation landed in `isales-engine@fb62fdd` (branch
`engine-artc-sdk-thread-model`, never merged to main).

## What broke the archive path

`isales-engine@fb62fdd` got the **driver thread model** working —
verified by:

- DNS resolution of `gw.rtn.aliyuncs.com` started succeeding
  (pre-fix: never resolved).
- `AliRTCEngine.cc:461` (token-validation path) was reached for the
  first time (pre-fix: code path never entered).
- `recvCoroutine` successfully delivered `OnError(0x01037D82)` back to
  Python via `call_soon_threadsafe` — proving the driver thread +
  pump + callback marshal chain is live end-to-end.

But the **next layer down** rejected the join: the vendor SDK
returned `"Invalid token!"` locally. § 5.3 / 5.4 / 5.5 acceptance
criteria therefore went unmet (no HTTP to `gw.rtn.aliyuncs.com`, no
`OnJoinChannelResult(code=0)`, no inbound PCM).

The original 2026-05-25 hypothesis was "token mint algorithm wrong";
a follow-on change `engine-artc-token-mint-investigation` was
recommended.

## What actually came next — the supersession

2026-05-26 ground-truth diagnosis (memory
`[[project_dingrtc_migration_groundtruth]]`) found the token / SDK
combination was **product-line mismatched**: the AppId `o6dpsan9` was
a DingRTC PaaS 3.x credential, but the SDK we were driving via
sidecar was the **legacy ApsaraVideo Live ARTC** SDK
(`AliRTCSDK_Linux-7.10.2`). Their tokens are NOT interoperable. The
sidecar pump model was a correct fix for the wrong SDK.

`engine-rtc-dingrtc-migration` (active, currently 51/91) swapped the
entire vendor layer to **DingRTC 3.9.0** with a project-internal
pybind11 binding (`isales-engine/deploy/cloud/pybind/dingrtc_pywrap/`).
That migration:

1. **Deleted** the files this change modified
   (`transport/aliyun_rtc.py` + `transport/_rtc_sdk.py`) in
   `isales-engine@2b21f7b`. § 6.4 of dingrtc-migration explicitly
   notes `transport/_rtc_driver.py` (the sidecar pump introduced by
   `fb62fdd`) only ever existed on this branch and is being retired
   alongside the archive.
2. **Replaced** the sidecar IPC model with in-process C++ calls
   through pybind11 — `__recvCoroutine` does not exist in the new
   binding because there is no Python-side coroutine pump to drive.
3. **Achieved** the underlying acceptance gate this change was
   gated by: § 5.4 of dingrtc-migration ECS PCM loopback PASS on
   channel `rtc-smoke-1779785584` —
   `OnJoinChannelResult(code=0, elapsed=128ms, streams_size=2)`,
   `GSLB statusCode:200`, 10 s clean run with 1001 inbound frames
   (1.92 MB), exit 0 (`isales-engine@243fbc1`). § 8.8 furthermore
   verified dual-peer mac+ECS互通 on channel `dual-peer-1779788945`
   with both peers receiving > 1900 inbound frames.

The DingRTC binding is what genuinely closes the "real Aliyun RTC
join e2e" gap that motivated this change.

## Mapping unmet acceptance criteria to their supersession evidence

| Unmet (this change) | Met by (dingrtc-migration) |
|---|---|
| § 5.3 sidecar log to `gw.rtn.aliyuncs.com` | n/a — no sidecar in new model; equivalent gate is `GSLB statusCode:200` in § 5.4 ECS smoke |
| § 5.4 `OnJoinChannelResult(code=0)` | § 5.4: `OnJoinChannelResult, result:0, channel:rtc-smoke-1779785584` in SDK file log |
| § 5.5 inbound PCM frames > 0 in 10 s | § 5.4: `inbound_frames=1001, inbound_bytes=1921920` over 10 s |
| § 5.6 `MUST NOT archive` until 5.3–5.5 pass | superseded — gate logic was "fix token + retry sidecar"; actual fix was "drop the SDK entirely" |

## What stays in the historical record

- `isales-engine@fb62fdd` (branch `engine-artc-sdk-thread-model`) —
  the driver-thread + pump + dispatch-queue implementation.
  Reference value: shows what the right asyncio-integration shape
  looks like for any future Python-coroutine-pumped vendor SDK.
- ECS sidecar log analysis 2026-05-25 — root-cause methodology
  (sidecar HTTP log → DNS → roomserver) is reusable even though
  this specific SDK is gone.
- `tasks.md` here — the 5 unchecked criteria (now marked `[x]
  SUPERSEDED`) preserve the precise blocker chain that drove the
  product-line investigation that drove the migration.

## Related memories

- `[[project_artc_join_diagnosis_2026_05_25]]` — the 2026-05-25
  diagnosis session that produced this change.
- `[[project_dingrtc_migration_groundtruth]]` — the 2026-05-26
  ground-truth that reframed "token wrong" as "SDK product line
  wrong".
- `[[project_dingrtc_migration_propose_done]]` /
  `[[project_dingrtc_cloud_binding_ecs_green]]` — the migration
  proposal and the eventual ECS-side green smoke that retired this
  change.
- `[[feedback-isolate-with-vendor-sample]]` — lesson that running
  the vendor's own sample first would have surfaced the
  product-line mismatch in hours instead of days.
