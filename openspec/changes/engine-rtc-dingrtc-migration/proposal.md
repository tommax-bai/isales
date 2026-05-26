## Why

iSales 三端（cloud Linux engine / Windows edge / macOS edge）当前接入的 RTC SDK 全部是**错产品线**——ApsaraVideo Live 下的 ARTC SDK（域名 `alivc-demo-cms.alicdn.com`，cloud 用的 `AliRTCSDK_Linux-7.10.2`、Windows 用的 `AliVCSDK_ARTC-7.6.0`、Mac 用的 `AliRTCSdk_7.8.10000-SNAPSHOT`）；而 ECS 上配置的 AppId `o6dpsan9...` 是 **DingRTC 3.x**（RTC PaaS 新一代，域名 `dingrtc.oss-cn-zhangjiakou.aliyuncs.com`，文档 [2640158](https://help.aliyun.com/document_detail/2640158.html)）。这是**跨产品线**——Live 下的 ARTC SDK 与 RTC PaaS DingRTC 房间**互不互通**，roomserver 必然 token 验证失败。这就是 2026-05-25 PoC 三个错码（`ERR_JOIN_BAD_TOKEN 0x02010205` / 本地 `0x01030302` / `JoinChannelFromServer` 同样被拒）的根本原因。

`rtc_token.py` v3.0 binary 算法（privilege+options+HMAC-SHA256 派生 key+zlib+base64）已经通过 vendor sample 仓库（`gitee.com/dingrtc/AliRTCSample`）byte-perfect 实证 = DingRTC 3.x 算法本身，不用重写；问题 100% 落在 SDK 选错产品线。DingRTC 3.9.0 三端 SDK 已对齐（同 minor → 互通保证）、demo appid `a4zfr1hn` 可隔离 PoC，是 A2 路径 e2e 通话验收的核心 enabler。

## What Changes

- **Cloud Linux engine 切 DingRTC 3.x（核心动作）**
  - 删除 `isales-engine/isales_engine/transport/aliyun_rtc.py`、`isales-engine/isales_engine/transport/_rtc_sdk.py`、`isales-engine/isales_engine/transport/_rtc_driver.py`（含 commit fb62fdd 1410 行 sidecar pump）—— 跨产品线包错 SDK + Python↔TCP sidecar IPC 模型整体淘汰
  - 新增 `isales-engine/isales_engine/transport/dingrtc/` 目录，承载 DingRTC Linux C++ SDK 3.9.0 的项目内 pybind11 binding（`dingrtc_pywrap.so`）+ Python wrapper `DingRtcSession`
  - vendor 落点 `/opt/isales/vendor/DingRTC_Linux_SDK_3_9_0/`（解压自 `https://dingrtc.oss-cn-zhangjiakou.aliyuncs.com/sdk/linux/3.9.0/DingRTC_Linux_SDK_3_9_0.zip`，2025-04-15 release）
  - DingRTC Linux C++ SDK 是 **in-process** 调用（`RtcEngine::Create` / `JoinChannel(RtcEngineAuthInfo, userName)` / `SetExternalAudioSource` + `PushExternalAudioFrame` / `RtcEngineAudioFrameObserver::OnPlaybackAudioFrame`）——彻底告别 sidecar、告别 `__recvCoroutine` 多线程 drive、告别 `engine-artc-sdk-thread-model` change 修的所有问题
- **Windows edge 切 DingRTC 3.x（vendor 调用层换，binding 框架 ~80% 保留）**
  - vendor 落点改 `~/codes/vendor/DingRTC_Windows_SDK_3_9_0/`（`DingRTC.dll`）；下载页 `https://dingrtc.oss-cn-zhangjiakou.aliyuncs.com/sdk/windows/3.9.0/`
  - `windows-artc-pybind11` active change（当前 39/51）的 binding 框架（CMake / audio_observer / ring_buffer / engine_listener 通用层）SHALL **保留**；vendor 调用层（类名、API 签名、callback selector）换 DingRTC 3.x API
  - PyInstaller spec 中 `aliyun_artc_pywrap.pyd` / `AliVCSDK_ARTC` dll 引用 SHALL 换为 `dingrtc_pywrap.pyd` / `DingRTC.dll`
- **macOS edge 切 DingRTC 3.x（vendor 调用层换，PyObjC binding 框架保留）**
  - vendor 落点改 `~/codes/vendor/DingRTC_macOS_SDK_3_9_0/DingRTC.framework`；下载页 `https://dingrtc.oss-cn-zhangjiakou.aliyuncs.com/sdk/mac/3.9.0/`
  - `macos-artc-pyobjc-binding`（已 archive）实装的 `MacosArtcPyObjCSession` selector 名 SHALL 重命名到 DingRTC.framework selector（`onJoinChannelResult:` 等映射到 DingRTC 等价 selector）；`objc.loadBundle("DingRTC", ...)` 替换 `loadBundle("AliRTCSdk", ...)`
  - env var `ISALES_MACOS_ARTC_FRAMEWORK_PATH` SHALL 重命名为 `ISALES_MACOS_DINGRTC_FRAMEWORK_PATH`
- **`rtc_token.py` 保留** — 算法已实证 = DingRTC 3.x v3.0 binary；换 SDK 后产出直接喂 `RtcEngineAuthInfo.token`
- **`RtcSession` ABC 保留** — `isales-common/isales_common/audio/rtc.py` 的 4 个 abstract API（`join` / `leave` / `is_joined` / `audio_frames()` / `push_audio`）形状不变；只换内部 driver
- **`RtcCredentials` dataclass 保留**（SDK 无关）；`WindowsRtcSession` / `MacosArtcPyObjCSession` 平台路由保留（接口形状不变）
- **联动 active changes 处置**
  - `engine-artc-sdk-thread-model`（26/31）SHALL archive，archive 说明标 "修了错产品线 SDK 的 bug，被 DingRTC 切换淘汰；DingRTC C++ 是 in-process 调用，sidecar pump 模型整体不再需要"
  - `windows-artc-pybind11`（39/51）vendor 调用层 SHALL 由本 change 重做；binding 框架（CMake / audio_observer / ring_buffer / engine_listener 通用层）保留
  - `arch-cloud-edge-split`（52/64）cloud-side ARTC SDK 集成 spec delta（device-hardware L195 / deployment-topology L30 / service-communication L169）SHALL 由本 change 提供修订 delta
  - `windows-artc-pybind11-join-config`（0/23）SHALL 在本 change 落地后重启（vendor 调用形状会变）
  - `joint-mvp-gate-13301035545`（11/43）SHALL 等本 change cloud + Windows edge 双绿后续推
- **PoC 顺序（隔离三义性，必须按序）**
  1. 装 DingRTC 3.x Linux C++ SDK + pybind11 binding（cloud Linux engine）
  2. 先用 demo appid `a4zfr1hn` + 对应 demo AppKey（demo sample 包内）跑 join → 验 "SDK 装对了 + binding 通 + `rtc_token.py` 算法对"
  3. 再切真 AppId `o6dpsan9...` + 真 AppKey 复跑 → 验 "凭据对"
- **STATE.md / 文档同步**（必随同一 PR）
  - `deploy/cloud/STATE.md` § "ARTC SDK vendor" → "DingRTC SDK vendor"，CDN URL / 解压路径 / 版本号全换
  - `isales-telephony/deploy/edge/windows/STATE.md` SDK 路径 + DLL 名同步
  - `isales-telephony/deploy/edge/macos/RUNBOOK.md` framework 路径 + 解压指令同步
  - `deploy/RUNBOOK-cloud.md` cloud-side SDK 装载步骤同步

**BREAKING**：cloud Linux engine 的 `_AliyunArtcChannel` wrapper 整体删除；任何 import `isales_engine.transport.aliyun_rtc` / `isales_engine.transport._rtc_sdk` 的代码 SHALL 改 import `isales_engine.transport.dingrtc`。`isales-telephony` 的 `audio_bridge` PyObjC / pybind11 binding 模块对外契约（`RtcSession` ABC）不变，但底层 vendor symbol / env var / framework path 全换。

## Capabilities

### New Capabilities
（无 —— 本 change 不引入新 capability；纯换 vendor SDK + binding 改造）

### Modified Capabilities

- `device-hardware`: 既有 Requirement "云端 isales-engine SHALL 在 `transport/aliyun_rtc.py` 中包装阿里 ARTC SDK for Linux Python"（来自 `arch-cloud-edge-split` delta L195）SHALL 改为 "云端 isales-engine SHALL 在 `transport/dingrtc/` 中通过项目内 pybind11 binding 包装 DingRTC Linux C++ SDK 3.x"；既有 macOS PyObjC binding Requirement（spec L423）SHALL 把 `AliRTCSdk.framework` 改为 `DingRTC.framework`、`ISALES_MACOS_ARTC_FRAMEWORK_PATH` 改为 `ISALES_MACOS_DINGRTC_FRAMEWORK_PATH`；既有 Windows backend Requirement SHALL 标注 vendor SDK = `DingRTC_Windows_SDK_3_9_0`
- `deployment-topology`: 既有 Windows PyInstaller / cloud Linux image vendor 路径 / SDK 名 SHALL 全换（`aliyun-artc-windows` → `dingrtc-windows`、`aliyun_artc_pywrap.pyd` → `dingrtc_pywrap.pyd`、`AliRTCSdk_macos` → `DingRTC_macOS` 等）；macOS dev/QA 形态启动步骤 SHALL 改 vendor 解压路径 + 一行启动命令
- `service-communication`: 既有 "通过阿里 RTC PaaS（ARTC SDK for Linux Python / ARTC SDK for macOS Python）" SHALL 改为 "通过阿里 RTC PaaS DingRTC 3.x SDK（Linux C++ in-process / Windows DLL / macOS framework，三端同 minor 互通）"

## Impact

- **代码**
  - `isales-engine/isales_engine/transport/aliyun_rtc.py` / `_rtc_sdk.py` / `_rtc_driver.py` — **删**
  - `isales-engine/isales_engine/transport/dingrtc/` — **新增**（pybind11 binding 源码 + CMakeLists + Python wrapper `DingRtcSession`）
  - `isales-engine/isales_engine/transport/rtc_token.py` — **保留**（算法已是 DingRTC 3.x v3.0 binary）
  - `isales-engine/tests/transport/` — vendor mock 单元测试同步迁移 + 新增
  - `isales-telephony/isales_telephony/audio_bridge/windows_rtc_session.py` — vendor 调用层切 DingRTC 3.x；ABC 契约不变
  - `isales-telephony/isales_telephony/audio_bridge/macos_artc_pyobjc.py` — selector + `loadBundle` 名切 `DingRTC.framework`；env var 改 `ISALES_MACOS_DINGRTC_FRAMEWORK_PATH`
  - `isales-common/isales_common/audio/rtc.py` — **不动**（`RtcSession` ABC + `RtcCredentials` dataclass + `RtcError` 家族 SDK 无关）
- **配置 / 依赖**
  - cloud Linux：`/opt/isales/vendor/DingRTC_Linux_SDK_3_9_0/`（替换 `AliRTCSDK_Linux-7.10.2/`）
  - Windows：`~/codes/vendor/DingRTC_Windows_SDK_3_9_0/`（替换 `AliVCSDK_ARTC-7.6.0/`）
  - macOS：`~/codes/vendor/DingRTC_macOS_SDK_3_9_0/DingRTC.framework`（替换 `AliRTCSdk_macos/AliRTCSdk.framework`）
  - vendor 全部走 `dingrtc.oss-cn-zhangjiakou.aliyuncs.com`，不进 git；解压指令进 STATE.md / RUNBOOK
  - pybind11 / CMake 版本约束不变（Linux 复用现有 toolchain；Windows 复用 `windows-artc-pybind11` 既有 build pipeline）
- **联动 active changes**
  - `engine-artc-sdk-thread-model`（26/31 active）→ archive 标 "DingRTC C++ in-process 调用，sidecar pump 整体不再需要"
  - `arch-cloud-edge-split`（52/64 active）→ 本 change 提供 device-hardware / deployment-topology / service-communication 三个 spec delta 的修订
  - `windows-artc-pybind11`（39/51 active）→ vendor 调用层重做；binding 框架（CMake / audio_observer / ring_buffer / engine_listener）保留
  - `windows-artc-pybind11-join-config`（0/23 active）→ 本 change 落地后重启
  - `macos-local-audio-dev`（0/37 active）→ 待评估 vendor 调用形状影响
  - `joint-mvp-gate-13301035545`（11/43 active）→ 等本 change cloud + Windows edge 双绿后续推
- **运行时**
  - 每路 RTC session 不再起 sidecar TCP 子进程 + 专用 SDK 驱动线程；DingRTC C++ in-process，资源占用降一档
  - 每路 session CPU / RAM 由 DingRTC SDK 内部线程模型决定（典型 1 RtcEngine + 内部 worker 线程数）
  - 三端同 minor 3.9.0 互通；如未来升 minor（3.10+）必须三端同步升
- **其他 sub-repo**：`isales-api` / `isales-scheduler` / `isales-worker` / `isales-web` 零影响
- **风险 / 已知未决**
  - DingRTC Linux C++ SDK 缺 `JoinChannelFromServer` 与 `subscribeAudioFormat=PcmBeforMixing` per-uid 订阅模式 → 仅混流；2-user channel 下混流就是对方那一路，**不**构成 blocker（2026-05-26 评估）；如未来需要 per-uid PCM（>2 用户），需另起 change 评估替代方案
  - vendor SDK 内部线程模型与 asyncio loop 集成路径需 PoC 阶段实测（in-process callback 进 asyncio 仍需 thread-safe marshal）
  - 回退路径：保留当前 commit ccb10dd 作为 base；PoC 不通则 revert + 重起 vendor-only sample 对照
  - DingRTC sample 仓 `gitee.com/dingrtc/AliRTCSample` 为 vendor 算法 ground truth；任何 token / API 行为分歧 SHALL 以该仓为准
- **文档 / STATE 必动**
  - `deploy/cloud/STATE.md` § "ARTC SDK vendor" → "DingRTC SDK vendor"，含 CDN URL / 解压指令 / 版本号
  - `isales-telephony/deploy/edge/windows/STATE.md` SDK 路径 + DLL 名
  - `isales-telephony/deploy/edge/macos/RUNBOOK.md` framework 路径
  - `deploy/RUNBOOK-cloud.md` cloud-side SDK 装载步骤
