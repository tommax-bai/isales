## ADDED Requirements

### Requirement: 云端 isales-engine 通过项目内 pybind11 binding 接入 DingRTC 3.x Linux C++ SDK

云端 isales-engine SHALL 在 `isales-engine/isales_engine/transport/dingrtc/` 目录下通过项目内 pybind11 binding（产物 `dingrtc_pywrap.so`）包装 DingRTC Linux C++ SDK 3.x，作为 engine session 的 RTC 入会与音频 IO 实现；MUST 暴露 asyncio-friendly 接口供 `audio_pipe` 与 engine session 主循环调用；MUST 实施 `isales_common.audio.rtc.RtcSession` ABC 的 4 个 abstract API（`join(channel, token, uid, *, send_sample_rate, send_channels)` / `leave()` / `is_joined` property / `audio_frames()` async iterator / `push_audio(pcm, *, timestamp_ms)`）。

本 Requirement 取代既有 "云端 engine 的 ARTC SDK 接入"（来自 `arch-cloud-edge-split`，包装 `AliRTCSDK_Linux-7.10.2` Python wrapper + TCP sidecar IPC 模型）。诊断根因：既往 SDK 是 **ApsaraVideo Live 产品线**下的 ARTC SDK（域名 `alivc-demo-cms.alicdn.com`），与 ECS 配置的 **DingRTC 3.x AppId**（`o6dpsan9...`，域名 `dingrtc.oss-cn-zhangjiakou.aliyuncs.com`）不互通 → token 验证必然失败（[[project_dingrtc_migration_groundtruth]]）。

#### Scenario: 项目内 pybind11 binding 编译产物

- **WHEN** cloud Linux engine 部署 / CI 构建
- **THEN** `transport/dingrtc/CMakeLists.txt` SHALL 编译 pybind11 binding，产物 SHALL 为 `dingrtc_pywrap.so`（Linux ELF shared object，CPython ABI 兼容）；编译命令 SHALL 通过 `pip install -e .` 触发（pyproject `[tool.scikit-build]` 或等价 build backend）；MUST NOT 提交 `.so` 二进制到 git 仓库（编译产物在 `.gitignore`）
- 编译过程 SHALL 引用 DingRTC SDK 头文件（默认 `/opt/isales/vendor/DingRTC_Linux_SDK_3_9_0/include/`）与共享库（默认 `/opt/isales/vendor/DingRTC_Linux_SDK_3_9_0/lib/libDingRTC.so`）；vendor 路径 SHALL 通过环境变量 `ISALES_DINGRTC_LINUX_SDK_PATH` 允许 override

#### Scenario: 入会用 RtcEngineAuthInfo 结构（DingRTC 3.x API）

- **WHEN** `RtcSession.join(channel, token, uid, *, send_sample_rate=16000, send_channels=1)` 被调用
- **THEN** binding SHALL 内部调用 `RtcEngine::Create(extras)` 创建 engine 实例 → `SetEngineEventListener(listener)` 注册回调 → 组装 `RtcEngineAuthInfo{channelId=channel, userId=uid, appId=<from credentials>, token=<token>, gslbServer="https://gslb.dingrtc.com"}` → `engine->JoinChannel(authInfo, userName=uid)`
- token 字段 SHALL 直接喂 `isales_engine.transport.rtc_token` 产出（v3.0 binary 算法不变；rtc_token 模块 SHALL NOT 被本变更修改）
- `join` SHALL 等 `OnJoinChannelResult` 回调（通过 main-loop `asyncio.Future`），10 秒超时 raise `RtcError`；result code 非 0 SHALL raise `RtcError(code, message)`

#### Scenario: 外部音频源 push / 远端 PCM observer

- **WHEN** session join 成功后第一次 `push_audio` 调用之前
- **THEN** binding SHALL 调用 `engine->SetExternalAudioSource(true, sampleRate, channels)` 启用外部音频源（参数取 `join` 时传入的 `send_sample_rate` / `send_channels`）；SHALL `engine->PublishLocalAudioStream(true)` + `engine->PublishLocalVideoStream(false)`（audio-only 拓扑）
- **WHEN** `RtcSession.push_audio(pcm, *, timestamp_ms)` 被调用
- **THEN** binding SHALL 组装 `RtcEngineAudioFrame{type=PCM16, bytesPerSample=2, samplesPerSec=sampleRate, channels=channels, buffer=pcm, samples=len(pcm)//2//channels, timestamp=timestamp_ms}` → `engine->PushExternalAudioFrame(&frame)`；调用失败 SHALL raise `RtcError`；vendor 报 buffer full SHALL raise `RtcPushBackpressure`
- 远端订阅 SHALL 走 `engine->SubscribeAllRemoteAudioStreams(true)`（仅混流模式；DingRTC Linux C++ SDK 不提供 per-uid PcmBeforMixing 订阅，v1.0 2-user channel 下混流 = 对方那一路，不构成 blocker）
- binding SHALL 实施 `RtcEngineAudioFrameObserver::OnPlaybackAudioFrame(frame)` 回调，把 PCM 通过 `main_loop.call_soon_threadsafe(...)` marshal 到 `audio_frames()` AsyncIterator

#### Scenario: 离会与销毁

- **WHEN** `RtcSession.leave()` 被调用 或 进程退出
- **THEN** binding SHALL 调用 `engine->LeaveChannel()` → `engine->SetEngineEventListener(nullptr)` → `RtcEngine::Destroy(engine)`；leave SHALL 是 idempotent（二次 leave 不抛）
- 销毁后 engine 指针 SHALL 置 nullptr；后续任何 API 调用 SHALL raise `RtcNotJoined`

#### Scenario: vendor 二进制不进 git，binding 源码进 git

- **WHEN** 任何 commit / PR / CI 构建
- **THEN** DingRTC SDK 共享库 / 头文件 / 文档 SHALL **NOT** 提交到任何 git 仓库；vendor 路径 SHALL 在 `.gitignore` 覆盖（默认 `/opt/isales/vendor/DingRTC_Linux_SDK_*/` glob）
- `transport/dingrtc/` 下的 pybind11 binding 源码（`.cpp` / `.h` / `CMakeLists.txt` / `pyproject` 配置）SHALL 进 git；binding 编译产物（`*.so`）SHALL **NOT** 进 git

### Requirement: macOS 边缘 DingRTC SDK 通过 PyObjC binding 接入（dev / QA 形态）

边缘 isales-telephony 进程在 macOS 13+（x86_64 + Apple Silicon）上 SHALL 通过 `isales_telephony/audio_bridge/macos_dingrtc_pyobjc.py`（项目内 PyObjC bridge）接入真 DingRTC SDK macOS framework；本 Requirement 取代既有 "macOS 边缘 ARTC SDK 通过 PyObjC binding 接入"（loadBundle `AliRTCSdk.framework` 路径），将 vendor SDK 从 ApsaraVideo Live 产品线 ARTC SDK（`AliRTCSdk_7.8.10000-SNAPSHOT`）切换到 DingRTC 3.x（`DingRTC_macOS_SDK_3_9_0`）。

形态边界（dev/QA only / MUST NOT 进商用 / 与既有 mock loopback 并存）与既有 spec 一致；本 Requirement 仅替换 vendor SDK 调用层。

#### Scenario: PyObjC + `objc.loadBundle("DingRTC", ...)` 加载 framework

- **WHEN** 边缘进程在 darwin 平台启动且 `pyobjc-core` 与 `pyobjc-framework-Cocoa` 已安装（通过 `[macos-artc]` optional extras，extras 名保持向后兼容）且 `DingRTC.framework` 解压在约定路径
- **THEN** `MacosDingRtcPyObjCSession.__init__` SHALL 通过 `objc.loadBundle("DingRTC", bundle_path=<framework path>)` 显式加载 framework
- framework path 默认 SHALL 为 `~/codes/vendor/DingRTC_macOS_SDK_3_9_0/DingRTC.framework`；env var `ISALES_MACOS_DINGRTC_FRAMEWORK_PATH` SHALL 允许 override 该默认值（既有 `ISALES_MACOS_ARTC_FRAMEWORK_PATH` SHALL 作 deprecated alias 保留一个 release 周期，读到时 WARN log 并 fallback 解析）
- framework 加载失败（路径不存在 / 不是 framework / 架构不兼容 / Obj-C class lookup 失败）SHALL 在 `__init__` 抛 `RtcError`，错误信息 SHALL 含具体诊断（缺失路径 / 缺失 class / Obj-C runtime error）

#### Scenario: PyObjC NSObject 子类作 DingRtc audio delegate，audio-only 子集

- **WHEN** binding 模块加载
- **THEN** SHALL 定义 PyObjC NSObject 子类 `_DingRtcAudioDelegate` 实施 audio-only 子集 selector（具体 selector 名由 PoC 阶段 `class-dump` framework `.tbd` 确认；约定按 DingRTC iOS SDK selector pattern 实施 `onJoinChannelResult:channel:elapsed:` / `onLeaveChannelResult:` / `onAudioFrame:` 类回调）
- selector 实施 SHALL 把 vendor callback 通过 `main_loop.call_soon_threadsafe(...)` marshal 到 main loop；MUST NOT 在 Obj-C 回调线程内直接调 Python asyncio API

#### Scenario: `MacosDingRtcPyObjCSession` 实施 `RtcSession` ABC，形状镜像 cloud 与 Windows session

- **WHEN** `MacosDingRtcPyObjCSession` 实例被使用
- **THEN** SHALL 实施 `isales_common.audio.rtc.RtcSession` ABC 的 4 个 abstract API；失败模式（`RtcError` / `RtcNotJoined` / `RtcPushBackpressure`）SHALL 与 cloud `DingRtcSession` / Windows `WindowsRtcSession` 一一对齐

#### Scenario: 平台默认路由 darwin → DingRTC PyObjC binding，fallback to mock

- **WHEN** `audio_bridge/__init__.py::get_default_rtc_session_class()` 在 `sys.platform == "darwin"` 下被调用
- **THEN** SHALL 优先 import `MacosDingRtcPyObjCSession` 并返回该类
- **WHEN** import 失败（pyobjc / framework 缺失 / SDK 不在路径）
- **THEN** SHALL 打 WARN log（含装包指引："pip install -e '.[macos-artc]' 并解压 DingRTC SDK 到 ~/codes/vendor/DingRTC_macOS_SDK_3_9_0/"）并 fallback 返回 `MacosRtcSession` mock loopback；MUST NOT 抛硬错（fresh checkout 不应 crash）
- MUST NOT 引入 `ISALES_EDGE_RTC_BACKEND` 类 env var 强制覆盖 platform 选择

#### Scenario: vendor SDK 与依赖隔离

- **WHEN** 商用 Windows PyInstaller 构建 / cloud Linux deploy
- **THEN** `pyobjc-core` / `pyobjc-framework-Cocoa` / `DingRTC.framework` SHALL **NOT** 被打入商用 frozen exe 或 cloud image
- `pyobjc-core` / `pyobjc-framework-Cocoa` SHALL 仅在 `isales-telephony` pyproject `[project.optional-dependencies].macos-artc` 中声明（extras 名保留 `macos-artc` 向后兼容）；商用构建装 base + Windows-specific extras，不装 `[macos-artc]`
- vendor `DingRTC.framework` SHALL **NOT** 进任何 git 仓库；按 [[reference_artc_sdk]] 约定放 `~/codes/vendor/DingRTC_macOS_SDK_3_9_0/`，运行时 `objc.loadBundle(bundle_path=...)` 注入

### Requirement: Windows 边缘 DingRTC SDK 通过项目内 pybind11 binding 接入（vendor 调用层切 DingRTC 3.x）

边缘 isales-telephony 进程在 Windows 10 21H2+ / Windows 11（x64）上 SHALL 通过 `isales_telephony/audio_bridge/windows_rtc_session.py` + 项目内 pybind11 binding（产物 `dingrtc_pywrap.pyd`，源码 `isales-telephony/isales_telephony/audio_bridge/_dingrtc_pywrap_src/`）包装 DingRTC Windows SDK 3.x（`DingRTC.dll`），作为边缘 RTC 入会与音频 IO 实现。

本 Requirement 取代既有 `windows-artc-pybind11` 实装中的 vendor 调用层（包装 `AliVCSDK_ARTC-7.6.0`），保留其 binding 框架（CMake / audio_observer / ring_buffer / engine_listener 通用层 ~80%）；vendor 调用层换 DingRTC 3.x API。

#### Scenario: vendor 路径与 DLL 名

- **WHEN** Windows edge 部署 / `build.ps1` PyInstaller 构建
- **THEN** vendor SDK SHALL 解压在 `C:\Users\<user>\codes\vendor\DingRTC_Windows_SDK_3_9_0\`（或环境变量 `ISALES_DINGRTC_WINDOWS_SDK_PATH` 指定路径）
- DLL 名 SHALL 为 `DingRTC.dll`（取代 `AliVCSDK_ARTC.dll` / `AliRTCSdk.dll`）；PyInstaller spec `binaries` 段 SHALL 显式包含 `DingRTC.dll` + 项目内 binding 产物 `dingrtc_pywrap.pyd`
- pybind11 模块名 SHALL 为 `dingrtc_pywrap`（取代 `aliyun_artc_pywrap`）；PyInstaller `hiddenimports` 段同步更新

#### Scenario: vendor 调用层 API 映射

- **WHEN** binding 编译
- **THEN** 头文件 include SHALL 改为 DingRTC 3.x 提供（`RtcEngine.h` / `RtcEngineAudioFrameObserver.h` / `RtcEngineEventListener.h`）；类名 SHALL 改为 `RtcEngine` / `RtcEngineAuthInfo` / `RtcEngineEventListener` / `RtcEngineAudioFrameObserver`；API 签名 SHALL 与 cloud Linux DingRTC binding 同（`Create` / `Destroy` / `SetEngineEventListener` / `JoinChannel(authInfo, userName)` / `LeaveChannel` / `SetExternalAudioSource(true, sampleRate, channels)` / `PushExternalAudioFrame(RtcEngineAudioFrame)` / `SubscribeAllRemoteAudioStreams(true)`）

#### Scenario: binding 通用层（vendor 无关）保留

- **WHEN** 本变更落地
- **THEN** `windows-artc-pybind11` 既有 binding 框架的通用层 SHALL **NOT** 被重写：
  - `CMakeLists.txt` build pipeline 骨架
  - `audio_observer.cpp/h`（`OnPlaybackAudioFrame` callback 桥接）
  - `ring_buffer.cpp/h`（capture / playback PCM 环形 buffer）
  - `engine_listener.cpp/h`（engine 事件 callback 桥接）
  - Python wrapper `WindowsRtcSession` 形状 + `RtcSession` ABC 实施
- 仅 vendor 调用层（包含的头文件、类名、API 签名）SHALL 重写为 DingRTC 3.x

#### Scenario: 三端 SDK 版本一致性 lint

- **WHEN** CI 构建 / `make spec-validate` / 任何 PR 提交
- **THEN** SHALL 强制三端 DingRTC SDK 版本号一致（`isales-engine` pyproject DingRTC Linux SDK 版本 + `isales-telephony` pyproject DingRTC Windows / macOS SDK 版本 + `deploy/cloud/STATE.md` + `isales-telephony/deploy/edge/windows/STATE.md` + `isales-telephony/deploy/edge/macos/RUNBOOK.md`，5 处对账）；版本不一致 SHALL 阻断 PR 合并
- 任何升 minor SHALL 三端同 PR；MUST NOT 单端升

## REMOVED Requirements

<!-- 2026-06-27 归档对账：原 REMOVED「…aliyun_rtc.py…recvCoroutine」已 moot——该 requirement 在 live device-hardware spec 中已不存在（前序 change 已移除），故撤掉此 REMOVED 以免 archive abort；原意（淘汰 aliyun_rtc sidecar/recvCoroutine）已由 DingRTC C++ in-process 达成。 -->

### Requirement: 云端 engine 的 ARTC SDK 接入

**Reason**: 本 Requirement（来自 active change `arch-cloud-edge-split`，包装 `AliRTCSDK_Linux-7.10.2` Python wrapper）选错产品线（ApsaraVideo Live 而非 RTC PaaS DingRTC），与 ECS AppId 不互通。本变更新增 "云端 isales-engine 通过项目内 pybind11 binding 接入 DingRTC 3.x Linux C++ SDK" Requirement 取代。

**Migration**:
- vendor 路径 `/opt/isales/current/vendor/aliyun-artc-linux-python/` SHALL 弃用；改为 `/opt/isales/vendor/DingRTC_Linux_SDK_3_9_0/`
- `deploy/cloud/scripts/install.sh` 中 `install-artc-sdk` 步骤 SHALL 改名 `install-dingrtc-sdk`，下载源 SHALL 从 `dingrtc.oss-cn-zhangjiakou.aliyuncs.com/sdk/linux/3.9.0/DingRTC_Linux_SDK_3_9_0.zip` 拉取
- `audio_pipe` 的 `AliyunRTCCapture` / `AliyunRTCPlayback` backend 类 SHALL 重命名为 `DingRtcCapture` / `DingRtcPlayback`，capture-backend / playback-backend 抽象基类不变
- engine session 启动调用 `aliyun_rtc.RtcSession(...).join()` SHALL 改为 `dingrtc.DingRtcSession(...).join()`；接口形状（`async def on_audio_frame()` / `async def push_audio(pcm, timestamp)` / `await leave()`）SHALL 保持兼容

### Requirement: macOS 边缘 ARTC SDK 通过 PyObjC binding 接入（dev / QA 形态）

**Reason**: ApsaraVideo Live ARTC 产品线整体被 DingRTC 3.x 取代（macOS 走 DingRTC PyObjC dev/QA 形态，见本 change ADDED 的「macOS 边缘 DingRTC SDK 通过 PyObjC binding 接入」），ARTC SDK 已不存在。
