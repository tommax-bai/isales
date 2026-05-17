## Context

2026-05-16 D1 PoC week 1 硬件 bring-up 期间下载阿里 ARTC SDK for Windows v7.6.0 实测，发现 Windows 发行包与 Linux 发行包形态根本不同：

| 维度 | Linux SDK | Windows SDK |
|---|---|---|
| 语言绑定 | 官方 Python wrapper（`alirtc_python.so` + .py 入口） | C++ only（headers + `.lib` + `.dll`） |
| 集成方式 | `pip install -e file://vendor/` 直接 import | 必须自己写 binding 才能从 Python 调到 |
| iSales 已落地形态 | isales-engine `transport/_rtc_sdk.py` 直接 import vendor 模块（arch-cloud-edge-split task 3 ship） | **不存在**（D1 spec 字面假设有 Python wrapper） |

D1 `windows-client-core` 的 `deployment-topology` spec delta 写了 vendor 目录注释 "ARTC SDK Windows native binary（.dll + Python wrapper）"、Windows 依赖列表写了"ARTC SDK for Windows Python wrapper + native binary"、PyInstaller hidden imports 写了"ARTC SDK Python wrapper 模块"——三处都基于错误假设。

D1 的 §2.4（PyInstaller + ARTC DLL 加载实测）当前停在"DLL 文件被打进 _internal"层面，无法继续；§9.3 端到端（拨号 → AI 开场白）则被完全堵死——边缘 audio_bridge 在商用 Windows 路径上根本无法 join RTC 房间。

A2 + D1 联合 MVP 的**唯一不可替代路径**就是把 ARTC SDK Windows C++ 接口对 Python 暴露。本 change 单点解决这件事。

## Goals / Non-Goals

**Goals**:

- 提供从 Python 调到 ARTC SDK for Windows native（C++）的 binding 层，**形状与 isales-common `audio/rtc.py::RtcSession` ABC 完全兼容**，使得 `audio_bridge` 可以像现在用 `MacosRtcSession` mock 一样切到 `WindowsRtcSession` 真实装
- 解锁 D1 §2.4（PyInstaller + ARTC 加载实测）→ §9.3（端到端联合 MVP）的唯一阻塞
- 把 D1 spec 中"Python wrapper"字面假设修正为"项目内 pybind11 binding"，避免归档时把错误假设带进 main spec
- 构建产物 `aliyun_artc_pywrap.pyd` 由 `deploy/edge/windows/build.ps1` 在 PyInstaller 之前 CMake build，被 PyInstaller spec 的 binaries glob 自动拾取——**单一构建命令体验保持不变**

**Non-Goals**:

- macOS ARTC SDK Python 绑定（A2 已决定 macOS 走 mock loopback；macOS SDK 是纯 Obj-C framework，需要 PyObjC 桥接，与 v1-roadmap "商用 = Windows / D1" 不符）
- Linux ARTC SDK 任何改动（已用官方 wrapper，arch-cloud-edge-split task 3 已 ship，本 change 不动）
- ARTC SDK 全 API 绑定：仅绑定 audio path 必需的 ~10 个函数 + 3 个 callback 接口；video / screenshare / 互动播放器 / cdn push 全部不绑
- 任何云端代码改动（纯边缘 change）
- EV 代码签名（D3 范围；`.pyd` 与主 exe 共用未来 D3 的签名流程）
- 性能极限调优：v1.0 单进程单 call 形态，binding 层只求"功能正确 + 满足 D1 §41 device-hardware P95 ≤ 50 ms SLA"；并发 / NUMA / lock-free queue 等留给后续

## Decisions

### Decision 1: 绑定技术栈 = pybind11 + CMake

**选项**:
- A. **pybind11** + CMake：业界主流，header-only，pythonic API（`py::class_<T>` / `py::init<>()`），自动 GIL 管理，社区好（scipy / PyTorch / Open3D 等都用）
- B. ctypes：纯 Python，无需 C++ 编译；但 ARTC SDK 暴露的是 C++ class（`AliEngine` 是抽象基类，需要 virtual function table + 构造函数），ctypes 几乎无法处理
- C. cffi：与 ctypes 类似，C-friendly 但 C++ 处理同样困难
- D. cppyy：Cling-based 真 C++ binding，但运行期 JIT、PyPI 包巨大、Windows 支持薄弱
- E. SWIG：能处理 C++，但 .i 文件维护重、生成代码不 pythonic、社区活跃度持续下降

**决策**: A（pybind11 + CMake）

**理由**:
- ARTC SDK 的核心入口 `AliRTCEngine* AliRtcEngine::create()` 返回**抽象基类指针**，回调通过 `IAudioFrameObserver` / `AliEngineEventListener` 等**纯虚类的 Python 端 override** 实现。pybind11 的 `py::class_` + trampoline 模式（`PYBIND11_OVERRIDE`）正好为此设计
- 团队已有 Python + C++ 工程师能维护；pybind11 的学习曲线低
- CMake 是 Aliyun SDK 文档推荐的集成方式（`add_library(AliRTCSdk SHARED IMPORTED)`），与 SDK 提供的 lib 配合自然
- 业界类似项目（如 Volcengine RTC Python wrapper 也用 pybind11）

### Decision 2: 绑定层 API 形状 = 严格对齐 isales-common `RtcSession` ABC

**问题**: pybind11 自然倾向暴露 C++ 类的镜像（`AliRtcEngine.create()` / `JoinChannel(channel, token, uid)` / `set_audio_frame_observer(observer)`）。但 iSales 架构里 `audio_bridge` 调的是更高层 `RtcSession`（join / leave / `async audio_frames()` iterator / `async push_audio(pcm, ts)`）。

**选项**:
- A. **绑定层只暴露 SDK 镜像，业务层 `WindowsRtcSession` 包一层适配为 `RtcSession` ABC**
- B. 绑定层直接暴露 `RtcSession` 形状的高层 API（C++ 内部封装 SDK）

**决策**: A

**理由**:
- 关注点分离：pybind11 binding 只管"C++ → Python"翻译，asyncio Queue / async iterator 等 Python 异步语义在 Python 侧组装，C++ 不引入 asyncio 依赖
- 测试边界清晰：binding 层用 GoogleTest 或纯 C++ 调用就能测；asyncio 桥接逻辑在 `WindowsRtcSession` 测，可用 mock 替换 `aliyun_artc_pywrap`
- 未来 SDK 升级或绑定层换技术栈（如换成 ctypes 子集）时，业务层 `WindowsRtcSession` 不变，调用方完全无感

### Decision 3: C++ 回调线程 → Python asyncio 的桥接 = thread-safe ring buffer + asyncio.Queue

**问题**: ARTC SDK 在内部 audio I/O 线程触发 `IAudioFrameObserver::onAudioFrame(...)` 回调（每 20 ms 一次，50 Hz），这个回调不是 Python 线程，也不在 asyncio loop 里。如何把 PCM frame 送回 `WindowsRtcSession.audio_frames()` 给 asyncio 消费？

**选项**:
- A. **C++ 回调 → C++ 侧 lock-free SPSC ring buffer → Python 端 asyncio task 周期性 drain (1 ms tick) → `asyncio.Queue`**
- B. C++ 回调直接 `pybind11::gil_scoped_acquire` + 调 Python callback → Python 侧 `loop.call_soon_threadsafe(queue.put_nowait, ...)`
- C. C++ 回调 → POSIX socket pair → Python 侧 `loop.add_reader(...)`

**决策**: A（带 fallback 到 B）

**理由**:
- A 把 GIL 释放窗口降到最低：C++ 回调线程**完全不持 GIL**，PCM frame 进 lock-free ring buffer；Python drainer task 在 asyncio loop 里持 GIL 把 frame 批量搬到 `asyncio.Queue`，吞吐高且无优先级反转
- B 的问题：每帧 50 Hz × `gil_scoped_acquire` 是非平凡开销；Linux SDK Python wrapper 实测 ~50 µs/帧 GIL 抢占，Windows 没有数据但同量级；高并发或竞争剧烈时会卡主 asyncio loop
- C 的问题：每帧多次内核态切换 + socket buffer copy，比 ring buffer 慢；且 Windows 上 `loop.add_reader` 仅支持有限 fd 类型
- **fallback**：如果 A 实现复杂度过高或带来其他风险，先用 B 跑通解锁 §9.3，B 的 50 µs GIL 开销在 v1.0 单 call 规模下仍可接受；profile 数据看 P95 是否守得住 50 ms SLA 再决定要不要切 A

### Decision 4: GIL 管理策略 = "C++ 不持，Python 侧显式获取"

- `aliyun_artc_pywrap.create_engine()`、`join_channel()`、`push_audio_frame()` 等同步调用：进入 C++ 时 `py::gil_scoped_release`，让 ARTC SDK 内部线程不与 Python 主线程互锁
- `IAudioFrameObserver::onAudioFrame()` C++ 回调实现：**不**通过 pybind11 trampoline 调 Python（避免 GIL 抢占），改为把 PCM 复制到 ring buffer 后立即返回；ring buffer drainer 在 Python 侧持 GIL
- `AliEngineEventListener::onJoinChannelResult(...)` 等低频事件回调：可以走 trampoline（`PYBIND11_OVERRIDE`）+ `py::gil_scoped_acquire`，事件率 < 10 Hz，GIL 开销可忽略

### Decision 5: C++ 对象生命周期 = `std::shared_ptr` + pybind11 `keep_alive`

- `AliRtcEngine` 对象由 `create()` 返回裸指针，**SDK 的析构语义是 `destroy()` 静态函数**（不是 `delete`）；pybind11 侧用 `std::shared_ptr<AliRtcEngine>` 包装并自定义 deleter 调 `AliRtcEngine::destroy(ptr)`
- `IAudioFrameObserver` / `AliEngineEventListener` 是回调对象，由 engine 持有引用：用 pybind11 `py::keep_alive<1, 2>()`（this 持有 observer 直到 this 销毁）防止 Python 端 GC 提前回收
- 显式 `WindowsRtcSession.close()` 路径：先 `unset_observer()` 再 `destroy_engine()`，避免回调线程在 engine 已 destroyed 时还来一发 frame

### Decision 6: 构建系统 = CMake + scikit-build-core，但 PyInstaller 用 pre-built `.pyd`

**问题**: pybind11 标准做法是 `setup.py` + `setuptools` 集成，让 `pip install .` 触发 CMake build。但 iSales Windows 构建链已经是 PowerShell + PyInstaller，引入 setup.py 会让构建流程分裂。

**选项**:
- A. **CMake 直接编译 → 产物 `aliyun_artc_pywrap.pyd` 拷到 `deploy/edge/windows/pybind/aliyun_artc_pywrap/aliyun_artc_pywrap.pyd` → PyInstaller spec `binaries` glob 拾取**
- B. setup.py + scikit-build-core → `pip install -e deploy/edge/windows/pybind/aliyun_artc_pywrap/` → 走 venv site-packages → PyInstaller 通过 `--collect-all aliyun_artc_pywrap` 收
- C. PyInstaller hook + scikit-build：让 PyInstaller 在打包阶段触发 CMake

**决策**: A

**理由**:
- 最简单：`build.ps1` 加两行 `cmake -S … -B build/pybind && cmake --build build/pybind --config Release`，产物拷到约定路径，PyInstaller spec 自动拾取
- 不污染 venv：开发期不需要 `pip install -e .`，IDE 直接通过 `sys.path` 找到 `.pyd` 即可（与 vendor SDK 同理）
- 与 vendor SDK 路径约定一致：vendor binaries 在 `deploy/edge/windows/vendor/aliyun-artc-windows/`，binding pyd 在 `deploy/edge/windows/pybind/aliyun_artc_pywrap/`，PyInstaller spec 两个 glob 一起拾取
- 不依赖 scikit-build-core 生态，少一个依赖项；C++ 工程师熟悉 CMake，多一层 setup.py 反而陡

**fallback**: 如果 Windows runner CI 集成期发现 CMake build artifact 拷贝路径管理混乱，可以转 B（scikit-build-core），但当前最简方案优先。

### Decision 7: CPython ABI 锁 = 与 PyInstaller frozen exe 一致的 Python 3.12.x

**问题**: `.pyd` 的 C ABI 与运行时 Python 解释器必须严格一致。PyInstaller frozen exe 内嵌的是 build 机器上的 Python 3.12.x。

**决策**: build.ps1 启动时**显式探测当前 Python 版本**（`python --version` 出 `Python 3.12.X`），把对应 `Python3_LIBRARY` / `Python3_INCLUDE_DIR` 传给 CMake；CI 矩阵把 Python 版本锁在 `3.12.x` 单一发行版。

**不采用 Py_LIMITED_API（stable ABI）**：pybind11 对 stable ABI 的支持仍处于实验性阶段（2.11 起部分支持），audio 回调路径的性能/兼容性风险大于收益；锁定 3.12 minor 版本更稳。

### Decision 8: VC Runtime 依赖 = PyInstaller `binaries` 节显式 collect

`AliRTCSdk.dll` 与 `aliyun_artc_pywrap.pyd` 都依赖 `msvcp140.dll` / `vcruntime140.dll` / `vcruntime140_1.dll`。用户 Windows 10/11 默认通常带 `VC++ 2015-2022 Redist`，但**不保证**。

**决策**: PyInstaller spec 的 `binaries` 节显式从构建机的 `C:\Windows\System32\` 拷 `msvcp140.dll` / `vcruntime140.dll` / `vcruntime140_1.dll` 进 frozen exe。零用户干预，比 `install.ps1` 检测后弹"请装 VC Redist" UX 好。

### Decision 9: D1 spec delta 修正 = 同 PR 修改 windows-client-core 的 spec 文件

**问题**: D1 `windows-client-core` 的 `specs/deployment-topology/spec.md` 字面写了"Python wrapper"。本 change 提案说要"修正 D1 字面假设"，但 D1 spec 在另一个 change folder 里，不能跨 change 直接改 spec delta（会破坏 archive merge）。

**决策**: 同一 PR 内**直接修改 D1 change folder 的 spec 文件**（D1 未归档，spec delta 是 mutable artifact），并在 D1 tasks.md 加一条注释说明"task 1.4 / 7.x 的 'Python wrapper' 措辞已由 windows-artc-pybind11 修正"。本 change 自己的 `specs/deployment-topology/spec.md` 在 D1 修正基础上增加 pybind11 相关 Requirement，归档顺序无关。

**风险**: 跨 change 修改 D1 文件，可能让 D1 的"任务进度 vs spec 当前文本"出现微小漂移；mitigation：D1 task 1.4 / 7.x 已经 ✅，修正只是文字，不影响进度判定。

## Risks / Trade-offs

| Risk | Mitigation |
|---|---|
| pybind11 trampoline + 50 Hz 回调下 GIL 抢占太重，audio loop P95 卡 | Decision 3 选 A（C++ ring buffer + Python drainer）；如 A 实现复杂或时间不够，先用 B 跑通 §9.3，profile 后再切 A |
| `.pyd` 与 frozen exe Python ABI 不匹配，运行时 `ImportError: dynamic module does not define module export function` | Decision 7 显式锁 Python 3.12.x；build.ps1 探测版本；CI 矩阵单一 Python；fail-fast 测试 `python -c "import aliyun_artc_pywrap"` 作为 build.ps1 最后一步 |
| ARTC SDK 7.6.0 → 后续版本 C++ ABI 变化，破坏 binding | 绑定只用 SDK 公开文档 API；vendor README 钉版本号；升级 SDK 需独立 PR 触发 D1 §2.4 / §9.3 重测 |
| 回调对象 use-after-free（observer 在 engine destroy 后还被调用） | Decision 5 严格 `unset_observer()` 先于 `destroy_engine()`；CMake 配 ASAN debug 模式跑冒烟；`WindowsRtcSession.close()` 加 sentinel state，二次调用 idempotent |
| C++ 工程量被低估（团队主要 Python 背景，pybind11 + CMake + MSVC C++17 + ARTC 文档对照），1 周变 2 周 | tasks.md 分 MVP scope（join/leave + audio observer 跑通）vs polish scope（event listener 完整 + 错误码精细化）；MVP 跑通即可解锁 §9.3，polish 推后 patch；不行就找外部 C++ 顾问 |
| VC Redist 在 frozen exe 内 bundle 触发 Microsoft 分发许可问题 | Decision 8 拷贝的 `msvcp140.dll` 等是 VC Redist 可再发行组件（Microsoft 官方许可允许 bundle 进应用程序）；保留许可证副本 `licenses/microsoft-vcredist-license.txt` |
| Windows runner CI 拉 vendor SDK（35 MB binaries）每次 build 都触发 OSS download 慢/超时 | CI cache vendor 目录 by SDK 版本 hash；本地 dev 一次下载长期复用；vendor README 注明 OSS bucket + 拉取脚本 |

## Migration Plan

本 change 是新增能力，没有破坏性 migration。部署顺序：

1. **构建机准备**：装 VS Build Tools 2022（C++ workload）+ CMake 3.20+ + Windows SDK 10.0.22621
2. **vendor SDK 就位**：`deploy/edge/windows/vendor/aliyun-artc-windows/{include,x64/Release}/` 解压完毕（PoC 周已完成）
3. **CMake 验证**：`cmake -S deploy/edge/windows/pybind/aliyun_artc_pywrap -B build/pybind` 配置成功
4. **本地 build 验证**：`cmake --build build/pybind --config Release` 产出 `aliyun_artc_pywrap.pyd`
5. **冒烟**：`python -c "import aliyun_artc_pywrap; print(aliyun_artc_pywrap.__version__)"` 不抛
6. **集成 build.ps1**：PyInstaller 前自动跑 CMake 阶段
7. **PyInstaller smoke**：frozen exe 启动后日志看到 `aliyun_artc_pywrap loaded` 行
8. **真 RTC join smoke**：（D1 §9.3 一部分）frozen exe 用真 AppId join 测试房间，看到 `OnJoinChannelResult` 回调

**rollback**: 本 change 不引入云端改动；如发现 binding 严重缺陷，回滚方案 = `WindowsRtcSession` 降级为 `MacosRtcSession` 同款 mock loopback（继续阻塞 §9.3，但不影响其他 D1 / A2 任务推进）。

## Open Questions

1. **Q**: pybind11 模块名最终定为 `aliyun_artc_pywrap` 还是 `isales_artc_windows_binding`？
   - **倾向**: `aliyun_artc_pywrap`（vendor/README.md 已用此名 + 与 SDK 厂商一致）；不取 `isales_*` 前缀是因为这层薄绑定不含 iSales 业务逻辑，未来可能被其他项目复用
2. **Q**: CMake 是否走 vcpkg 装 pybind11，还是 git submodule？
   - **倾向**: git submodule（pybind11 是 header-only 库，submodule 简单、版本可控；vcpkg 引入新工具链负担）；CMakeLists.txt 写 `add_subdirectory(deps/pybind11)`
3. **Q**: 绑定层是否需要把 ARTC SDK 的日志 callback (`OnAliEngineLog`) 也桥接到 Python logging？
   - **倾向**: MVP scope 不做（直接读 SDK 自己的日志文件即可，路径 `%TEMP%\AliRtcSdkLog`）；polish scope 加上，便于 D2 `hardware-observability` 统一日志收集
4. **Q**: 是否在 binding 层暴露 ARTC SDK 的网络质量回调（`OnNetworkQualityChanged`）供 D2 用？
   - **倾向**: 同上，polish scope；MVP 不阻塞
5. **Q**: 是否要给绑定层独立的 unit test CI job（跑 GoogleTest），还是合并进 windows-tests job？
   - **倾向**: 合并进 windows-tests job（一个 Windows runner 跑完所有 Windows 子集，CI minutes 友好）；GoogleTest 单跑在本地开发期可选
