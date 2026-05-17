# windows-client-core acceptance log (2026-05-17)

**Status**: Code / scripts / tests shipped on Windows dev rig; hardware PoC
week (§1/§2) and joint MVP end-to-end (§9) deferred per the task descriptions
themselves (these sections explicitly carry `执行者：用户 / 运维 / QA` and
depend on A2 cloud-side ship plus physical PoC time).

This change re-targeted the iSales edge platform from a Mac mini PoC to
customer-owned Windows 10/11 PCs running a single PyInstaller-frozen tray
app. It added the Windows-specific `modem_controller/platforms/windows_serial.py`
USB watcher, the original `modem_controller/audio/windows_wasapi.py` audio
backend (later superseded by the SerialPcm-over-COM backend below), the
`AtClient` AT-channel probe + identity sequence, the cross-platform
`serial_lock.py` shim that unblocked Windows pytest collection, the tray /
activation UX (`isales_telephony/ui/`), the qasync edge entry point
(`main_windows.py`), the PyInstaller spec + PowerShell install / uninstall
scripts, the `[project.optional-dependencies].windows` extras, and the
Windows CI job. Mid-stream PoC measurements (2026-05-17, see below) overturned
the original `Decision 3` USB Audio Class assumption; a design.md amend
replaced WASAPI with a SerialPcm-over-COM backend driven by SIMCom-private
`AT+CPCMREG=1/0` lifecycle. The corresponding spec deltas
(`device-hardware` + `deployment-topology`) were updated in the same amend.

## PRs landed (isales-telephony)

| Tasks | Commit | Subject |
|---|---|---|
| §3.1 / §3.2 / §3.6 / §8.1 / §8.2 | `0300c96` | PR #6 (windows-client-core): WindowsSerialWatcher + vendor whitelist + windows extras |
| §3.3 / §3.4 / §3.5 | `e7987b7` | PR #8 (windows-client-core): at_probe — AT-channel identify + identity sequence |
| §4.1-§4.6 (superseded), §5.1-§5.6, §6.1-§6.5, §7.1-§7.6, §8.3, §10.1-§10.6 | `f39e75b` | PR #9 (windows-client-core): WASAPI audio + UI + main_windows + deploy |
| windows-artc-pybind11 (sibling change) | `0679822` | PR #10 (windows-artc-pybind11): pybind11 binding + WindowsRtcSession |
| §3.7-§3.9 | `308de8c` | PR #11 (windows-client-core): platforms/serial_lock — de-fcntl at_client |
| §3.10 | `8d212b8` | PR #12 (windows-client-core §3.10): widen windows-tests pytest scope |
| §4.7-§4.12 | `a55b158` | PR #13 (windows-client-core §4.7-§4.12): SerialPcm-over-COM audio backend |
| live hardware spike | `aeff11e` | windows-client-core §4.7-§4.12: live hardware spike script |

## design.md amend (2026-05-17): Decision 3 → SerialPcm-over-COM

Mid-implementation PoC against the dev rig's SIMCom SIM7600G-H revealed that
the modem **does not register any USB Audio Class endpoint on Windows 10/11**
(`Get-PnpDevice -Class AudioEndpoint` returns ∅ for the device). The original
`Decision 3` — "USB Audio Class path default, WASAPI via sounddevice" — was
literally unreachable on the v1.0 main SKU. The amend (commit `bebebae` on
the meta-repo) reversed `Decision 3`, added `Decision 8` (CPCMREG lifecycle =
orchestrator's job, backend stays pure byte-stream IO), and modified the
device-hardware spec Scenarios accordingly. §4.7-§4.12 replaced the original
§4.1-§4.6 WASAPI tasks; §7.1 / §7.5 / §8.1 ripple notes were folded into the
§4.11 cleanup. Original §4.1-§4.6 PR #9 deliverables (`windows_wasapi.py` +
`tests/windows/test_wasapi_audio.py`) were deleted in PR #13.

## Live hardware spike (2026-05-17, SIM7600G-H, COM11/COM12)

Non-destructive 8-assertion spike (`scripts/d1_poc/poc_serial_pcm_spike.py`,
commit `aeff11e`) validating the §4.7-§4.12 contracts against the dev rig:

| # | Assertion | Result |
|---|---|---|
| 1 | comports() enumerates the 5-COM SIMCom composite (VID:PID 1e0e:9001) | ✅ COM8/9/10/11/12 |
| 2 | `find_audio_serial_path(usb_serial, "1e0e", "9001")` returns COM11 | ✅ description-`Audio` match |
| 3 | `SerialATClient.create_from_tty(COM12)` init OK (ATE0 / CMEE / CLIP) | ✅ live ACK |
| 4 | `AT+CPCMREG=?` → `+CPCMREG: (0-1)` on firmware `LE20B04SIM7600G22` | ✅ protocol present |
| 5 | `AT+CPCMREG=1` outside a call → `ERROR` → `PcmEnableError(detail='ERROR')` | ✅ orchestrator failure-path contract holds |
| 6 | `AT+CPCMREG=0` outside a call → `OK` on this firmware (defensive log path never triggers) | ✅ tolerant |
| 7 | `WindowsSerialPcmCapture(COM11).open_port()` against live audio COM | ✅ pyserial open |
| 8 | `read_chunk()` under CPCMREG=0 returns 0 bytes within 1 s timeout (no raise) | ✅ pump-loop assumption holds |

These assertions exercise every control / data-plane contract the
`§4.7-§4.12` implementation relies on. The remaining hardware acceptance
(full dial → CONNECT URC → CPCMREG=1 → bridge join → talk → leave →
CPCMREG=0) is the joint A2 / D1 MVP and lives in `§9.3` below.

## Unit / integration tests (as-landed on this Windows dev box)

Run from `isales-telephony` against Python 3.14.4 on Windows 11 25H1:

```
pytest -v tests/windows tests/test_platforms_dispatch.py tests/modem_audio \
         tests/modem_serial tests/test_modem_dial.py tests/test_modem_pump_cancel.py \
         tests/test_fake_modem_e2e.py tests/edge
```

→ **185 passed + 6 skipped** (5 PG-fixture gated + 1 PIL-gated; the latter
six match the post-§3.10 baseline).

PR #13 alone added 15 new asserts across `tests/windows/test_serial_pcm_audio.py`
(8 tests), `tests/modem_serial/test_at_client_cpcmreg.py` (4 tests), and
`tests/edge/test_orchestrator.py` (3 tests covering cpcmreg ordering + the
`PCM_ENABLE_FAILED_STAGE` HardwareAlert path).

The post-§3.10 GitHub Actions `windows-tests` job runs the exact same
`pytest` invocation on `windows-latest`; CI runner has no SIM modem and no
PG service container, so the 6-skip subset (PG fixture / PIL) is the
expected baseline there as well.

## Spec deltas (synced into main specs at archive time)

Both deltas validated via `openspec validate windows-client-core --strict`
and reviewed in archive prep:

- `device-hardware`:
  - **ADDED** Requirement "Windows 平台 backend" (USB watcher策略 +
    multi-COM identification + SerialPcm-over-COM backend + 8 kHz / 20 ms
    frame format + AT+CPCMREG lifecycle + 50 ms P95 latency SLA + macOS /
    Linux preservation).
  - **ADDED** Requirement "Windows USB GSM modem 设备识别" (VID:PID
    whitelist primary, AT probe fallback with 1/min/COM rate limit, init
    sequence CGMI/CGMM/CGSN/CCID with HardwareAlert on failure).
  - **MODIFIED** Requirement "URC → ATEvent 翻译契约" — Scenario
    "串口竞争互斥" rewritten to cover both POSIX `fcntl.flock` and Windows
    OS-level exclusive-open semantics, with the `platforms/serial_lock.py`
    shim as single source of truth (per `Decision 7`). All other Scenarios
    in the Requirement are restated verbatim (OpenSpec delta does not
    support Scenario-only MODIFIED).
- `deployment-topology`:
  - **ADDED** Requirement "Windows 边缘形态" — Windows-as-commercial /
    macOS-as-PoC platform split, install layout (`%LOCALAPPDATA%\Programs\
    isales\` + `%APPDATA%\isales\`), HKCU Run-key startup, single-process
    qasync architecture, two-state tray UX, activation UX (static token =
    A2 contract), macOS retention.
  - **ADDED** Requirement "Windows 客户端依赖与打包" — pyproject extras
    list, PyInstaller `onedir` mode + ARTC SDK binaries + tray icon,
    `install.ps1` / `uninstall.ps1` semantics, outbound network reachable
    set.

The PCM-enable HardwareAlert wire shape ships as a reuse of the existing
`ModemInitFailed` oneof (`stage = "CPCMREG_ENABLE"` constant exported
from `isales_telephony/edge/orchestrator.py::PCM_ENABLE_FAILED_STAGE`)
to keep D1 a pure edge change (no `isales-common` proto bump). The
deviation is documented inline in tasks.md §4.10 and forwarded to any
future D2 `hardware-observability` change if a dedicated oneof is later
desired.

## A1 reverse cross-link

Per `archive/2026-05-17-impl-real-at/acceptance.md` § "Out-of-scope
deferred items" (line 99) and § "Post-A2/D1 scope retraction" (line 67),
A1 task §3.4 (5-call real-hardware acceptance for `SerialATClient`) was
explicitly forward-deferred to this change's §9. The deferral resolved
via:

- A1 §3.4's blocking dependency — `SerialATClient` Windows importability —
  was lifted in **PR #11** (commit `308de8c`), which extracted `fcntl` to
  the new `modem_controller/platforms/serial_lock.py` POSIX/Windows shim
  and re-pointed `at_client.py` at it.
- A1 §3.4's CI corollary — widening the Windows pytest job to cover
  `tests/modem_serial/` + `tests/test_modem_*.py` + `tests/edge/test_
  orchestrator.py` — landed in **PR #12** (commit `8d212b8`).
- A1 §3.4's hardware-log corollary — 3-call hangup_cause samples
  (`manual_hangup` / `no_answer` / `user_busy`) using `SerialATClient`
  directly via `scripts/at_smoke.py` — is folded into D1 §9.3 below and
  remains deferred along with the rest of D1 §9.

## Out-of-scope deferred items

The following Sections of `tasks.md` are unticked at archive time; each
explicitly carries an `执行者：用户 / 运维 / QA` annotation in the source
and depends on physical hardware time + A2 cloud-side ship that the
code-side D1 archive cannot satisfy alone:

- **§1.1-§1.4 Sprint 0 preparation** — physical Windows PC + USB GSM modem
  procurement; VS Build Tools / Wireshark install; Aliyun ARTC SDK download.
  The current dev rig already satisfies §1.1 (SIM7600G-H + Windows 11 PC,
  see `[[project-d1-hardware-rig]]` memory); §1.2-§1.4 are per-customer-
  deployment user actions, not iterative code work.
- **§2.1-§2.5 PoC week one (live performance baselines)** — `§2.1` WASAPI
  loopback latency is **废止 (废)** by the `Decision 3` amend; the
  superseding latency measurement (CPCMREG=1 → pyserial.read(320) × N
  end-to-end echo P95) is recorded in design.md's Risks section as the
  replacement task. `§2.2`-`§2.4` (pyserial polling cost, qasync /
  pystray / PySide6 co-existence, PyInstaller + ARTC DLL load) require
  the Windows PoC rig + signed-build environment that A2 joint MVP
  provides. `§2.5` is the design.md-amend escalation trigger and is
  already exercised once (this very change's `Decision 3` reversal).
- **§9.1-§9.6 端到端验证** — joint A2 / D1 MVP. Predicate: A2 cloud-side
  ship + ARTC SDK pybind production-grade + valid `EDGE_DEVICE_TOKEN`
  signed by the cloud `isales-api`. A1 §3.4's 3 hangup_cause samples
  fold into §9.3's happy-path-plus-symptom matrix. §9.6 (Windows Defender
  / SmartScreen) work-around recipe is partially captured in
  `deploy/edge/windows/README.md::Q1` and gets the full empirical recipe
  appended after a clean-PC install run.

These three sections are tracked as joint A2 / D1 MVP acceptance work and
will reopen as a follow-up change (or as inline acceptance-log addenda
to *this* archive) once the joint MVP is exercised. Convention precedent:
`archive/2026-05-12-impl-deploy-macos/12.4/12.5` were deferred via a new
proposed change (`impl-real-at`) rather than re-opening an archive; the
same convention applies here if any *design* issue surfaces during the
joint MVP.

## Forward-looking notes

- The deferred `at_probe + RateLimitedProber → USB watcher` reaction path
  (tasks.md §3 footer line 28) was kept out of this change scope by
  design — `windows_serial.WindowsSerialWatcher.events()` still emits raw
  `UdevEvent(add | remove, device_node, vid, pid)` without auto-running
  `identify_modem_channel` or caching results. The wiring is shovel-ready:
  every public API the wiring needs (`at_probe.identify_modem_channel`,
  `at_probe.AudioSerialPathFinder`, `windows_serial.find_audio_serial_path`)
  is in place; only the loop-glue in modem-controller's main needs to
  land. That follow-up belongs either with D2 `hardware-observability` or
  as a one-shot `windows-usb-watcher-integration` change.
- `Decision 8`'s `cpcmreg_enable` / `cpcmreg_disable` are vendor-neutral
  on `AtClient`; future non-SIMCom SKUs whose PCM protocol differs (e.g.
  Quectel EC25-EU runs the byte stream over USB Audio Class endpoints
  rather than a private COM, and Quectel EG25-G uses `AT+QPCM=1`) can
  override `cpcmreg_enable / cpcmreg_disable` on a `ModemDriver` subclass
  without touching the orchestrator. tasks.md §9 will record which SKUs
  end up accepted into v1.0 once the joint MVP runs.
- `Open Question #2` from design.md (WASAPI Exclusive Mode togglability)
  is now formally retired by the `Decision 3` amend.
- `Open Question #4` (multi-user Windows PCs) survives unchanged into
  C2's `multi-tenant-roles-and-leads` seat model.
