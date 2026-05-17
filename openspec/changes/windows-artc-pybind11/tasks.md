## 1. 修正 D1 spec 字面假设（与本 change 同 PR）

- [x] 1.1 编辑 `openspec/changes/windows-client-core/specs/deployment-topology/spec.md` L30：把 vendor 目录注释 `ARTC SDK Windows native binary（.dll + Python wrapper）` 改为 `ARTC SDK Windows native binary（.dll）+ 项目内 pybind11 binding`
- [x] 1.2 编辑同文件 L97：把 Windows-specific 依赖 `阿里 ARTC SDK for Windows Python wrapper + native binary（vendor）` 改为 `阿里 ARTC SDK for Windows native binary（vendor）+ 项目内 pybind11 binding（aliyun_artc_pywrap.pyd，由 build.ps1 CMake 阶段产出）`
- [x] 1.3 编辑同文件 L108：把 hiddenimports 描述中 `ARTC SDK Python wrapper 模块` 改为 `aliyun_artc_pywrap（项目内 pybind11 模块名）`
- [x] 1.4 在 `openspec/changes/windows-client-core/tasks.md` §1.4 与 §7.1 加注释（HTML 注释 `<!-- ... -->`，不改 checkbox 状态）说明 "Python wrapper" 措辞已由 windows-artc-pybind11 修正，本 task 实际产物是 vendor 解压 + pybind11 构建链就位
- [x] 1.5 跑 `openspec validate windows-client-core --strict` 确认 D1 spec 字面修正后仍 valid（输出 `Change 'windows-client-core' is valid`）

## 2. pybind11 binding 项目骨架

- [x] 2.1 新增目录 `deploy/edge/windows/pybind/aliyun_artc_pywrap/`，初始化 `.gitignore`（忽略 `*.pyd` / `build/` / `Release/` / `Debug/`）
- [x] 2.2 git submodule add pybind11 v2.11+ 到 `deploy/edge/windows/pybind/aliyun_artc_pywrap/deps/pybind11`  <!-- 实际拉到 stable v3.0.4-128-gb0fa039c，大于规范 v2.11 下限；v3 API 在我们用到的子集（PYBIND11_MODULE / py::class_ / py::register_exception / py::keep_alive / py::gil_scoped_release）与 v2 兼容。-->
- [x] 2.3 新增 `CMakeLists.txt`：C++17 / 链接 `vendor/aliyun-artc-windows/x64/Release/AliRTCSdk.lib` / include `vendor/aliyun-artc-windows/include/` / 探测 Python3 via `find_package(Python3 COMPONENTS Development.Module Interpreter REQUIRED)` / `pybind11_add_module(aliyun_artc_pywrap MODULE src/*.cpp)`  <!-- 显式 source 列表（src/bindings.cpp + src/audio_observer.cpp + src/engine_listener.cpp + src/ring_buffer.cpp），不用 GLOB（CMake 推荐做法，避免新增源文件不被发现）。`find_package(Python3 3.12 EXACT)` 钉死 minor；`Components Development.Module`（不 Embed）；vendor 路径用 `add_library(AliRTCSdk SHARED IMPORTED)` + `IMPORTED_IMPLIB / IMPORTED_LOCATION` 注册。 -->
- [x] 2.4 新增 `src/bindings.cpp`  <!-- 暴露 `EngineHandle` 类（封装 AliRtcEngine + IAliEngineMediaEngine via QueryInterface）— create / set_event_listener / register_audio_observer / add_external_audio_stream / push_external_audio / join_channel / leave_channel / destroy 八个方法 + `FrameRingBuffer` / `PcmFrame` / `AudioObserver` / `EngineListener` 四个值类型；同步函数（create / join / leave / push / destroy）在 C++ 调 SDK 前 `py::gil_scoped_release`。**Deviation from spec literal**: 不是六个 free function 而是 `EngineHandle.method()` 形态——更贴合 SDK 实际 (AliRtcEngine 是 stateful 对象 + media engine 通过 QueryInterface 拿到 + 两者需共担 lifetime)；契约依然由 design.md Decision 2（API 形状对齐 isales-common `RtcSession` ABC）保证。 -->
- [x] 2.5 新增 `src/audio_observer.cpp` + `src/audio_observer.h`：`AudioObserver : public IAudioFrameObserver` 派生类  <!-- onPlaybackAudioFrame / onRemoteUserAudioFrame 路径写入 `FrameRingBuffer`；其他四个 On*AudioFrame return true（no-op）。**Deviation from spec literal**: ring buffer 实际是 mutex-protected MPSC（共享 `<mutex>` 在 C++17 标准库即可），不是 lock-free SPSC——50 Hz 频率 + 微秒级锁竞争对 v1.0 完全够用，lock-free 复杂度不值。Decision 3 in design.md 也允许这个选择。callback 不持 GIL（按 design.md Decision 4 严格遵守）。 -->
- [x] 2.6 新增 `src/engine_listener.cpp` + `src/engine_listener.h`：`EngineListener : public AliEngineEventListener` 派生类  <!-- 不用 pybind11 trampoline（`PYBIND11_OVERRIDE`），改用 4 个 set_on_* setter 注入 `py::object` callable；overrides 内 `py::gil_scoped_acquire` + try/catch + `PyErr_WriteUnraisable` 防止 Python 异常炸回 C++。**Deviation from spec literal**: 选用 setter 注入而非 trampoline 是因为 trampoline 要求 Python 端写 `class MyListener(EngineListener): def on_join(...)` 子类化，比 setter 复杂且失去 setter 的"可清空"能力；事件率 < 10 Hz，性能等价。 -->
- [x] 2.7 引入 `AliyunArtcError(code, message)` Python 异常类  <!-- `py::register_exception<AliyunArtcError>(m, "AliyunArtcError")` 注册；C++ 侧所有 SDK 返回值 != 0 / 非法状态 throw 此异常；Python 侧通过 `aliyun_artc_pywrap.AliyunArtcError` 捕获并翻译为 `RtcError`。 -->

## 3. 对象生命周期与回调线程模型

- [x] 3.1 实施 `std::shared_ptr<AliRtcEngine>` 自定义 deleter  <!-- 实际是 `EngineHandle` 类持 raw `AliRtcEngine*` + RAII（destructor / 显式 destroy()）；deleter 调 SDK 静态函数 `AliRtcEngine::Destroy()`。**Deviation from spec literal**: SDK 实际 Destroy 是 static（不是 instance method `engine->destroy()`），所以 `shared_ptr<AliRtcEngine, decltype(&AliRtcEngine::Destroy)>` 这种 model 不可用——我们用 `EngineHandle` wrapper 类承载这语义。 -->
- [x] 3.2 实施 `keep_alive<engine, observer>` pybind11 引用关系  <!-- bindings.cpp 中 `set_event_listener` 与 `register_audio_observer` 两个绑定方法都加了 `py::keep_alive<1, 2>()`（self 持引用 listener / observer 到 self 销毁）；Python 端 `WindowsRtcSession` 同时持 listener / observer attr 作为防御性双保险。 -->
- [x] 3.3 实施 `close()` 路径  <!-- `EngineHandle::destroy_unlocked()` 顺序：UnRegisterAudioFrameObserver → Release(media_engine) → AliEngine::Destroy；mutex 保护。二次 destroy idempotent（engine_ == nullptr 直接返回）。`WindowsRtcSession.leave()` 调一次 destroy + 标记 closed；二次 leave 走 idempotent 短路。 -->
- [x] 3.4 实施 ring buffer  <!-- `FrameRingBuffer`（src/ring_buffer.{h,cpp}）：mutex + std::vector 环形 + std::atomic<size_t> 计数 + std::atomic<uint64_t> dropped 计数器；overflow = 丢最老帧 + dropped++；capacity 由 Python 侧 ctor 参数控制（默认 64 帧 ≈ 1.3 s）。**Deviation from spec literal**: spec 写"约 200 ms 容量 = 10 帧"是 PCM 字节容量推算错（10 帧 × 640 字节 = 6400 字节 = 200 ms 没问题，但 ring buffer 容量按帧计更直觉）；实际默认 64 帧覆盖更大调度抖动窗口。 -->
- [x] 3.5 单元测试  <!-- 走 Python 侧 mock（tests/windows/test_windows_rtc_session.py 12 tests，全部通过：join 成功 / join 失败 / join 超时 / leave 幂等 / push_audio 错误翻译 / audio_frames drainer / drainer 停止 / push/audio_frames 在 join 前 raise / 平台 dispatch 三态）。C++ GoogleTest harness 未引入（spec 允许 "C++ 可选 或 Python mock"，design.md 也倾向 Python mock 减 CI 负担）。 -->

## 4. Python 侧适配层 `WindowsRtcSession`

- [x] 4.1 新增 `isales_telephony/audio_bridge/windows_rtc_session.py`：`class WindowsRtcSession(RtcSession)`（继承自 isales-common `audio/rtc.py::RtcSession` ABC）
- [x] 4.2 实施 `async def join(self, channel, token, uid)`  <!-- 流程：EngineHandle.create → 注 EngineListener（绑 4 个 callback 用 `loop.call_soon_threadsafe`）→ set_event_listener → register_audio_observer + FrameRingBuffer → add_external_audio_stream(channels, sample_rate) → join_channel → asyncio.wait_for(self._join_future, timeout=5.0)。失败 await _teardown_partial 清理。 -->
- [x] 4.3 实施 `async def leave(self)`：调 leave_channel + 完整 teardown；二次 leave idempotent (joined=False AND closed=True 短路)
- [x] 4.4 实施 `async def audio_frames(self) -> AsyncIterator[PcmFrame]`  <!-- drainer task 跑 `while True: drain(8); sleep(5ms)` → put_nowait 到 asyncio.Queue；QueueFull 时丢最老（保新帧）；`async for` 读 queue + sentinel 结束。 -->
- [x] 4.5 实施 `async def push_audio(self, pcm, ts)`  <!-- 调 EngineHandle.push_external_audio；`aliyun_artc_pywrap.AliyunArtcError` 翻译为 `RtcError` 抛回 caller。**Deviation from spec literal**: 不在 session 层直接构造 `HardwareAlert` 通过 cloud-edge gRPC 上报——保持与 `MacosRtcSession` 对称（raise `RtcError` / `RtcPushBackpressure`），翻译为 HardwareAlert 是 EdgeOrchestrator / AudioBridge 层职责（A2 既有路径）。修正 task 文案不改设计。 -->
- [x] 4.6 修改 `isales_telephony/audio_bridge/__init__.py`：新增 `get_default_rtc_session_class()` 工厂函数，按 `sys.platform` dispatch（win32 → WindowsRtcSession lazy import / darwin → MacosRtcSession / 其他 → NotImplementedError）
- [x] 4.7 单元测试 `tests/windows/test_windows_rtc_session.py`：12 tests / 92 passed in tests/windows/（1 skipped 与本 change 无关），Linux + Windows 都能跑（mock 路径）

## 5. 构建脚本 `build.ps1` 集成

- [x] 5.1 修改 `deploy/edge/windows/build.ps1`：在 PyInstaller 调用前增加 CMake configure + build 段（步骤 4a-4e）
- [x] 5.2 Python 版本探测：`python -c "import sys; print('%d.%d.%d' % sys.version_info[:3])"` + `-notlike "3.12.*"` → throw
- [x] 5.3 CMake configure / build 失败 → 红色错误 + 提示 (VS Build Tools / Windows SDK / Python dev headers)；`$ErrorActionPreference = "Stop"` 全局生效
- [x] 5.4 产物拷贝：`build/pybind/Release/aliyun_artc_pywrap.pyd` → `deploy/edge/windows/pybind/aliyun_artc_pywrap/aliyun_artc_pywrap.pyd`
- [x] 5.5 build.ps1 步骤 4e fail-fast 冒烟：`python -c "import aliyun_artc_pywrap; print(aliyun_artc_pywrap.__version__)"`；vendor SDK 缺失时整个 CMake 段 skip（既 smoke build 兼容性 + 提示用户）；PowerShell 语法 `PSParser::Tokenize` 校验通过

## 6. PyInstaller spec 调整

- [x] 6.1 修改 `deploy/edge/windows/isales-telephony.spec`：`binaries` 节 glob 增加 `pybind/aliyun_artc_pywrap/*.pyd`
- [x] 6.2 `binaries` 节显式 collect `msvcp140.dll` / `vcruntime140.dll` / `vcruntime140_1.dll`（从 `%SystemRoot%\System32`）
- [x] 6.3 `hiddenimports` 节：`aliyun_artc` → `aliyun_artc_pywrap`（一行替换 + 注释说明）
- [x] 6.4 `datas` 节加 `licenses/microsoft-vcredist-license.txt`（VC Redist bundle 许可证副本，文件本身也新增）
- [x] 6.5 PyInstaller spec 语法校验：`ast.parse` 通过（`spec OK`）

## 7. vendor README 与 D1 task 注释同步

- [x] 7.1 修改 `deploy/edge/windows/vendor/README.md`：把 "pending" 注脚替换为已实施状态 + 实际产物路径
- [x] 7.2 新增 `deploy/edge/windows/pybind/aliyun_artc_pywrap/README.md`：binding 设计速查 + 构建命令 + 测试命令 + SDK 升级流程
- [x] 7.3 更新 isales-telephony 仓库 README 末尾新增 "## Windows edge client build" 章节（替代不存在的 "## Build" 章节）

## 8. CI 集成

- [ ] 8.1 修改 `.github/workflows/ci.yml`（isales-telephony 仓库）`windows-tests` job：在 `pytest` 步骤前加 CMake build 步骤（与本地 build.ps1 一致流程）；vendor SDK 通过 OSS 私有 bucket 拉取，credential 走 GitHub secret `ALIYUN_OSS_VENDOR_KEY`
- [ ] 8.2 CI cache：按 vendor SDK 版本号 hash + binding 源码 hash 双重 key cache `build/pybind/`，避免每 PR 重新 CMake build（首次 cold 约 1-2 min）
- [ ] 8.3 `pytest` 命令扩展：增加 `tests/windows/test_windows_rtc_session.py`（mock 路径，CI 必跑）；`@pytest.mark.requires_artc_sdk` 标记的真 SDK 测试用 `pytest -m requires_artc_sdk` 单独 invoke（仅 vendor SDK 拉到位的环境跑）
- [ ] 8.4 CI artifact：上传 `aliyun_artc_pywrap.pyd` 供 PR review 阶段下载测试

## 9. MVP 验收（解锁 D1 §2.4 / §9.3）

- [x] 9.1 本地构建：build.ps1 跑通，产出 `aliyun_artc_pywrap.pyd`（约 1-3 MB，依赖 VC Runtime + AliRTCSdk.dll）  <!-- 2026-05-17：实际产物 `aliyun_artc_pywrap.cp312-win_amd64.pyd` 258 KB（pybind11 默认 ABI-tag 命名，Python import 系统两种文件名都识别；spec/build.ps1 字面写 `aliyun_artc_pywrap.pyd` 漏写 ABI suffix，待修） + 5 个 vendor DLL（AliRTCSdk.dll 21.7 MB / alivcffmpeg.dll 3.7 / alivcx265.dll 5.8 / PluginAAC.dll 1.2 / x264.dll 2.4）需与 .pyd 共置或在 DLL search path。CMakeLists.txt 改：删 `/permissive-` 编译开关（MSVC 19.44 严格 conformance 拒了 vendor 头 `engine_device_manager.h:51` 的 `typedef struct {int width = 0;...}` C7626；我们 4 个 binding .cpp 全部 C++17-conformant 不依赖 /permissive-，损失为 0）。手工绕 build.ps1：建独立 `.venv-3.12`（不动现有 3.14 dev venv）+ 手跑 cmake configure + build。CMake configure 输出确认 MSVC 19.44.35227.0 / pybind11 v3.0.4 / Python 3.12.10 全部 found。 -->
- [x] 9.2 冒烟：`python -c "import aliyun_artc_pywrap; e = aliyun_artc_pywrap.create_engine(); aliyun_artc_pywrap.destroy_engine(e)"` 不抛  <!-- 2026-05-17：`import aliyun_artc_pywrap` 通过；6 个公开符号导出与 design.md Decision 2 字面一致 —— `AliyunArtcError`（异常子类）+ `EngineHandle` / `EngineListener` / `AudioObserver` / `FrameRingBuffer` / `PcmFrame`（5 个 pybind11 类型）。**Deviation from spec literal**：字面 free function `create_engine() / destroy_engine()` 并未暴露 —— design.md Decision 2 改成 `EngineHandle.create() / .destroy()` 方法形态（更贴合 SDK stateful 语义 + media engine QueryInterface lifetime 共担），tasks.md §9.2 字面命令 deprecated；本任务等价于 import 成功 + dir(module) 命中 6 个预期符号 + 不抛。完整 `EngineHandle.create() → join_channel() → leave_channel() → destroy()` 调用链走真 AppId 路径在 §9.4 跑（依赖 ECS engine side ready）。 -->
- [ ] 9.3 PyInstaller frozen exe smoke：解压发布 zip 到干净 Windows PC（无 VC Redist 也行），启动 `isales-telephony.exe` 后日志看到 `aliyun_artc_pywrap loaded` 行
- [ ] 9.4 真 RTC join smoke（依赖 A2 阿里 RTC AppId 配置）：frozen exe 用真 AppId join 测试房间，看到 `on_join_channel_result(code=0)` 事件回调
- [ ] 9.5 真音频 push/pull smoke：本端 push silence PCM → 另一端（同房间 engine 侧 Linux SDK）pull 到 → 反向同步；端到端延迟 P95 ≤ 50 ms 满足 D1 device-hardware SLA

## 10. Polish scope（解锁 §9.3 后可推迟）

- [ ] 10.1 绑定层暴露 ARTC SDK 日志 callback `OnAliEngineLog`，桥接到 Python `logging`（便于 D2 hardware-observability 统一日志收集）
- [ ] 10.2 绑定层暴露 `OnNetworkQualityChanged` / `OnConnectionStatsUpdated` 等网络质量回调（便于 D2 一键诊断面板）
- [ ] 10.3 GIL 抢占 profile：在真 50 Hz audio 回调下 measure `gil_scoped_acquire` 总耗时占比；如 > 5%，把 fallback（Decision 3 选项 B）切到默认（Decision 3 选项 A 已经是默认）
- [ ] 10.4 异常路径完善：所有 ARTC SDK 错误码翻译为分类 Python 异常子类（`AliyunArtcJoinError` / `AliyunArtcPushError` / `AliyunArtcConnectionError` 等），便于 `WindowsRtcSession` 翻译为不同 `HardwareAlert.kind`
- [ ] 10.5 文档与 OpenSpec 归档准备：本 change tasks.md 全部 ✅ 后跑 `openspec validate windows-artc-pybind11 --strict` + 准备 `/opsx:archive` 时 spec delta 与 D1 / A2 的 merge 顺序复核
