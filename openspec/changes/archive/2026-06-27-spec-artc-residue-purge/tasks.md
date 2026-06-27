# Tasks — spec-artc-residue-purge

> Pure live-spec terminology purge: stale ApsaraVideo-Live ARTC names that
> describe the CURRENT architecture, left behind because
> `engine-rtc-dingrtc-migration` never MODIFIED these requirements. Each
> MODIFIED block is the live requirement copied verbatim with ONLY the listed
> substitutions; narrative / deprecated-alias / guards / citations preserved.

## 1. device-hardware

- [x] 1.1 "自研控制层与单主机部署" — audio-bridge bullet `阿里 ARTC SDK 客户端` → `阿里 DingRTC 3.x SDK 客户端`.
- [x] 1.2 "macOS dev-no-modem orchestrator 路径" — `MacosArtcPyObjCSession` → `MacosDingRtcPyObjCSession`; fail-fast 文案 `windows-artc-pybind11 真 Aliyun RTC 路径` → `真 DingRTC 路径`.
- [x] 1.3 "audio-bridge 组件" — `阿里 ARTC SDK 客户端`/`调用 ARTC SDK`/`**WHEN** ARTC SDK 触发` → DingRTC.

## 2. deployment-topology

- [x] 2.1 "Windows 客户端依赖与打包" — `阿里 ARTC SDK for Windows native binary` → DingRTC 3.x; `aliyun_artc_pywrap` → `dingrtc_pywrap` (×2); `windows-artc-pybind11/` change-link → archived `engine-rtc-dingrtc-migration/` (×2); `显式包含 ARTC SDK Windows native` → DingRTC.
- [x] 2.2 "macOS dev/QA 形态…" — `windows-artc-pybind11` citation → `engine-rtc-dingrtc-migration`; vendor zip/path → `DingRTC_macOS_SDK_3_9_0`; `AliRTCSdk.framework`/`MacosArtcPyObjCSession` → DingRTC; `ARTC SDK 接 mac default device` → DingRTC; isolation bullet `macos_artc_pyobjc.py` + `AliRTCSdk.framework` → DingRTC.

## 3. provider-credential

- [x] 3.1 "凭据 DB 是单一事实来源" — non-credential config list `ARTC AppId/AppKey 等` → `DingRTC AppId/AppKey 等`.

## 4. Preserved (NOT touched — verify via grep)

- [x] 4.1 deployment-topology DingRTC vendor-SDK requirement: `install-dingrtc-sdk 取代 install-artc-sdk`, `DingRTC.dll 取代 AliVCSDK_ARTC.dll`, `dingrtc_pywrap.pyd 取代 aliyun_artc_pywrap.pyd`, "既有 ApsaraVideo Live ARTC SDK 路径清理" scenario, `alivc-demo-cms`/`help-static-aliyun-doc` guards, `extras 名 macos-artc 保持向后兼容`.
- [x] 4.2 device-hardware DingRTC-binding requirements: `取代既有 … ARTC …` narrative, `[macos-artc]` extras, `ISALES_MACOS_ARTC_FRAMEWORK_PATH` deprecated alias, `[[reference_artc_sdk]]`.
- [x] 4.3 service-communication: entirely untouched (DingRTC media-plane narrative + guards + change-name citation).

## 5. Validate & archive

- [ ] 5.1 `openspec validate spec-artc-residue-purge --strict`.
- [ ] 5.2 `openspec archive spec-artc-residue-purge -y`.
- [ ] 5.3 `git diff openspec/specs/` shows ONLY substituted lines; post-purge ARTC grep = only legit keeps.
