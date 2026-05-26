## ADDED Requirements

### Requirement: 三端 DingRTC 3.9.0 vendor SDK 落点与下载源

iSales 三端（cloud Linux engine / Windows edge / macOS edge）SHALL 统一使用 **DingRTC 3.9.0** vendor SDK（来源 `dingrtc.oss-cn-zhangjiakou.aliyuncs.com`，2025-04-15 release），取代既往三端使用的 ApsaraVideo Live 产品线下 ARTC SDK；三端 SDK MUST 同 minor 同 patch 以保证 vendor 互通契约。

#### Scenario: 三端 vendor SDK 下载源与落点

- **WHEN** 部署 / 开发环境装载 vendor SDK
- **THEN** SHALL 按下表从 DingRTC OSS 拉取：

  | 接入点 | SDK 文件 | CDN 直链 | 解压目标 |
  |---|---|---|---|
  | Cloud Linux engine | `DingRTC_Linux_SDK_3_9_0.zip` (C++) | `https://dingrtc.oss-cn-zhangjiakou.aliyuncs.com/sdk/linux/3.9.0/DingRTC_Linux_SDK_3_9_0.zip` | `/opt/isales/vendor/DingRTC_Linux_SDK_3_9_0/` |
  | Windows edge | `DingRTC_Windows_SDK_3_9_0.zip` (`DingRTC.dll`) | `https://dingrtc.oss-cn-zhangjiakou.aliyuncs.com/sdk/windows/3.9.0/DingRTC_Windows_SDK_3_9_0.zip` | `C:\Users\<user>\codes\vendor\DingRTC_Windows_SDK_3_9_0\` |
  | macOS edge | `DingRTC_macOS_SDK_3_9_0.zip` (`DingRTC.framework`) | `https://dingrtc.oss-cn-zhangjiakou.aliyuncs.com/sdk/mac/3.9.0/DingRTC_macOS_SDK_3_9_0.zip` | `~/codes/vendor/DingRTC_macOS_SDK_3_9_0/` |

- vendor 二进制 / 头文件 / 文档 SHALL **NOT** 进任何 git 仓库；三端解压路径 SHALL 在 `.gitignore` 覆盖
- 解压路径 SHALL 通过环境变量 override：`ISALES_DINGRTC_LINUX_SDK_PATH` / `ISALES_DINGRTC_WINDOWS_SDK_PATH` / `ISALES_MACOS_DINGRTC_FRAMEWORK_PATH`

#### Scenario: cloud-side install script 自动化下载

- **WHEN** 跑 `deploy/cloud/scripts/install.sh` 或等价部署脚本
- **THEN** SHALL 包含 `install-dingrtc-sdk` 步骤（取代既有 `install-artc-sdk`）：从 DingRTC OSS 拉取 `DingRTC_Linux_SDK_3_9_0.zip` → 校验 sha256（值 SHALL 在 `deploy/cloud/STATE.md` § "DingRTC SDK vendor" 钉死）→ 解压到 `/opt/isales/vendor/DingRTC_Linux_SDK_3_9_0/`
- 装载 pybind11 binding 编译依赖：`apt install build-essential cmake python3-dev` + `pip install pybind11`；编译 `isales-engine/isales_engine/transport/dingrtc/` → 产 `dingrtc_pywrap.so`

#### Scenario: Windows PyInstaller 打包路径

- **WHEN** 跑 `isales-telephony/deploy/edge/windows/build.ps1` PyInstaller 构建
- **THEN** PyInstaller spec SHALL：
  - `binaries` 段显式包含 `DingRTC.dll`（取代 `AliVCSDK_ARTC.dll` / `AliRTCSdk.dll`）
  - `binaries` 段显式包含项目内 pybind11 binding 产物 `dingrtc_pywrap.pyd`（取代 `aliyun_artc_pywrap.pyd`）
  - `hiddenimports` 段包含 `dingrtc_pywrap`（取代 `aliyun_artc_pywrap`）
- vendor 路径文档（`STATE.md`）SHALL 同 PR 更新；MUST NOT 同时保留两套 SDK（构建结果含两套 dll → 互通行为不确定）

#### Scenario: macOS dev/QA 启动指令

- **WHEN** dev 同学在 mac 工作机上启动真 RTC dev/QA 形态
- **THEN** 启动步骤 SHALL 改为：
  1. 解压 `DingRTC_macOS_SDK_3_9_0.zip` 到 `~/codes/vendor/DingRTC_macOS_SDK_3_9_0/`（vendor 不进 git）
  2. `pip install -e '.[dev,macos,macos-artc]'`（extras 名 `macos-artc` 保持向后兼容）
  3. `isales-telephony-edge --cloud-endpoint 121.89.85.150:50051 --edge-token-file <jwt> --dev-no-modem --dev-channel <demo-id> --dev-uid mac-dev-01`
- 启动后 edge 通过 PyObjC 加载 `DingRTC.framework` → `MacosDingRtcPyObjCSession` 真 join DingRTC 3.x 房间 → cloud engine 看到 edge 是真 DingRTC peer

#### Scenario: 三端 SDK 版本一致性 lint

- **WHEN** CI / `make spec-validate` / 任何 PR 提交
- **THEN** SHALL 跨 5 个数据源对账 DingRTC SDK 版本号（`isales-engine` pyproject + `isales-telephony` pyproject + `deploy/cloud/STATE.md` + `isales-telephony/deploy/edge/windows/STATE.md` + `isales-telephony/deploy/edge/macos/RUNBOOK.md`）；版本不一致 SHALL 阻断 PR 合并
- 任何升 DingRTC minor / patch SHALL 三端同 PR；MUST NOT 单端升

#### Scenario: 既有 ApsaraVideo Live ARTC SDK 路径清理

- **WHEN** 本变更落地
- **THEN** `deploy/cloud/STATE.md` § "ARTC SDK vendor" SHALL 重命名为 "DingRTC SDK vendor"；既有 `AliRTCSDK_Linux-7.10.2` vendor 路径 / OSS URL / 解压指令 SHALL 全部替换为 DingRTC 等价值
- `isales-telephony/deploy/edge/windows/STATE.md` 既有 `AliVCSDK_ARTC-7.6.0` 路径 + dll 名 SHALL 同步更新
- `isales-telephony/deploy/edge/macos/RUNBOOK.md` 既有 `AliRTCSdk_macos/AliRTCSdk.framework` 路径 + env var 名 SHALL 同步更新
- `deploy/RUNBOOK-cloud.md` cloud-side SDK 装载步骤 SHALL 同步更新
- ECS 上既有 vendor 路径（`/opt/isales/current/vendor/aliyun-artc-linux-python/` 或类似）SHALL 在新 SDK 上线后人工清理（避免磁盘占用）

#### Scenario: vendor 下载域名识别

- **WHEN** 任何 dev / ops 引用 RTC SDK 下载页
- **THEN** SHALL 通过下载域名识别产品线归属：
  - `dingrtc.oss-cn-zhangjiakou.aliyuncs.com` = **DingRTC 3.x（RTC PaaS）** ← iSales 唯一使用
  - `alivc-demo-cms.alicdn.com/versionProduct/sdk/` = **ApsaraVideo Live（视频直播）下的 ARTC SDK** ← MUST NOT 使用（与 DingRTC 房间不互通）
  - `help-static-aliyun-doc.aliyuncs.com` = **AliRTC 2.x（已淘汰）** ← MUST NOT 使用
- 文档引用 vendor 链接 SHALL 标注产品线归属，避免下次再选错（[[feedback_isolate_with_vendor_sample]]）
