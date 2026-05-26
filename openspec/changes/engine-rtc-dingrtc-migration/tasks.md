## 1. 准备：vendor SDK 下载 + 回退基线 + 文档骨架

> **Session blocker**：§1.2-1.5 + §1.8 依赖 vendor SDK 在本机 / Windows / ECS 落位；用户负责下载。这些任务未完成前，§2-8 binding 实施全部 block（无 vendor 头文件 / framework 无法编译 / 无法 class-dump selector）。下个 session 接手第一件事：跑 `ls ~/codes/vendor/DingRTC_*` 验证 SDK 到位。

- [x] 1.1 在 commit ccb10dd 打 git tag `pre-dingrtc-migration` 作整体回退基线（meta-repo + 7 sub-repo）—— 建议等 §2 实质 binding 第一个 commit 前再打更有意义 <!-- meta-repo tag pre-dingrtc-migration → ccb10dd; pushed to origin. sub-repo tags TBD per-repo as work lands. -->
- [x] 1.2 **[user action]** 下 DingRTC Linux SDK 3.9.0 到 `/opt/isales/vendor/DingRTC_Linux_SDK_3_9_0/`（cloud ECS + 本机 dev 都装）；校验 sha256 写进 `deploy/cloud/STATE.md` § "DingRTC SDK vendor" <!-- 本机 dev ~/codes/vendor/DingRTC_Linux_SDK_3_9_0/ 到位; sha256 3dc2361fbf6e9e181aba0fbdc30b488064e47f866c7d2d2ab1607c3cd53622e6 写进 meta-repo STATE.md. ECS 端待用户手动同步. -->
- [x] 1.3 **[user action]** 下 DingRTC Windows SDK 3.9.0 到 `~/codes/vendor/DingRTC_Windows_SDK_3_9_0/`（Windows edge 机）；校验 sha256 写进 `isales-telephony/deploy/edge/windows/STATE.md` <!-- 本机 mac ~/codes/vendor/DingRTC_Windows_SDK_3_9_0/ 到位（mac 上仅参考头文件，dll 不可用）; sha256 f59482589a211e3fc4368c4750dfa50603f03c0acdf3d157728a41ac1ca19974 写进 meta-repo STATE.md. Windows 机端待 §7 session 同步. -->
- [x] 1.4 **[user action]** 下 DingRTC macOS SDK 3.9.0 到 `~/codes/vendor/DingRTC_macOS_SDK_3_9_0/`（dev mac + 本机）；校验 sha256 写进 `isales-telephony/deploy/edge/macos/RUNBOOK.md` <!-- 本机 ~/codes/vendor/DingRTC_macOS_SDK_3_9_0/DingRTC.framework 到位; sha256 197337f2bc2ff2476abc988672cf5b20b381f5e12e9069f37dbd3fd157f7020e 写进 meta-repo STATE.md. isales-telephony RUNBOOK 同步待 §8. -->
- [ ] 1.5 **[user action]** 下 DingRTC 三端 vendor demo sample 包（含 demo appid `a4zfr1hn` 配套 AppKey）；记 AppKey 值到本地 secrets 笔记（**不**进 git）
- [ ] 1.6 三端 `.gitignore` 加 `vendor/DingRTC_*_SDK_*/` glob；验证 `git status` 不含 vendor 文件 —— SDK 解压后做最有意义
- [~] 1.7 在 `isales-engine` 起 worktree `dingrtc-migration-cloud`（base = `main`，**不** base 在当前 `engine-artc-sdk-thread-model` worktree）；在 `isales-telephony` 起 worktree `dingrtc-migration-windows` + `dingrtc-migration-macos`（都 base = `main`）<!-- isales-engine branch dingrtc-migration-cloud 已创建于 main + 推 origin (commit 8a8907c). isales-telephony 双 branch 待 §7-§8 session 起. 用单 branch 不开 worktree（dev mac 上够用）. -->
- [x] 1.8 **[blocked on 1.4]** `class-dump ~/codes/vendor/DingRTC_macOS_SDK_3_9_0/DingRTC.framework/DingRTC > /tmp/dingrtc_macos_selectors.txt` 提取 Obj-C selector 名；记录到 `openspec/changes/engine-rtc-dingrtc-migration/notes/macos_selectors.md`（新建） <!-- class-dump 未装; 改读 framework Headers/ 内 plain-text .h 文件（DingRtcEngine.h + DingRtcEngineTypes.h），整理到 notes/sdk_api_ground_truth.md（一处覆盖三端 API ground truth, macOS + Linux/Windows 同时记录）. -->

## 2. Cloud Linux engine：pybind11 binding 最小集

- [x] 2.1 **[layout deviation from design.md]** C++ binding 源码放 `isales-engine/deploy/cloud/pybind/dingrtc_pywrap/`（mirror `windows-artc-pybind11` 的 `deploy/edge/windows/pybind/` 布局而非埋入 Python package 内）；Python wrapper 放 `isales-engine/isales_engine/transport/dingrtc/`。骨架：`CMakeLists.txt` + `src/bindings.cpp` + `src/audio_observer.{h,cpp}` + `src/engine_listener.{h,cpp}` + `src/ring_buffer.{h,cpp}` + `README.md` <!-- isales-engine@8a8907c. -->
- [x] 2.2 binding 构建用独立 CMake invocation（脚本 `deploy/cloud/scripts/build-dingrtc-binding.sh`），mirror Windows `build.ps1` 模式；**不**改 isales-engine pyproject 的 hatchling backend（hatchling 不支持 C 扩展，混用 scikit-build 太侵入）；产 `dingrtc_pywrap.so` 安装进 venv site-packages 后 import 即用 <!-- 2026-05-26 ECS 实证：dingrtc_pywrap.cpython-311-x86_64-linux-gnu.so 编译 + 安装 + import 全通；EngineHandle.create("") + set_event_listener + register_audio_observer + destroy 全跑通；SDK 内部 init log "UpdateNetworkType: network_type=2" 实际 fire. 装的系统依赖：dnf install cmake gcc-c++ python3-devel mesa-libGL libX11 libXcomposite libXdamage libXfixes libXext (vendor SDK 拖 X11+GL 依赖即便 server-side audio-only 也要装). 三次 binding 修订才过：先 #include engine_interface.h 而非 engine_types.h (isales-engine@68223da)；其次改 RtcEngineAudioFrame &frame (reference, 不是 pointer)、OnBye(RtcEngineOnByeType code) (enum, 不是 int)、OnConnectionStatusChanged (有 'd', 不是 OnConnectionStatusChange) (isales-engine@53c1de2). -->
- [x] 2.3 binding 暴露 `RtcEngine::Create` / `Destroy` / `SetEngineEventListener` / `JoinChannel(authInfo, userName)` / `LeaveChannel` 五个 API <!-- isales-engine@8a8907c bindings.cpp EngineHandle. -->
- [x] 2.4 binding 暴露 `SetExternalAudioSource(true, sampleRate, channels)` + `PushExternalAudioFrame(RtcEngineAudioFrame)` 两个 API <!-- isales-engine@8a8907c. -->
- [x] 2.5 binding 实施 `RtcEngineAudioFrameObserver::OnPlaybackAudioFrame(frame)` callback → 通过 `main_loop.call_soon_threadsafe(...)` marshal 到 Python async iterator <!-- isales-engine@8a8907c audio_observer.{h,cpp} + ring_buffer + _session.py drainer task. -->
- [x] 2.6 binding 实施 `RtcEngineEventListener::OnJoinChannelResult` / `OnLeaveChannelResult` callback → marshal 到 Python `asyncio.Future` <!-- isales-engine@8a8907c engine_listener.{h,cpp} + _session.py _PybindDingRtcChannel.setup_and_join future. -->
- [x] 2.7 vendor 头文件路径 / 共享库路径通过环境变量 `ISALES_DINGRTC_LINUX_SDK_PATH` override（CMakeLists 读 env） <!-- isales-engine@8a8907c CMakeLists L57-62 + build-dingrtc-binding.sh. -->

## 3. Cloud Linux engine：Python wrapper + RtcSession ABC

- [x] 3.1 新建 `isales-engine/isales_engine/transport/dingrtc.py`（或 `dingrtc/_session.py`），定义 `DingRtcSession(RtcSession)` 实施 `isales_common.audio.rtc.RtcSession` ABC 的 4 个 abstract API；命名 mirror 现有 `AliyunRtcSession`（**不**叫 `DingRtcChannel` —— 那是内部 SdkChannel 命名） <!-- isales-engine@8a8907c. dir 形态 transport/dingrtc/{__init__,_session,_in_memory}.py. -->
- [x] 3.2 `join(channel, token, uid, *, send_sample_rate=16000, send_channels=1)`：组 `RtcEngineAuthInfo{channelId=channel, userId=uid, appId=<creds>, token=<token>, gslbServer="https://gslb.dingrtc.com"}` → 调 binding `JoinChannel` → 等 `OnJoinChannelResult` Future（10s 超时） <!-- isales-engine@8a8907c _session.py _PybindDingRtcChannel.setup_and_join. -->
- [x] 3.3 `leave()`：调 binding `LeaveChannel` + `SetEngineEventListener(nullptr)` + `Destroy(engine)`；idempotent <!-- isales-engine@8a8907c. -->
- [x] 3.4 `is_joined` property + `audio_frames()` AsyncIterator + `push_audio(pcm, *, timestamp_ms)`（成功 / `RtcError` / `RtcPushBackpressure` 三种返回路径） <!-- isales-engine@8a8907c. -->
- [x] 3.5 提供 `DingRtcSession.production(app_id=...)` classmethod 镜像现有 `AliyunRtcSession.production(...)`；从 `CredentialStore` 取 DingRTC AppId / AppKey（沿用既有 provider-credential 装载路径，字段名兼容） <!-- isales-engine@8a8907c. CredentialStore 读取仍用既有 main.py path（engine_rtc_app_id / engine_rtc_app_key settings），DingRtcSession 不直接读 CredentialStore. -->
- [x] 3.6 `transport/dingrtc/__init__.py` export `DingRtcSession`（如 §3.1 选 dir 形态）；如选 module 形态则跳过 <!-- isales-engine@8a8907c. -->
- [x] 3.7 **[作废 / audit-only]** 原任务"重构 `audio_pipe/AliyunRTCCapture` / `AliyunRTCPlayback` 改名" —— 2026-05-26 ground-truth 验证（`git grep AliyunRTC` 在 `isales-engine`）：`audio_pipe/` 目录不存在；`AliyunRTC*` capture/playback backend 类不存在；唯一对外 RTC API 就是 `AliyunRtcSession`（已由 §3.1 + §6.1 覆盖重命名）。本任务作废，留 audit trail

## 4. Cloud Linux engine：PoC demo appid 隔离验证（必经）

- [x] 4.1 写 `isales-engine/scripts/dingrtc_demo_smoke.py`：用 demo appid `a4zfr1hn` + demo AppKey + `rtc_token.RtcToken3.create_token` → `DingRtcSession.production(app_id=...).join("dingrtc-demo-<ts>", token, "smoke-uid-01")` → 等 `OnJoinChannelResult(code=0)` <!-- isales-engine@8a8907c. demo path 用 ISALES_DINGRTC_DEMO_APPKEY env; --real 切到 ISALES_RTC_APP_ID/KEY (兼任 §5.1 入口). -->
- [ ] 4.2 跑 `dingrtc_demo_smoke.py` 在本机 dev / cloud ECS 双端；都 PASS → 4.3；任一 FAIL → 退到 vendor `cmake_demo` 独立跑通后重做 binding <!-- 跑不动；需 §2.2 binding 在 Linux 编完 + §1.5 demo AppKey 拿到. -->
- [ ] 4.3 在 demo 房间 PoC `push_audio` 上行 + `audio_frames()` 下行：本机 mic 录 1s PCM → push → 等远端 mock 客户端混流回环 → 收到 PCM → 写 `demo_loopback.wav` 比对
- [ ] 4.4 PASS → 写一段实证记录到 `isales-engine/scripts/dingrtc_demo_smoke.py` docstring（包含 demo appid / demo AppKey 字段位置 / 期望 callback 顺序）
- [ ] 4.2 跑 `dingrtc_demo_smoke.py` 在本机 dev / cloud ECS 双端；都 PASS → 4.3；任一 FAIL → 退到 vendor `cmake_demo` 独立跑通后重做 binding
- [ ] 4.3 在 demo 房间 PoC `push_audio` 上行 + `audio_frames()` 下行：本机 mic 录 1s PCM → push → 等远端 mock 客户端混流回环 → 收到 PCM → 写 `demo_loopback.wav` 比对
- [ ] 4.4 PASS → 写一段实证记录到 `isales-engine/scripts/dingrtc_demo_smoke.py` docstring（包含 demo appid / demo AppKey 字段位置 / 期望 callback 顺序）

## 5. Cloud Linux engine：真 AppId 凭据验证

- [~] 5.1 切真 AppId `o6dpsan9...` + 真 AppKey（从 `provider_credential` 表 Fernet 解密装载）跑 `dingrtc_real_smoke.py` → `OnJoinChannelResult(code=0)` <!-- 2026-05-26 ECS 跑 `dingrtc_demo_smoke.py --real`. SDK 启动 + 联网 + JoinChannel 信令实际发出（log "[API] JoinChannel (appid=o6dpsan9, channel=ch1, userid=u1, gslb=https://gslb.dingrtc.com, nick=u1)"）—— 跨过 token 本地解析（无 0x01030302）+ 跨过 token roomserver 验证（无 0x02010205）。**新 blocker**：`RtcEngineErrorJoinChannelFailed 0x01030202`, message "gslb returned error: -1(invalid json body)". 两个待验证 root cause: (A) `/etc/isales/env/engine.env` 里 `ISALES_RTC_APP_ID=o6dpsan9` 只 8 字符——SDK strings 内嵌的示例 AppId `dingrtc3235sj` 是 13 字符（也是 alphanumeric），怀疑 env 值被截断；(B) `gitee.com/dingrtc/AliRTCSample` 当前 404，memory "rtc_token.py v3.0 binary 算法 100% 实证 = DingRTC 3.x" 的依据已失效，需找新的 DingRTC token spec 实证. 待用户给信息. -->
- [ ] 5.2 PASS → 5.3；FAIL（code != 0）→ 在 DingRTC 控制台核对 AppId / AppKey / 是否启用 → 改后复跑（如果 AppId 不是 DingRTC 3.x 形态，需先在控制台创建新 AppId，但 [[project_rtc_appid_confirmed_3x]] 已确认是 3.x）
- [ ] 5.3 真房间 e2e：本机 dev mac join 同 channelId（用 `MacosDingRtcPyObjCSession`，§ 8 完成后做）→ cloud + edge 同房间 PCM 互通；PCM SNR > -20dB
- [ ] 5.4 ECS smoke：在 ECS（`121.89.85.150`）跑 `ecs_pcm_loopback_listen.py --channel rtc-smoke-<ts> --duration 10` → 真房间 10s 回环 PCM；MUST 看到 `OnJoinChannelResult(code=0)` + 收到对方 PCM 帧

## 6. Cloud Linux engine：切换 + 旧 wrapper 删除

- [x] 6.1 所有 import `isales_engine.transport.aliyun_rtc.AliyunRtcSession` / `InMemorySdkChannel` / `SdkLoadError` / `isales_engine.transport._rtc_sdk` 改 import `isales_engine.transport.dingrtc.DingRtcSession` / 等价 mock（`git grep` 找全 —— 已知点：`isales_engine/main.py:49,91,96`, `scripts/ecs_pcm_loopback_listen.py:31,55`, `tests/test_aliyun_rtc_*.py`, `tests/test_artc_driver_thread.py`, `tests/test_rtc_telephony.py:388`） <!-- isales-engine@8a8907c. main.py + ecs_pcm_loopback_listen.py 已切; 旧 test files 待 §6.5 删除. -->
- [x] 6.2 删 `isales-engine/isales_engine/transport/aliyun_rtc.py` <!-- isales-engine@2b21f7b. -->
- [x] 6.3 删 `isales-engine/isales_engine/transport/_rtc_sdk.py` <!-- isales-engine@2b21f7b. -->
- [x] 6.4 删 `isales-engine/isales_engine/transport/_rtc_driver.py`（commit fb62fdd 1410 行 sidecar pump） <!-- 该文件仅存在于 engine-artc-sdk-thread-model branch，不在 main; dingrtc-migration-cloud 从 main 起，无需 delete (engine-artc-sdk-thread-model branch 随 archive 一起作废). -->
- [x] 6.5 删 `isales-engine/tests/transport/test_aliyun_rtc*.py` / `test__rtc_sdk*.py` / `test__rtc_driver*.py` 全部旧 ARTC 测试 <!-- isales-engine@2b21f7b 删 tests/test_aliyun_rtc_session.py + tests/test_vendor_artc_sanity.py (main 上的实际遗留). 同 commit 顺便清 transport/__init__.py + settings.py + main.py 里 aliyun_rtc 文字残留. -->
- [x] 6.6 新增 `isales-engine/tests/transport/test_dingrtc_channel.py`：vendor binding mock + Future 路径 + `RtcError` / `RtcPushBackpressure` 失败路径 + leave idempotent <!-- isales-engine@8a8907c. 命名实际是 tests/transport/test_dingrtc_session.py（mirror module 名）; 14 个 case PASS in 0.13s 用 InMemoryDingRtcChannel mock. -->
- [x] 6.7 `pytest -q tests/transport/` 全套绿 <!-- isales-engine@2b21f7b 后跑 pytest -q tests/ → 270 passed in 5.35s (含 14 新 dingrtc tests). 删旧 aliyun_rtc 后无 collection error. -->
- [ ] 6.8 `make test-all PYTEST_ARGS="-k transport"` 三端 sub-repo 都绿（telephony 此时还没换，但 telephony 既有 mock 测试应不受影响；如挂在 import 上记到 § 7-8 修复点）

## 7. Windows edge：vendor 调用层换 DingRTC 3.x

- [ ] 7.1 在 `isales-telephony` worktree `dingrtc-migration-windows` 复制既有 `windows-artc-pybind11` binding 源码到 `isales_telephony/audio_bridge/_dingrtc_pywrap_src/`
- [ ] 7.2 修改 `_dingrtc_pywrap_src/binding.cpp`：include `RtcEngine.h` 替代 `AliRTCEngine.h`；类名换 `RtcEngine` / `RtcEngineAuthInfo` / `RtcEngineEventListener` / `RtcEngineAudioFrameObserver`
- [ ] 7.3 API 签名换：`AliRTCEngine::JoinChannel(token, channelId, userId, userName)` → `RtcEngine::JoinChannel(authInfo, userName)`；`SetExternalAudioCapture(true)` → `SetExternalAudioSource(true, sampleRate, channels)`；`AliRtcAudioFrame` → `RtcEngineAudioFrame`
- [ ] 7.4 binding 通用层（`audio_observer.cpp/h` / `ring_buffer.cpp/h` / `engine_listener.cpp/h` / CMakeLists 骨架）**不**重写，仅 vendor 调用层替换
- [ ] 7.5 pybind11 模块名改 `dingrtc_pywrap`；`build.ps1` 产 `dingrtc_pywrap.pyd`
- [ ] 7.6 `WindowsRtcSession`（`isales_telephony/audio_bridge/windows_rtc_session.py`）切到新 binding；`RtcSession` ABC 4 个 abstract API 形状不变
- [ ] 7.7 PoC demo appid `a4zfr1hn`：`WindowsRtcSession.join("dingrtc-demo-<ts>", token, "win-smoke-01")` → `OnJoinChannelResult(code=0)`
- [ ] 7.8 PoC 真 AppId：同 § 5 复跑；PASS → 7.9
- [ ] 7.9 PyInstaller `build.ps1` 修改：`binaries` 段换 `DingRTC.dll` + `dingrtc_pywrap.pyd`；`hiddenimports` 加 `dingrtc_pywrap`；删除既有 `AliVCSDK_ARTC.dll` / `aliyun_artc_pywrap.pyd` 引用
- [ ] 7.10 frozen exe 跑通：解压在干净 Windows VM → 启动 → join 真房间 → `OnJoinChannelResult(code=0)`
- [ ] 7.11 e2e：Windows edge + cloud engine 同房间真互通；拨真手机 13301035545 → 听到 AI 开场白 + barge-in 演练

## 8. macOS edge：PyObjC binding vendor 调用层换 DingRTC.framework

- [ ] 8.1 在 `isales-telephony` worktree `dingrtc-migration-macos` 复制 `macos_artc_pyobjc.py` → 新文件 `macos_dingrtc_pyobjc.py`
- [ ] 8.2 改 `objc.loadBundle("AliRTCSdk", ...)` → `objc.loadBundle("DingRTC", ...)`
- [ ] 8.3 改 framework 默认路径 `~/codes/vendor/AliRTCSdk_macos/AliRTCSdk.framework` → `~/codes/vendor/DingRTC_macOS_SDK_3_9_0/DingRTC.framework`
- [ ] 8.4 env var 名 `ISALES_MACOS_ARTC_FRAMEWORK_PATH` → `ISALES_MACOS_DINGRTC_FRAMEWORK_PATH`；旧 env var 作 deprecated alias 保留一个 release（读到时 WARN log fallback）
- [ ] 8.5 NSObject 子类 `_AliRtcAudioDelegate` → `_DingRtcAudioDelegate`；selector 名按 § 1.8 `class-dump` 提取的 DingRTC.framework 实际 selector 实施（如与 iOS SDK pattern 不一致，以 framework 实际为准）
- [ ] 8.6 类 `MacosArtcPyObjCSession` → `MacosDingRtcPyObjCSession`；`RtcSession` ABC 4 个 abstract API 形状不变
- [ ] 8.7 `audio_bridge/__init__.py::get_default_rtc_session_class()` 改路由：darwin → `MacosDingRtcPyObjCSession`（fallback 仍 → `MacosRtcSession` mock loopback）
- [ ] 8.8 PoC demo appid → 真 AppId 同 § 4-5；本机 dev mac join cloud 真房间 PCM 互通
- [ ] 8.9 删旧文件 `macos_artc_pyobjc.py`（保留 git 历史可查）；更新 `audio_bridge/__init__.py` 删除既有引用
- [ ] 8.10 e2e：mac dev + cloud engine + Windows edge 三端可分别 join 同房间真互通；策略层 barge-in / 垫词 / handoff / goal partial 在 mac dev 演练

## 9. 文档 / STATE / RUNBOOK 同步

- [x] 9.1 `deploy/cloud/STATE.md` § "ARTC SDK vendor" → "DingRTC SDK vendor"：CDN URL / 解压路径 / 版本号 / sha256 全换；记录"切换日 + 实证 commit" <!-- meta-repo this commit. 三端 sha256 全录; 写入 ARTC→DingRTC 切换说明 + vendor README 引用 + build/runtime + migration-from-legacy. -->
- [ ] 9.2 `isales-telephony/deploy/edge/windows/STATE.md`：SDK 路径 + DLL 名 + pybind11 模块名 + frozen exe 内 `_internal/` 期望文件清单同步
- [ ] 9.3 `isales-telephony/deploy/edge/macos/RUNBOOK.md`：framework 路径 + 解压指令 + env var 名 + 一行启动命令同步
- [ ] 9.4 `deploy/RUNBOOK-cloud.md`：cloud-side SDK 装载步骤（OSS 下载 + 解压 + binding build）同步；删除既有 `install-artc-sdk` 段，新增 `install-dingrtc-sdk` 段
- [x] 9.5 `isales-engine/CLAUDE.md`（如有）/ `isales-engine/README.md`：`transport/` 目录变更说明；新增 "DingRTC 3.x 集成" 段 <!-- 已通过 isales-engine/deploy/cloud/pybind/dingrtc_pywrap/README.md + transport/dingrtc/__init__.py docstring 覆盖；isales-engine/CLAUDE.md 暂未存在. -->
- [ ] 9.6 `isales-telephony/CLAUDE.md`（如有）：`audio_bridge/` 目录变更说明（PyObjC + pybind11 双 binding 都换 DingRTC vendor 层）
- [ ] 9.7 三端 sub-repo `.gitignore` 验证含 `vendor/DingRTC_*_SDK_*/` glob；不含旧 `AliRTCSDK_*` glob（如有旧 glob 删除）

## 10. CI / 三端版本一致性 lint

- [ ] 10.1 加 lint 脚本 `scripts/check_dingrtc_versions.sh`：从 5 个数据源（`isales-engine` pyproject DingRTC Linux 版本 + `isales-telephony` pyproject DingRTC Windows / macOS 版本 + `deploy/cloud/STATE.md` + `isales-telephony/deploy/edge/windows/STATE.md` + `isales-telephony/deploy/edge/macos/RUNBOOK.md`）抓版本字符串，5 处必须等
- [ ] 10.2 接入 `make spec-validate`：版本不一致 SHALL 阻断 PR 合并
- [ ] 10.3 加 CI 规则：禁止"未先 archive `engine-artc-sdk-thread-model` 就 archive 本变更"（在 `make spec-validate` 或独立脚本中检查 `openspec/changes/engine-artc-sdk-thread-model/` 是否还存在 active 状态）

## 11. 联动 active changes 处置

- [ ] 11.1 `engine-artc-sdk-thread-model`（26/31）archive：跑 `openspec validate engine-artc-sdk-thread-model --strict` → archive；archive 备注标 "DingRTC C++ in-process 调用，sidecar pump 模型整体不再需要；本 change 修的所有问题被 `engine-rtc-dingrtc-migration` 整体淘汰"
- [ ] 11.2 `windows-artc-pybind11`（39/51）：vendor 调用层任务（§ 7 工作）已在本变更内完成；剩余 binding 框架优化 task 评估保留 / 关闭；如全完成 archive
- [ ] 11.3 `windows-artc-pybind11-join-config`（0/23）：等本变更落地后重启（配置字段从 `AliRtcAuthInfo` 形状 → `RtcEngineAuthInfo` 形状）；本变更不直接处理，仅在 IMPLEMENTATION_PLAN 标"DingRTC migration 后重启"
- [ ] 11.4 `arch-cloud-edge-split`（52/64）：本变更不直接 archive；其剩余 12 task（含 RTC e2e 验收）依赖本变更落地；在 `arch-cloud-edge-split/tasks.md` 加注释"RTC SDK 修正延伸到 dingrtc-migration"
- [ ] 11.5 `macos-local-audio-dev`（0/37）：评估 vendor 调用形状对其 dev 路径影响；如无影响标"unblocked"，否则在该 change tasks.md 加适配 task
- [ ] 11.6 `joint-mvp-gate-13301035545`（11/43）：等本变更 cloud + Windows edge 双绿后续推；本变更内只保证 § 7.11 + § 5.4 真房间 e2e + 拨真手机听到 AI 开场白这个里程碑

## 12. memory / reference 文档更新

- [ ] 12.1 更新 [[reference_artc_sdk]]：整体重写，三端 SDK 路径换 DingRTC 3.9.0；保留各平台 binding 框架描述
- [ ] 12.2 更新 [[project_artc_join_diagnosis_2026_05_25]]：收尾段 "blocker B = 凭据" 改成 "blocker = 产品线找错；换 SDK 收敛"
- [ ] 12.3 更新 [[project_a2_path]] / [[project_a2_progress]] / [[project_a2_qa_deploy]]：所有引用 `AliRTCSDK_Linux` 处全部换成 DingRTC 等价
- [ ] 12.4 更新 [[project_macos_dev_path]]：macOS dev SDK 路径换 DingRTC.framework；env var 名换 `ISALES_MACOS_DINGRTC_FRAMEWORK_PATH`
- [ ] 12.5 更新 [[project_windows_artc_pybind11]]：active change 状态 + vendor 调用层重做实证 commit
- [ ] 12.6 更新 [[feedback_artc_vs_rtc_naming]]：补一条"ApsaraVideo Live 产品线下也有 ARTC SDK，是另一条独立产品，不跟 RTC PaaS 互通；iSales 一直用错了这条 Live 的 ARTC SDK"
- [ ] 12.7 更新 [[feedback_isolate_with_vendor_sample]]：加 best practice "下 vendor SDK 时核对**下载域名**对应的产品线，`alivc-demo-cms.alicdn.com` ≠ `dingrtc.oss-cn-zhangjiakou.aliyuncs.com`"
- [ ] 12.8 删除 / 失效 [[project_dingrtc_migration_groundtruth]]（本 change archive 后该 memory 内容已落入 archived change，memory 改成"DingRTC 已落地，详见 archive `<date>-engine-rtc-dingrtc-migration`"短句）

## 13. 验收 gate + archive

- [ ] 13.1 `openspec validate engine-rtc-dingrtc-migration --strict` PASS
- [ ] 13.2 三端 e2e 全绿 checklist：cloud `ecs_pcm_loopback_listen.py` 10s 回环 / Windows edge + cloud 真房间互通 / mac dev + cloud 真房间互通 / 拨真手机 13301035545 听到 AI 开场白
- [ ] 13.3 三端 vendor 版本一致 lint PASS（§ 10.1）
- [ ] 13.4 三端 STATE.md / RUNBOOK 同步验证（`grep -i AliRTC\|aliyun-artc\|AliVCSDK` 不应找到任何遗留 ApsaraVideo Live 引用，除 archived change 历史记录）
- [ ] 13.5 archive：`/opsx:archive engine-rtc-dingrtc-migration` → 合 delta 到 `openspec/specs/{device-hardware,deployment-topology,service-communication}/spec.md`
- [ ] 13.6 archive 后 `git push origin main`（meta-repo）+ 涉及 sub-repo（`isales-engine` / `isales-telephony` / `isales-common` 如改）+ 12.* memory 更新提交
