<!-- SUPERSEDED 2026-06-08 by `engine-rtc-dingrtc-migration`（§7）。RTC vendor 从 Aliyun ARTC 整体迁到 DingRTC 3.x，ARTC binding + vendor 目录已物理删除（engine 5e1ab5f），本 ARTC pybind 框架作废。spec delta 为废弃设计，归档 --skip-specs 不并入 specs/。 -->

## Why

D1 `windows-client-core` 在 spec 与 tasks.md 中**字面假设阿里云为 Windows 提供官方 ARTC SDK Python wrapper**（同 Linux SDK 形态），把它列为 vendor 依赖（`deployment-topology` L30 / L97 / L108、windows-client-core tasks §1.4 / §7.1）。2026-05-16 PoC 周硬件 bring-up 时下载 Aliyun ARTC SDK for Windows v7.6.0 实测，发现：

> **Windows SDK 是 C++ only**（headers + `.lib` + `.dll`），与 Linux SDK 形态不同，**没有官方 Python wrapper**。

这条假设错位直接卡住 D1 联合 MVP 的两条关键链：

- **D1 §2.4 PyInstaller + ARTC DLL 加载实测**：DLL 单独打进 PyInstaller 也无法从 Python 调到 RTC engine（`AliEngine::create()` 等 C++ symbol 没有 Python 入口）
- **A2 + D1 §9.3 端到端拨号 → AI 开场白**：边缘 audio_bridge 在 macOS 上走 `MacosRtcSession` mock loopback（参见 reference_artc_sdk.md 决策），商用真 audio 路径就是 Windows——没有 Python 入口，audio_bridge 无法 `JoinChannel` + `PushExternalAudioFrame` + 接收 `OnAudioFrame` 回调

A2 + D1 已写入 vendor/README.md（telephony commit 5e58ef2）作为 follow-up，需要单独 OpenSpec change 来承载这块约 1 周工作量的项目内绑定层，并把 D1 spec 中"Python wrapper"的字面假设修正为"项目内 pybind11 binding"。

## What Changes

- **新增 pybind11 binding 项目** `deploy/edge/windows/pybind/aliyun_artc_pywrap/`：项目内 C++ 源码（`CMakeLists.txt` + `src/bindings.cpp` + `src/audio_observer.cpp` + `src/engine_listener.cpp` 等），CMake 构建产出 `aliyun_artc_pywrap.pyd`（CPython 3.12 ABI），链接 `vendor/aliyun-artc-windows/x64/Release/AliRTCSdk.lib`
- **绑定层 API 面**：暴露给 Python 的接口 SHALL 与 isales-common `audio/rtc.py::RtcSession` ABC 形状一致（`join(channel, token, uid)` / `leave()` / `audio_frames()` async iterator / `push_audio(pcm, ts)`）；底层用 `IAudioFrameObserver`（捕获远端 audio）+ `setExternalAudioSource()`（推本端 audio）+ `AliEngineEventListener`（join / leave / disconnect / error 事件）三个 C++ 接口
- **新增 Windows RtcSession 实装** `isales_telephony/audio_bridge/windows_rtc_session.py`：薄包装 `aliyun_artc_pywrap.pyd`，把 C++ 回调适配为 asyncio Queue / async iterator；与既有 `MacosRtcSession`（mock loopback）并列，由 `audio_bridge/__init__.py` 按 `sys.platform` 选择实装
- **更新 PyInstaller spec** `deploy/edge/windows/isales-telephony.spec`：`binaries` glob 加入 `aliyun_artc_pywrap.pyd`；`hiddenimports` 中"ARTC SDK Python wrapper 模块"项删除（不再有 Python wrapper），替换为 `aliyun_artc_pywrap`（项目内 pybind11 模块名）
- **更新构建脚本** `deploy/edge/windows/build.ps1`：在 PyInstaller 步骤前增加 CMake configure + build 步骤（输出 `aliyun_artc_pywrap.pyd` 到约定位置，由 PyInstaller spec 的 glob 拾取）；构建依赖 VS Build Tools 2022 + CMake 3.20+ + pybind11（pip install）
- **修正 D1 spec 字面假设**：`deployment-topology` 中 vendor 目录注释、Windows 依赖列表、PyInstaller hidden imports 三处把"Python wrapper"改为"project-local pybind11 binding"；`device-hardware` 新增 Requirement "Windows ARTC SDK 通过 pybind11 binding 接入"，并行于 A2 已有的"云端 engine 的 ARTC SDK 接入"Requirement
- **更新 vendor/README.md**：把目前的 "windows-artc-pybind11 (proposal, pending)" 注脚替换为实际产物路径与构建命令；保持 vendor SDK 本身仍为 gitignored（proprietary）
- **D1 task §2.4 重新解锁**：原 §2.4 "PyInstaller onedir 打包 + ARTC SDK Windows DLL 加载实测" 的"加载"判定从 "DLL 文件被 PyInstaller 收进 _internal" 升级为 "frozen exe 内 `import aliyun_artc_pywrap; aliyun_artc_pywrap.create_engine(...)` 不抛 ImportError / OSError"

**故意不在本 change 范围**：

- Linux ARTC SDK 接入（isales-engine 已用官方 Python wrapper，arch-cloud-edge-split task 3 已 ship）—— 本 change 仅补 Windows
- macOS ARTC SDK 接入（A2 已决定 macOS 走 mock loopback；macOS 真 SDK 是纯 Obj-C framework，若未来要做需要单独 change）
- 完整的 ARTC SDK 全 API 绑定（video / screenshare / 互动播放器等）—— 本 change 仅绑定 audio path 必需的 ~10 个 C++ 函数 + 3 个 callback 接口
- 项目内 ARTC engine 的对象生命周期管理 / 性能 profiling / 多 session 并发 —— v1.0 单进程单 call 形态，复杂度留给后续 change
- EV 代码签名（D3 范围）—— `aliyun_artc_pywrap.pyd` 与主 exe 共用 D3 的签名流程
- 任何云端代码改动 —— 本 change 是纯边缘 change

## Capabilities

### New Capabilities

无。本 change 不引入新 capability spec，所有变更体现在两份既有 spec 的 delta 上（与 D1 同套约定）。

### Modified Capabilities

- `device-hardware`: 新增 Requirement "Windows 边缘 ARTC SDK 通过 pybind11 binding 接入"，并行于 A2 已有的"云端 engine 的 ARTC SDK 接入"；规定绑定层暴露的 API 与 isales-common `RtcSession` ABC 形状一致、audio path 必需的最小 C++ 接口集（IAudioFrameObserver / setExternalAudioSource / AliEngineEventListener）、错误传播策略
- `deployment-topology`: MODIFY 既有"Windows 客户端依赖与打包"Requirement——把"ARTC SDK for Windows Python wrapper"全部替换为"ARTC SDK for Windows native binary + 项目内 pybind11 binding"；PyInstaller hidden imports 列表中"ARTC SDK Python wrapper 模块"删除，新增 `aliyun_artc_pywrap`；vendor 目录注释更新；构建脚本步骤增加 CMake 阶段

## Impact

**仓库与代码影响**（仅 isales-telephony 仓库，仅边缘 Windows 端）：

| 文件 / 目录 | 改动 |
|---|---|
| `deploy/edge/windows/pybind/aliyun_artc_pywrap/CMakeLists.txt` | 新增。CMake 配置：C++17 / 链接 `AliRTCSdk.lib` + pybind11 / 输出 `aliyun_artc_pywrap.pyd` |
| `deploy/edge/windows/pybind/aliyun_artc_pywrap/src/bindings.cpp` | 新增。pybind11 module 入口，导出 `create_engine` / `destroy_engine` / `join_channel` / `leave_channel` / `set_external_audio_source` / `push_audio_frame` 等 |
| `deploy/edge/windows/pybind/aliyun_artc_pywrap/src/audio_observer.cpp` | 新增。`IAudioFrameObserver` 派生类，C++ 回调把 PCM frame 推 Python 端 thread-safe queue（GIL 通过 `pybind11::gil_scoped_acquire` 处理） |
| `deploy/edge/windows/pybind/aliyun_artc_pywrap/src/engine_listener.cpp` | 新增。`AliEngineEventListener` 派生类，join/leave/disconnect/error 事件 marshal 到 Python callable |
| `deploy/edge/windows/pybind/aliyun_artc_pywrap/tests/test_smoke.py` | 新增。最小冒烟测试（不入真 RTC 房间，仅验证 `import aliyun_artc_pywrap` + `create_engine` + `destroy_engine` 不崩，可在 Windows runner 跑） |
| `isales_telephony/audio_bridge/windows_rtc_session.py` | 新增。`WindowsRtcSession(RtcSession)` 实装，包 `aliyun_artc_pywrap.pyd`，asyncio Queue 桥接 C++ 回调线程与 asyncio loop |
| `isales_telephony/audio_bridge/__init__.py` | 修改。按 `sys.platform == "win32"` 选 `WindowsRtcSession`，macOS 仍走 `MacosRtcSession` mock；Linux 边缘形态不支持（v1.0 范围外） |
| `deploy/edge/windows/isales-telephony.spec` | 修改。`binaries` glob 加 `aliyun_artc_pywrap.pyd`；`hiddenimports` 调整 |
| `deploy/edge/windows/build.ps1` | 修改。PyInstaller 前加 `cmake -S pybind/aliyun_artc_pywrap -B build/pybind && cmake --build build/pybind --config Release` 步骤；产物拷贝到 `pybind/aliyun_artc_pywrap/aliyun_artc_pywrap.pyd` 由 PyInstaller spec 拾取 |
| `deploy/edge/windows/vendor/README.md` | 修改。把当前 "pending" 注脚替换为已实施状态 + 构建命令 |
| `isales-telephony/pyproject.toml` | 修改。`[project.optional-dependencies] windows` 节加 `pybind11>=2.11`（构建期依赖，运行期已 baked in pyd） |
| `tests/windows/test_windows_rtc_session.py` | 新增。用 `unittest.mock` 替换 `aliyun_artc_pywrap` 模块测试 asyncio Queue 桥接 / join/leave 状态机 / 异常路径；真 SDK 集成测试为 `@pytest.mark.requires_artc_sdk` 标记，CI 不跑 |

**外部资源**：

- 无新增 SaaS 依赖（继续用 A2 已开通的阿里 RTC AppId）
- 构建期新增工具链：CMake 3.20+ + VS Build Tools 2022（C++ workload）+ pybind11 >= 2.11；vendor SDK 仍走既有 `deploy/edge/windows/vendor/aliyun-artc-windows/` 路径（gitignored）

**测试影响**：

- pybind11 模块的单元测试通过 `aliyun_artc_pywrap` 的 mock 进行（不依赖真 SDK），可在 Linux CI 跑
- 真 SDK 集成测试 `@pytest.mark.requires_artc_sdk` 必须在 Windows runner + 已 vendor SDK 的环境跑；建议 D1 `windows-tests` CI job 矩阵增加这层（vendor SDK 通过 OSS 私有 bucket 拉取，credential 走 GitHub secret）
- 真 RTC e2e 测试（实际入会 + push/pull audio）仍走 §9.3 的硬件验收路径，本 change 不要求 CI 覆盖

**变更链接**：

- 上游依赖：A2 `arch-cloud-edge-split`（isales-common `RtcSession` ABC 是绑定层契约的源头）；D1 `windows-client-core`（PyInstaller spec / build.ps1 / vendor/README.md 是被修改文件，本 change 必须晚于 D1 这些文件落地——已经落地）
- 平行依赖：D1 §2 PoC week 1 实测中 §2.4（PyInstaller + DLL 加载）的"加载"判定升级到调到 pybind 入口；§9.3 联合 MVP 验收依赖本 change 完成才能跑
- 下游：D2 `hardware-observability`（绑定层可暴露 SDK 内部 stats / 错误码，挂到 `HardwareAlert`）；D3 `windows-installer-and-ota`（`.pyd` 与主 exe 共用 EV Authenticode 签名流程）

**Risk & 缓解**：

| 风险 | 缓解 |
|---|---|
| pybind11 GIL 释放 / 重获在高频 audio 回调（20 ms 帧 = 50 Hz）下 CPU 开销 | 设计上 C++ 回调线程不持 GIL，把 PCM frame 通过 thread-safe ring buffer 推到 Python；Python 侧 asyncio task 周期性 drain 而非每帧回调一次；冒烟期 profile，必要时降到 40 ms 帧或加双 buffer |
| C++ 回调对象的对象生命周期：observer / listener 的 Python 端引用与 C++ engine 之间释放顺序错乱 → use-after-free / double-free | pybind11 `keep_alive` 注解 + `std::shared_ptr` 管理；显式 `destroy_engine` 调用前 `unset_observer()`；测试用 ASAN 跑跨进程冒烟 |
| ARTC SDK 升级（7.6.0 → 后续版本）C++ ABI 变化破坏绑定 | 绑定层只调 SDK 文档公开的 C++ API（不依赖 implementation detail）；vendor README 钉死支持的 SDK 版本号；升级 SDK 由独立 PR 触发，需重跑 D1 §2.4 / §9.3 |
| CPython 3.12 ABI 与 PyInstaller frozen exe 内嵌的 Python ABI 不匹配导致 `import aliyun_artc_pywrap` 失败 | 绑定层用 stable ABI（`Py_LIMITED_API`）或在 CMake 显式 link 与 PyInstaller 同版本 Python；CI 矩阵锁定 Python 3.12.x |
| Visual C++ Redistributable 依赖：用户 PC 缺 `VC++ 2022 Redist` 导致 DLL 加载失败 | PyInstaller spec 的 `binaries` 节显式 collect `msvcp140.dll` / `vcruntime140.dll`；或在 install.ps1 检测并提示用户装 Redist；优先前者（零用户干预） |
| ARTC SDK Windows native 在低延迟 audio 路径上的 P95 ≤ 50 ms SLA（D1 §41 device-hardware 已定）是否达标 | 本 change impl 阶段最小验证脚本（loopback：本端 push → 同房间另一参会者 pull → 测端到端），不达标触发 design.md 备选方案（如内置 jitter buffer 调小 / 优先 WASAPI Exclusive Mode）；可能与 D1 §2.1 WASAPI 实测合并 |
| 一周工作量估算偏乐观——绑定层 + 测试 + 构建脚本 + spec delta merge 实际可能 1.5-2 周 | impl 阶段如超 1 周，先把 join/leave + audio observer 跑通解锁 §9.3 端到端验收；event listener 完整化 / 错误码精细化推到后续 patch；本 change tasks.md 内标注 "MVP scope vs polish scope" 分组 |

**与 D1 / A2 的 spec delta 协同**：

- 本 change 修改 D1 已写入的 `deployment-topology` Windows requirement 字段，**采用 MODIFIED Requirement delta**（与 ADDED 相反），明确删除 / 替换字符串；D1 这两份 spec delta 尚未 archive（D1 还在 implementing），归档时按 OpenSpec 规约由 archive skill 处理 modification chain
- A2 `device-hardware` 已有"云端 engine 的 ARTC SDK 接入"Requirement（针对 Linux SDK 官方 Python wrapper），本 change 的新 Requirement "Windows 边缘 ARTC SDK 通过 pybind11 binding 接入" 是并列形态，互不修改对方
- 归档顺序建议：先 archive 本 change（D1 / A2 同期归档时已经吸收本 change 的修正），再走 D1 / A2 联合 archive；如果 D1 / A2 先 archive，本 change archive 时需手工 merge 这两份 spec
