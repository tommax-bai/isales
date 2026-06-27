## Why

Stale **ApsaraVideo-Live ARTC** terminology survived in 3 live specs after the
DingRTC 3.x migration (`engine-rtc-dingrtc-migration`) archived. That change
MODIFIED the engine/edge RTC-binding requirements but never touched these
particular requirements, which still describe the **current** architecture
using the retired SDK name (e.g. "audio-bridge：阿里 ARTC SDK 客户端",
`MacosArtcPyObjCSession`, `aliyun_artc_pywrap`, "ARTC AppId/AppKey"). This
misleads readers into thinking the live edge/cloud path still runs the
ApsaraVideo-Live ARTC SDK. Terminology-only purge — **no behavior / code /
schema / deploy change**. Legitimate ARTC mentions are preserved: migration
narrative ("取代既有 … ARTC …"), the `macos-artc` extras name +
`ISALES_MACOS_ARTC_FRAMEWORK_PATH` deprecated alias, MUST-NOT guards, the
"既有 ApsaraVideo Live ARTC SDK 路径清理" cleanup scenario, change-name
citations, and the `[[reference_artc_sdk]]` memory link.

## What Changes

- `device-hardware` (3 requirements): "自研控制层与单主机部署" audio-bridge
  bullet, "macOS dev-no-modem orchestrator 路径" (`MacosArtcPyObjCSession` +
  the `windows-artc-pybind11` fail-fast message), and "audio-bridge 组件"
  (3 SDK-name spots) → DingRTC equivalents.
- `deployment-topology` (2 requirements): "Windows 客户端依赖与打包" (vendor +
  `aliyun_artc_pywrap` + change-link + binaries bullet) and "macOS dev/QA 形态…"
  (vendor zip path, PyObjC framework + session class, audio I/O, isolation
  bullet) → DingRTC equivalents.
- `provider-credential` (1 requirement): "凭据 DB 是单一事实来源" non-credential
  config list `ARTC AppId/AppKey` → `DingRTC AppId/AppKey`.

Pure terminology reconciliation. Each MODIFIED block copies the live
requirement verbatim and changes ONLY the listed strings.

## Impact

- Specs: `device-hardware`, `deployment-topology`, `provider-credential`
  (MODIFIED, terminology only).
- Out of scope (legitimate ARTC, left untouched): the DingRTC vendor-SDK
  requirement's `取代 …` narrative + cleanup scenario + alias in
  `deployment-topology`; the engine/macOS/Windows DingRTC-binding requirements'
  `取代 …` narrative + `macos-artc` extras + `ISALES_MACOS_ARTC_FRAMEWORK_PATH`
  alias + `[[reference_artc_sdk]]` in `device-hardware`; `service-communication`
  entirely (DingRTC media-plane narrative + guards + change-name citation).
- No code, no migration, no deploy.
