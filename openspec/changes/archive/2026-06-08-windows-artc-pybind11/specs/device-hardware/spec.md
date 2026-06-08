## ADDED Requirements

### Requirement: Windows 边缘 ARTC SDK 通过 pybind11 binding 接入

边缘 isales-telephony 进程在 Windows 上 SHALL 通过项目内 pybind11 binding 模块 `aliyun_artc_pywrap` 调用阿里 ARTC SDK for Windows native（C++）API；MUST NOT 假设阿里官方提供 Python wrapper（实测 Windows 发行包仅含 headers + `.lib` + `.dll`，无 Python 绑定）。本 Requirement 并行于 A2 `arch-cloud-edge-split` 中已有的"云端 engine 的 ARTC SDK 接入"Requirement（针对 Linux 官方 Python wrapper），不修改后者。

pybind11 binding 的源码 SHALL 落在 isales-telephony 仓库的 `deploy/edge/windows/pybind/aliyun_artc_pywrap/`；构建产物 `aliyun_artc_pywrap.pyd` MUST 在 PyInstaller 打包前由 `deploy/edge/windows/build.ps1` 通过 CMake build 步骤生成。

#### Scenario: 绑定层 API 形状

- **WHEN** Python 端 `WindowsRtcSession`（`isales_telephony/audio_bridge/windows_rtc_session.py`）需要入会 / 离会 / 推音频 / 收音频
- **THEN** SHALL 通过 `aliyun_artc_pywrap` 模块暴露的接口完成；该模块的接口 SHALL 与 isales-common `audio/rtc.py::RtcSession` ABC 形状语义兼容（`join(channel, token, uid)` / `leave()` / async `audio_frames()` iterator / `push_audio(pcm, ts)`）；MUST NOT 在绑定层引入 asyncio 依赖（异步语义由 Python 侧的 `WindowsRtcSession` 组装）

#### Scenario: 必绑定的最小 SDK 接口集

- **WHEN** 实施 pybind11 binding
- **THEN** SHALL 至少绑定以下 ARTC SDK C++ 接口：
  - `AliRtcEngine::create()` / `AliRtcEngine::destroy()`（engine 生命周期）
  - `JoinChannel(token, channel, uid, username, joinConfig)` / `LeaveChannel()`
  - `SetExternalAudioSource(enable, sampleRate, channelsPerFrame)` / `PushExternalAudioFrameRawData(pcm, length, timestamp)`
  - `IAudioFrameObserver`（接收远端音频回调）+ `RegisterAudioFrameObserver()` / `UnRegisterAudioFrameObserver()`
  - `AliEngineEventListener::onJoinChannelResult` / `onLeaveChannelResult` / `onConnectionLost` / `onError`
- MAY 绑定额外的 SDK 接口（log callback / network quality / video API 等）但在本 change 范围内 SHALL NOT 要求实施；video / screenshare / 互动播放器 API 明确 SHALL NOT 在绑定层暴露（v1.0 audio-only 场景）

#### Scenario: C++ 回调线程与 Python asyncio loop 桥接

- **WHEN** ARTC SDK 内部 audio I/O 线程触发 `IAudioFrameObserver::onAudioFrame` 回调（约 50 Hz）
- **THEN** binding 实现 SHALL 在 C++ 回调线程**不持 GIL** 的情况下把 PCM frame 写入 thread-safe ring buffer；Python 端 SHALL 通过周期性 drainer task（持 GIL）把 frame 批量搬到 asyncio.Queue；MUST NOT 在 audio 回调路径上对每帧调用 `pybind11::gil_scoped_acquire`（避免 GIL 抢占阻塞主 asyncio loop）；低频事件回调（join / leave / connection lost，< 10 Hz）MAY 走 pybind11 trampoline + `gil_scoped_acquire`

#### Scenario: 对象生命周期管理

- **WHEN** Python 端持有 `aliyun_artc_pywrap` 创建的 engine 对象
- **THEN** binding SHALL 用 `std::shared_ptr<AliRtcEngine>` 包装，自定义 deleter 调 SDK 的 `AliRtcEngine::destroy()` 静态函数（而非 C++ `delete`）；audio observer / event listener 等回调对象 SHALL 通过 pybind11 `keep_alive` 注解防止 Python 端 GC 先于 engine 释放；`WindowsRtcSession.close()` 路径 SHALL 先 unset observer 再 destroy engine，避免回调线程在 engine 已销毁时访问；二次 `close()` SHALL 幂等

#### Scenario: 错误传播

- **WHEN** ARTC SDK C++ 接口返回错误码或异常
- **THEN** binding SHALL 把错误码翻译为 Python 异常（`AliyunArtcError(code, message)` 类）；MUST NOT 在 C++ 侧静默吞错；调用方 `WindowsRtcSession` SHALL 把 `AliyunArtcError` 翻译为 `HardwareAlert{kind="rtc_*"}` 通过 cloud-edge gRPC 上报；致命错误（如 `onConnectionLost` 超过 SDK 重试上限）SHALL 触发挂断流程（与 A2 `service-communication` 已定义的 media_lost 路径一致）

#### Scenario: CPython ABI 兼容

- **WHEN** 构建 `aliyun_artc_pywrap.pyd`
- **THEN** binding SHALL 链接与 PyInstaller frozen exe 内嵌相同的 Python 版本（v1.0 锁 Python 3.12.x）；build.ps1 SHALL 在 CMake configure 阶段探测当前 `python --version`，把对应 `Python3_LIBRARY` / `Python3_INCLUDE_DIR` 传给 CMake；MUST NOT 使用 `Py_LIMITED_API`（stable ABI）—— pybind11 对 stable ABI 的支持仍处于实验性，在 audio 回调高频路径上的性能/兼容性风险大于收益

#### Scenario: VC Runtime 依赖

- **WHEN** PyInstaller 打包 frozen exe
- **THEN** PyInstaller spec `binaries` 节 SHALL 显式 collect 构建机的 `msvcp140.dll` / `vcruntime140.dll` / `vcruntime140_1.dll`（VC++ 2015-2022 Redist 可再发行组件）；MUST NOT 让用户单独安装 VC Redist；许可证副本 SHALL 落入 `licenses/microsoft-vcredist-license.txt`

#### Scenario: SDK 版本钉死

- **WHEN** vendor SDK 版本变更
- **THEN** 升级 SDK SHALL 走独立 PR；该 PR SHALL 重跑 D1 §2.4（PyInstaller + ARTC 加载实测）+ §9.3（端到端联合 MVP）；vendor `README.md` SHALL 记录当前支持的 SDK 版本号；绑定层 SHALL 仅依赖 SDK 文档公开的 C++ API，MUST NOT 依赖 implementation detail（如 SDK 内部 struct 布局 / 私有函数）

#### Scenario: 真 SDK 集成测试与 mock 测试隔离

- **WHEN** CI 跑 binding 相关测试
- **THEN** binding 行为单元测试 SHALL 通过 `unittest.mock` 替换 `aliyun_artc_pywrap` 模块进行，不依赖真 SDK，可在 Linux runner 跑（覆盖 `WindowsRtcSession` 的 asyncio Queue 桥接 / join/leave 状态机 / 异常路径）；真 SDK 集成测试 SHALL 标记 `@pytest.mark.requires_artc_sdk`，仅在 Windows runner + 已 vendor SDK 的环境跑；真 RTC e2e（实际入会 + push/pull）SHALL 走 D1 §9.3 硬件验收路径，MUST NOT 要求 CI 覆盖
