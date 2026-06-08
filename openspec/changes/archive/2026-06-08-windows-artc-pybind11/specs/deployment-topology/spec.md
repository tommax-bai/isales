## ADDED Requirements

### Requirement: Windows ARTC SDK pybind11 binding 构建产物

Windows 边缘客户端 SHALL 在 PyInstaller 打包前通过 CMake 构建项目内 pybind11 binding，产出 `aliyun_artc_pywrap.pyd`，由 PyInstaller spec 文件的 `binaries` glob 自动拾取打包进 frozen exe；构建源码 SHALL 落在 isales-telephony 仓库的 `deploy/edge/windows/pybind/aliyun_artc_pywrap/`。本 Requirement 配合 D1 `windows-client-core` 已经写入的 "Windows 客户端依赖与打包" Requirement，补充 binding 构建环节。

D1 提案中"阿里 ARTC SDK for Windows Python wrapper"的字面描述 SHALL 在归档前由本 change 同 PR 修正为"阿里 ARTC SDK for Windows native binary + 项目内 pybind11 binding"——D1 spec delta 文件 `openspec/changes/windows-client-core/specs/deployment-topology/spec.md` 在三处（vendor 目录注释 / Windows-specific 依赖列表 / PyInstaller hidden imports 列表）字面措辞 SHALL 同步修正。

#### Scenario: vendor 与 pybind 目录布局

- **WHEN** Windows 客户端构建准备
- **THEN** `deploy/edge/windows/` 下 SHALL 同时存在：
  ```
  deploy/edge/windows/
    vendor/
      aliyun-artc-windows/         # gitignored，proprietary SDK
        include/                   # C++ headers
        x64/Release/               # AliRTCSdk.dll / .lib + 依赖 DLL
    pybind/
      aliyun_artc_pywrap/
        CMakeLists.txt             # 构建配置
        src/
          bindings.cpp             # pybind11 module 入口
          audio_observer.cpp       # IAudioFrameObserver 派生
          engine_listener.cpp      # AliEngineEventListener 派生
        deps/
          pybind11/                # git submodule，header-only
        tests/
          test_smoke.py            # 冒烟测试
        aliyun_artc_pywrap.pyd     # 构建产物（gitignored）
  ```
- `vendor/` 与 `pybind/` 平级；前者承载第三方 binaries，后者承载项目自有 binding 源码；二者都 gitignore 二进制产物

#### Scenario: CMake 构建步骤

- **WHEN** 执行 `deploy/edge/windows/build.ps1`
- **THEN** SHALL 在 PyInstaller 调用之前增加 CMake 构建阶段：
  1. 探测当前 Python 版本（`python --version` 应输出 `Python 3.12.X`），取得 `Python3_LIBRARY` 与 `Python3_INCLUDE_DIR`
  2. `cmake -S deploy/edge/windows/pybind/aliyun_artc_pywrap -B build/pybind -DPython3_EXECUTABLE=<path> -DCMAKE_BUILD_TYPE=Release`
  3. `cmake --build build/pybind --config Release --target aliyun_artc_pywrap`
  4. 拷贝 `build/pybind/Release/aliyun_artc_pywrap.pyd` 到 `deploy/edge/windows/pybind/aliyun_artc_pywrap/aliyun_artc_pywrap.pyd`
  5. fail-fast 冒烟：`python -c "import aliyun_artc_pywrap"` 不抛 ImportError / OSError
- 任一步骤失败 SHALL 立即终止 build.ps1（PowerShell `$ErrorActionPreference = "Stop"` 既有约定）；MUST NOT 让 PyInstaller 在缺 binding 时静默继续

#### Scenario: PyInstaller spec 调整

- **WHEN** PyInstaller 打包
- **THEN** `deploy/edge/windows/isales-telephony.spec` SHALL：
  - `binaries` 节 glob 增加 `deploy/edge/windows/pybind/aliyun_artc_pywrap/*.pyd`
  - `binaries` 节显式 collect 构建机 `C:\Windows\System32\` 中的 `msvcp140.dll` / `vcruntime140.dll` / `vcruntime140_1.dll`（VC Runtime 依赖）
  - `hiddenimports` 节移除"ARTC SDK Python wrapper 模块"项（不存在的官方 wrapper），新增 `aliyun_artc_pywrap`（项目内 pybind11 模块名）
- frozen exe 启动后 SHALL 能 `import aliyun_artc_pywrap` 成功；启动失败 MUST 落入日志 + tray 转红

#### Scenario: 构建环境要求

- **WHEN** 构建机准备
- **THEN** SHALL 至少安装：
  - Visual Studio Build Tools 2022（C++ workload 含 MSVC v143 编译器 + Windows SDK 10.0.22621）
  - CMake 3.20+
  - Python 3.12.x（与目标 frozen exe Python 版本一致）
  - pybind11 通过 git submodule 引入 `deps/pybind11`（MUST NOT 通过 vcpkg / pip 装），版本 SHALL 钉死在 `>= 2.11`
- macOS / Linux MUST NOT 强求满足上述构建要求（这些环境不构建 Windows binding；CI 矩阵中 Windows-only job 单独装）

#### Scenario: 运行时 Python ABI 锁

- **WHEN** binding 链接 / 加载
- **THEN** `aliyun_artc_pywrap.pyd` SHALL 链接与 PyInstaller frozen exe 内嵌完全一致的 Python ABI（v1.0 锁 Python 3.12.x，CI 矩阵单一 Python 发行版）；MUST NOT 使用 `Py_LIMITED_API`（stable ABI 在 audio 高频回调路径上风险高）；运行时如 `import aliyun_artc_pywrap` 抛 `ImportError: dynamic module does not define module export function` MUST 视为构建配置错误，立即修构建脚本而非 runtime workaround

#### Scenario: vendor SDK 版本钉死

- **WHEN** vendor SDK 升级
- **THEN** 升级 ARTC SDK 版本 SHALL 走独立 PR，PR 内 SHALL：
  - 更新 `deploy/edge/windows/vendor/README.md` 中记录的 SDK 版本号
  - 重跑 D1 §2.4（PyInstaller + ARTC 加载实测）
  - 重跑 D1 §9.3（端到端联合 MVP）
  - 如 SDK C++ ABI 变化导致 binding 源码需修，本 change 的 spec delta 不变（只是实施细节），但 PR 描述 SHALL 列出影响的 C++ 接口
- vendor 目录本身 SHALL 保持 gitignored（35 MB binaries 不进 git）；CI Windows runner SHALL 通过 OSS 私有 bucket 拉取 vendor 压缩包，credential 走 GitHub secret；vendor cache 按 SDK 版本 hash 命名以避免每次 build 重下载
