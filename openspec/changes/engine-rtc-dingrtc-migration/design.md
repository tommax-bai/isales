## Context

iSales v1.0 媒体面架构（archive `arch-cloud-edge-split`）规定 cloud engine 与 edge audio-bridge 通过阿里 RTC PaaS 作为参会者入同一房间走 PCM 双向流。三端 SDK 既往实装：

| 接入点 | 当前 SDK（错产品线） | 来源域名 |
|---|---|---|
| Cloud Linux engine | `AliRTCSDK_Linux-7.10.2`（Python wrapper + TCP sidecar IPC） | `alivc-demo-cms.alicdn.com/versionProduct/sdk/linux/` |
| Windows edge | `AliVCSDK_ARTC-7.6.0` | `alivc-demo-cms.alicdn.com/versionProduct/sdk/windows/` |
| Mac edge | `AliRTCSdk_7.8.10000-SNAPSHOT` | `alivc-demo-cms.alicdn.com/versionProduct/sdk/macos/` |

三端 SDK 全部来自 **ApsaraVideo Live（视频直播）** 产品线下的 ARTC SDK；而 ECS 配置的 AppId `o6dpsan9...` 是 **DingRTC 3.x**（RTC PaaS 新一代）AppId（[[project_rtc_appid_confirmed_3x]] 多次实证）。Live 下的 ARTC SDK 与 RTC PaaS DingRTC 房间属于**不同产品线**，roomserver 必然拒 token → 2026-05-25 PoC 三个错码全部解释通：

| PoC 尝试 | 错码 | 解释 |
|---|---|---|
| #1 `AliRTCSDK_Linux-7.10.2` join 真房间 | `ERR_JOIN_BAD_TOKEN 0x02010205` | Live SDK 算的 token Live roomserver 都不认（跨产品） |
| #2 同 SDK 本地 token v3.0 binary 自算 | 本地 `0x01030302` | Live SDK 拒认 DingRTC 3.x v3.0 binary 格式 |
| #3 `JoinChannelFromServer` 用 cloud token | 同 #1 | 不是 wire format 问题，是产品线问题 |

`rtc_token.py` v3.0 binary 算法已通过 vendor sample 仓 `gitee.com/dingrtc/AliRTCSample` byte-perfect 实证 = DingRTC 3.x 算法本身（同一仓 `Server/python3/` 路径），算法不用重写。

DingRTC 3.x 三端 SDK 在 `dingrtc.oss-cn-zhangjiakou.aliyuncs.com` 齐全（Linux C++ 3.9.0 / Windows DLL 3.9.0 / macOS framework 3.9.0，2025-04-15 同 minor → 互通保证），demo appid `a4zfr1hn` 可隔离 PoC。Cloud Linux 是 C++ in-process API（无 sidecar、无 Python ↔ TCP IPC、无 `__recvCoroutine` drive 问题），整套 `engine-artc-sdk-thread-model` change 修的问题被本变更整体淘汰。

约束：
- iSales 10-phase 一体发布（[[feedback_release_atomicity]]），本变更必须三端齐换；不允许只换 cloud
- v1.0 商用形态是 Windows edge + 真 GSM modem + 真 Aliyun RTC；macOS 是 dev/QA 形态
- A2 路径剩余 12 task 中"真 Aliyun RTC e2e"等本变更解锁
- `RtcSession` ABC 不动；上层 engine session loop / audio_pipe 零感知

## Goals / Non-Goals

**Goals:**
- 三端（cloud Linux / Windows edge / macOS edge）统一切 DingRTC 3.9.0 vendor SDK
- Cloud engine 去 sidecar IPC，改 in-process C++ SDK + 项目内 pybind11 binding
- Windows / macOS edge vendor 调用层换 DingRTC API；binding 框架（CMake / audio_observer / ring_buffer / engine_listener / PyObjC NSObject 子类）保留
- demo appid `a4zfr1hn` 隔离 PoC → 真 AppId `o6dpsan9...` 复跑的 PoC 顺序固化为 spec 验收
- 三端 e2e 验收：cloud engine ↔ Windows edge / cloud engine ↔ macOS edge 真房间互通 + 拨真手机 13301035545 听到 AI 开场白
- `rtc_token.py` / `RtcSession` ABC / `RtcCredentials` / 平台路由完整保留
- `engine-artc-sdk-thread-model` 整体淘汰（archive 时标说明）

**Non-Goals:**
- 不引入 per-uid PCM 订阅（DingRTC Linux C++ SDK 仅混流；2-user channel 下混流 = 对方那一路，2026-05-26 评估不构成 v1.0 blocker）
- 不改 `RtcSession` ABC 外部契约
- 不改 token 算法（已实证就是 DingRTC v3.0 binary）
- 不改 cloud-edge gRPC 控制面（媒体面切换与控制面正交）
- 不引入 IMS AICallKit / 其他托管智能体 SaaS
- 不动 `RtcCredentials` Fernet 加密 / `provider-credential` spec
- 不验证 DingRTC 3.10+ minor（如未来必须升 minor，需三端同步升 + 另起 change）
- v1.0 不上 DingRTC Web SDK（admin web 不需要直接 join 房间）

## Decisions

### D1: 三端 SDK 统一选 DingRTC 3.9.0（不是 3.7 / 3.8 / 3.10）

**Why this version**：vendor 下载页 2025-04-15 release，三端同 minor 同 patch，明确"同 minor → 互通保证"。三端必须同时升降版本；锁 3.9.0 是最近一次三端齐全 release。

**Alternatives**：
- 升 3.10+：vendor 未来可能 release；现在不锁 3.9.0 会让 PoC 期间被 vendor 升级窗口干扰
- 三端不同版本：vendor 文档明确互通不保证；不可行

**Rationale**：三端版本一致是 vendor 互通契约的硬约束；锁定具体 patch 是 PoC 复现性的硬要求。

### D2: Cloud Linux 用项目内 pybind11 binding，不用 sidecar / 不用 ctypes / 不用 cffi

**Why pybind11**：
- DingRTC Linux SDK 是 C++（不是 C），需要 C++ class 绑定能力
- `windows-artc-pybind11` (39/51 active) 已经验证了 pybind11 在 iSales 项目内的 build pipeline（CMake / audio_observer / ring_buffer / engine_listener 通用层）；Linux 复用同套 binding 设计
- in-process 调用避免了 sidecar 模型的所有 drive / IPC 问题（`engine-artc-sdk-thread-model` 整套问题）
- 三端 binding 同设计 → 维护成本低

**Alternatives**：
- ctypes：DingRTC C++ class 不能直接 ctypes 绑定，需要先暴露 C ABI 包装层，工作量更大
- cffi：同 ctypes 问题
- vendor 自带 Python wrapper：DingRTC Linux SDK 文档未发现 Python wrapper（[2863577 Linux(C++) 基本功能](https://help.aliyun.com/zh/document_detail/2863577.html) 仅 C++）；如未来 vendor 出 Python wrapper 可重新评估
- sidecar IPC：刚被 2026-05-25 诊断证明是 join 不通的根因之一；in-process 是更稳的形态

### D3: 复用 `windows-artc-pybind11` 既有 binding 框架（不重起 binding）

**保留**（vendor SDK 无关的通用层，~80%）：
- `CMakeLists.txt` build pipeline（pybind11 / C++ class binding 通用骨架）
- `audio_observer.cpp/h` — `OnPlaybackAudioFrame` callback 桥接
- `ring_buffer.cpp/h` — capture / playback PCM 环形 buffer
- `engine_listener.cpp/h` — engine 事件 callback 桥接
- Python wrapper `WindowsRtcSession` 形状 + `RtcSession` ABC 实施

**换**（vendor 调用层）：
- 包含的头文件：`AliRTCEngine.h` → `RtcEngine.h`
- 类名：`AliRTCEngine` → `RtcEngine`（DingRTC 3.x [2863577 文档](https://help.aliyun.com/zh/document_detail/2863577.html)）
- API 签名：`AliRtcAuthInfo` → `RtcEngineAuthInfo`（含 channelId / userId / appId / token / gslbServer 5 字段）
- callback 类：`AliRTCEngineEventListener` → `RtcEngineEventListener`、`AliRTCEngineAudioFrameObserver` → `RtcEngineAudioFrameObserver`
- 入会调用：`AliRTCEngine::JoinChannel(token, channelId, userId, userName)` → `RtcEngine::JoinChannel(authInfo, userName)`
- 外部音频源：`SetExternalAudioCapture(true) + PushExternalAudioFrame(AliRtcAudioFrame)` → `SetExternalAudioSource(true, sampleRate, channels) + PushExternalAudioFrame(RtcEngineAudioFrame)`
- 订阅：`SubscribeAllRemoteAudioStreams(true)` 保留；不再有 per-uid `SubscribeAudioFormat=PcmBeforMixing`
- 销毁：`AliRTCEngine::Destroy(engine)` → `RtcEngine::Destroy(engine)`
- DLL 名：`AliRTCSdk.dll` / `AliVCSDK_ARTC.dll` → `DingRTC.dll`
- Python 模块名：`aliyun_artc_pywrap` → `dingrtc_pywrap`

`windows-artc-pybind11-join-config`（0/23）等本变更落地后重启（配置字段从 `AliRtcAuthInfo` 形状 → `RtcEngineAuthInfo` 形状）。

### D4: macOS 复用 `macos-artc-pyobjc-binding` 既有 PyObjC NSObject 框架

**保留**：
- `MacosArtcPyObjCSession` 类整体（实施 `RtcSession` ABC 的 4 个 abstract API）
- PyObjC NSObject 子类 `_AliRtcAudioDelegate` → 改名 `_DingRtcAudioDelegate`
- 平台默认路由（`darwin` → PyObjC binding；fallback → `MacosRtcSession` mock loopback）
- dev-no-modem orchestrator 路径（device-hardware spec L498）
- vendor SDK 不打入商用打包的隔离规则

**换**（vendor 调用层）：
- `objc.loadBundle("AliRTCSdk", bundle_path=<framework>)` → `objc.loadBundle("DingRTC", bundle_path=<framework>)`
- framework path 默认：`~/codes/vendor/AliRTCSdk_macos/AliRTCSdk.framework` → `~/codes/vendor/DingRTC_macOS_SDK_3_9_0/DingRTC.framework`
- env var：`ISALES_MACOS_ARTC_FRAMEWORK_PATH` → `ISALES_MACOS_DINGRTC_FRAMEWORK_PATH`
- Obj-C selector 名：vendor docs 未公开 macOS PyObjC selector 映射，需 PoC 阶段读 framework `.tbd` 文件确认；约定按 DingRTC iOS SDK selector pattern（`onJoinChannelResult:remoteUid:elapsed:` 类）实施

**Rationale**：PyObjC binding 框架本身（NSObject 子类、selector pattern、framework loading、env var override）与 vendor 厂家无关；只 vendor API 映射层换。

### D5: PoC 顺序按 demo → 真 凭据三段隔离

**Step 1: SDK + binding 验证（demo appid）**
- 装 DingRTC 3.x Linux C++ SDK 3.9.0
- 写 pybind11 binding
- 用 demo appid `a4zfr1hn` + 对应 demo AppKey（在 vendor demo sample 包内查找）跑 `RtcSession.join(channel, token, uid)` 等到 `OnJoinChannelResult` 回调 code=0
- 验"SDK 装对了 + binding 通 + `rtc_token.py` 算法对"

**Step 2: 凭据验证（真 AppId）**
- 切真 AppId `o6dpsan9...` + 真 AppKey（[[project_macos_dev_path]] 私人凭据）
- 同样 `RtcSession.join` 走 demo 跑通的代码路径
- 验"凭据对"

**Step 3: e2e 验证（双 peer）**
- cloud engine + macOS edge / Windows edge 同时 join 同房间
- macOS / Windows edge → cloud engine 上行 PCM，cloud engine → edge 下行 PCM
- 拨真手机 13301035545 听到 AI 开场白 + barge-in

**Rationale**：三段隔离让失败精准定位层。如果跳过 demo 直接试真凭据 → 失败时既可能 SDK 错，又可能 binding 错，又可能凭据错，定位回到 2026-05-25 那种"半天找不到根因"的状态。隔离投入是固定成本，回报是任一步失败 ≤ 30min 定位。

### D6: `rtc_token.py` 不改一行

**实证链**：
1. `rtc_token.py` 头部 docstring 引用 `github.com/aliyun/AliRTCSample/Server/python3/`
2. vendor 下载页 sample 仓 = `https://github.com/aliyun/AliRTCSample` / `https://gitee.com/dingrtc/AliRTCSample/`（同一仓双镜像）
3. gitee 路径 `dingrtc/AliRTCSample` 证实仓库归 DingRTC 维护
4. → `rtc_token.py` 算法 ≡ DingRTC 3.x 算法

**算法保留**：privilege flags + options + HMAC-SHA256 派生 key + zlib + base64 = DingRTC v3.0 binary。换 SDK 后产出直接喂 `RtcEngineAuthInfo.token` 字段。

**Alternatives**：
- 重写 token 为 sha256+JSON+base64 wrapper（2026-05-25 一度评估）→ 否决，因为算法本身正确，问题是 SDK 错

### D7: 联动 active changes 处置（明确顺序）

| Change | 状态 | 本变更对其的影响 |
|---|---|---|
| `engine-artc-sdk-thread-model` | 26/31 active | SHALL archive（本变更落地前 / 同 PR 内），archive 备注标 "DingRTC C++ in-process 调用，sidecar pump 模型整体不再需要；本 change 修的所有问题被 `engine-rtc-dingrtc-migration` 整体淘汰" |
| `arch-cloud-edge-split` | 52/64 active | 本变更对其 device-hardware / deployment-topology / service-communication 三个 delta 提供修订；archive 顺序 = arch-cloud-edge-split 先（保留架构原则）→ dingrtc-migration 后（修正 vendor SDK 选择） |
| `windows-artc-pybind11` | 39/51 active | vendor 调用层重做（D3）；binding 框架保留；本变更落地后该 change 的剩余 12 task 重估 |
| `windows-artc-pybind11-join-config` | 0/23 active | 本变更落地后重启（配置字段形状会从 AliRtcAuthInfo → RtcEngineAuthInfo） |
| `macos-local-audio-dev` | 0/37 active | 待评估 vendor 调用形状对其 dev 路径的影响 |
| `joint-mvp-gate-13301035545` | 11/43 active | 等本变更 cloud + Windows edge 双绿后续推；e2e 验收 gate 即 D5 Step 3 |

### D8: STATE.md / RUNBOOK 必随同一 PR 更新（[[reference_state_files]]）

部署 ground truth 在 STATE.md，不在 OpenSpec change。本变更涉及三端 vendor SDK 路径全换，任何文档不同步都会让下一个接手 session 错读"装哪个 SDK"：

| 文件 | 必动字段 |
|---|---|
| `deploy/cloud/STATE.md` | § "ARTC SDK vendor" 重命名 + CDN URL / 解压路径 / 版本号全换 |
| `isales-telephony/deploy/edge/windows/STATE.md` | SDK 路径 + DLL 名 + pybind11 模块名 |
| `isales-telephony/deploy/edge/macos/RUNBOOK.md` | framework 路径 + 解压指令 + env var 名 |
| `deploy/RUNBOOK-cloud.md` | cloud-side SDK 装载步骤（含 OSS 下载 + 解压 + binding build） |
| `isales-engine/CLAUDE.md`（如有） | `transport/` 目录变更说明 |

### D9: vendor 不进 git，但 binding 源码进 git

**vendor 二进制（不进 git）**：
- Cloud Linux：`/opt/isales/vendor/DingRTC_Linux_SDK_3_9_0/`（含 `.so` + headers）
- Windows：`~/codes/vendor/DingRTC_Windows_SDK_3_9_0/`（含 `DingRTC.dll`）
- macOS：`~/codes/vendor/DingRTC_macOS_SDK_3_9_0/DingRTC.framework`
- `.gitignore` 三端路径全覆盖

**binding 源码（进 git）**：
- `isales-engine/isales_engine/transport/dingrtc/`（cloud Linux pybind11 binding 源码 + CMakeLists）
- `isales-telephony/isales_telephony/audio_bridge/_dingrtc_pywrap_src/`（Windows pybind11 binding 源码，与 cloud 共享 audio_observer / ring_buffer 通用层结构）
- `isales-telephony/isales_telephony/audio_bridge/macos_dingrtc_pyobjc.py`（macOS PyObjC binding 源码）

**rationale**：vendor 二进制 vendor 控制版本 + 不希望 git 仓大；binding 源码必须 in-repo（CI / 多 dev 复现 build）。

## Risks / Trade-offs

| Risk | Mitigation |
|---|---|
| DingRTC Linux C++ SDK 缺 per-uid PCM 订阅（仅混流） | 2-user channel 下混流 = 对方那一路，v1.0 不构成 blocker；如未来 >2 用户场景出现，另起 change 评估替代方案（如 RTC 转 server-side mixer） |
| pybind11 binding build 在 cloud Linux 上需 gcc / cmake / Python dev headers | `deploy/cloud/scripts/install.sh` 加 `install-dingrtc-binding` 步骤（apt install build-essential + cmake + python3-dev + pip install pybind11）；CI 镜像预装 |
| Windows binding 与 PyInstaller 打包路径 | 复用 `windows-artc-pybind11` 既有 `.pyd` 打包路径，PyInstaller `--add-binary` 指 `dingrtc_pywrap.pyd` + `DingRTC.dll` |
| macOS framework `objc.loadBundle("DingRTC", ...)` selector 名 vendor 未公开 | PoC 阶段 `class-dump` 或 `otool -ov` 读 framework `.tbd` 文件提取 selector；不能盲目按 iOS pattern 假设 |
| DingRTC C++ SDK 内部线程模型与 asyncio 集成 | PoC 阶段实测；vendor callback 在 SDK 内部 worker 线程 fire → `loop.call_soon_threadsafe` marshal 回主 loop（与 macOS PyObjC binding 同模式） |
| Token 算法实证基础是 `gitee.com/dingrtc/AliRTCSample` 而非 vendor 官方文档 | PoC Step 1 用 demo appid 跑通就是算法的最终验证；如未来 vendor 改算法，sample 仓 commit 是 ground truth |
| 三端 SDK 版本不同步导致互通失败 | CI 强制三端 vendor 版本号一致（pyproject / build script / STATE.md 三处对账）；任何升 minor 必须三端同 PR |
| 错误回退路径：DingRTC PoC 不通 | 保留 commit ccb10dd（本变更 base）作 git tag；任一阶段 PoC 不通则 revert + 先用 vendor-only Linux sample app（DingRTC 3.x demo 仓 `cmake_demo`）独立跑通 join → 再回项目内 binding |
| 联动 active changes 数量多（6 个），档案顺序敏感 | 在 archive 顺序与 D7 表格固定；CI 加 lint 规则禁止"未先 archive thread-model 就 archive 本变更" |
| 一个月旧的 `_AliyunArtcChannel` 多 worktree 在用 | 删 commit 前在 sub-repo `git log --diff-filter=D -p` 留 audit trail；archived change 文档保留旧 wrapper 设计供历史回查 |

## Migration Plan

### 阶段 0：准备（不破坏现状）
1. 下三端 DingRTC 3.9.0 SDK 到 vendor 路径（不动 git）
2. 在 commit ccb10dd 打 tag `pre-dingrtc-migration` 作回退基线
3. 写本 change 的 design.md + specs/ + tasks.md

### 阶段 1：Cloud Linux PoC（demo appid）
4. 在 `isales-engine` worktree 起新分支 `dingrtc-migration-cloud`
5. 写 pybind11 binding `transport/dingrtc/` —— 最小可 join 集（`Create` / `Destroy` / `SetEngineEventListener` / `JoinChannel` / `LeaveChannel` / `SetExternalAudioSource` / `PushExternalAudioFrame` / `SubscribeAllRemoteAudioStreams` / `RtcEngineAudioFrameObserver`）
6. 用 demo appid `a4zfr1hn` + demo AppKey + `rtc_token.py` 跑 `transport/dingrtc/_smoke_demo.py` → 等到 `OnJoinChannelResult(code=0)`
7. PASS → Step 7；FAIL → 退到 vendor-only `cmake_demo` 独立跑通后重做 binding

### 阶段 2：Cloud Linux PoC（真 AppId）
7. 切真 AppId `o6dpsan9...` + 真 AppKey 复跑 `_smoke_demo.py`
8. PASS → 重写 `_AliyunArtcChannel` 调用方为 `DingRtcSession`；删 `transport/aliyun_rtc.py` / `_rtc_sdk.py` / `_rtc_driver.py`
9. 跑 `tests/transport/` 全套 + ECS smoke `ecs_pcm_loopback_listen.py` 真房间 10s 回环
10. PASS → 提 PR + 合 cloud 部分

### 阶段 3：Windows edge PoC
11. 在 `isales-telephony` worktree 起新分支 `dingrtc-migration-windows`
12. 改 `windows-artc-pybind11` 既有 binding vendor 调用层 → DingRTC 3.x API
13. 用 demo appid → 真 AppId 同样两段隔离
14. e2e: Windows edge + cloud engine 同房间真互通；拨真手机 13301035545 听到 AI 开场白

### 阶段 4：macOS edge PoC
15. 在 `isales-telephony` worktree 起新分支 `dingrtc-migration-macos`
16. 改 `macos_artc_pyobjc.py` PyObjC binding → DingRTC.framework selector
17. demo → 真 AppId 同样两段
18. dev 同学 mac 工作机 join + cloud engine 同房间真互通；策略层 / barge-in dev 演练

### 阶段 5：archive & cleanup
19. archive `engine-artc-sdk-thread-model`（标"被 dingrtc-migration 整体淘汰"）
20. archive `engine-rtc-dingrtc-migration`
21. 更新 [[reference_artc_sdk]] + 5 个项目 memory；STATE.md / RUNBOOK 同步
22. CI 加 vendor SDK 版本 lint（三端必须同 3.9.0）

### 回退策略
- 任一阶段 PoC 不通 → revert 到 tag `pre-dingrtc-migration`
- DingRTC 3.9.0 vendor 提下架 / 重大 bug → 锁回 3.8.x（DingRTC 文档检索更早版本）
- 整体 DingRTC 路线失败（极不可能）→ 评估自研 RTC 或换 AgoraRTC / 腾讯 TRTC（产品级决策，超出本 change）

## Open Questions

- DingRTC macOS framework Obj-C selector 名（PoC 阶段 `class-dump` 后定）
- DingRTC Linux C++ SDK 内部 worker 线程数 / CPU 占用 baseline（PoC 实测；如比当前 sidecar 高于 50%，需调研 SDK 配置项）
- demo appid `a4zfr1hn` 配套 AppKey 在 vendor demo sample 包内哪个文件（下载 demo 包后定）
- `arch-cloud-edge-split` archive 顺序：理论上应在本变更前 archive 保留架构原则，但如果 RTC 路线提前推进，可能并行 archive；最终顺序待两个 change 实施进度确定
- `joint-mvp-gate-13301035545` 是否在本变更内完成 e2e 验收，还是单独推进；建议本变更只保证 D5 Step 3 真房间互通 + 拨真手机听到 AI 开场白这个里程碑，更全的 MVP 验收 gate 仍由 `joint-mvp-gate-13301035545` 独立承担
