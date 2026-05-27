## Why

A2 路径上 ECS smoke (`ecs_pcm_loopback_listen.py`) 始终 join 不通 RTC 房间。2026-05-25 session 把链路打穿后确认根因：vendor `AliRTCEngineImpl` 是 **Python ↔ TCP sidecar IPC 模型**，`InitializeEngine` 时注册的 `__recvCoroutine` 协程必须有持续 drive 的 asyncio loop 才能读 sidecar 响应；而当前 `_AliyunArtcChannel` wrapper 的 `_do_join` 是 `to_thread` 一次性 worker，调完 `_channel.join(...)` 就退出 → loop 被 GC → recvCoroutine 永不运行 → sidecar 实际从未把 `JoinChannel` 信令发出到 `gw.rtn.aliyuncs.com` → roomserver 静默 → wrapper 30s 超时。

ECS sidecar log 实证：18 个 HTTP 请求全部指向 httpdns，**0** 个指向 `gw.rtn.aliyuncs.com`；Python 端 `[Python] join channel begin...` 之后就静止。token v3.0 binary 算法已 byte-perfect 对齐 vendor sample，**不是** token 或 AppId/AppKey 启用问题——之前 commit 9f3968d 记录的 0x01037D81 来源待考证，**今天起这条不再是排查方向**。

这是 A2 路径 12 remaining task 里"真 Aliyun RTC join e2e"那条的核心 enabler；不解决则整个 cloud-edge RTC 媒体面无法跑通，A2 不能进 e2e 通话验收。

## What Changes

- 重构 `isales-engine/isales_engine/transport/aliyun_rtc.py` 与 `isales-engine/isales_engine/transport/_rtc_sdk.py` 中 `_AliyunArtcChannel` 的 SDK 调用线程模型
  - 引入**专用 SDK 驱动线程**：每个 `_AliyunArtcChannel` 实例在 `__init__` / `join` 入口 spawn 一个 daemon thread，thread 内 `set_event_loop(new_event_loop())` 后周期 pump（仿 vendor demo `sleepFor` 模式：`run_until_complete(asyncio.sleep(<short>))` 循环），给 vendor 注册的 `__recvCoroutine` 持续 drive 机会
  - 所有 vendor API 调用（`InitializeEngine` / `JoinChannel` / `LeaveChannel` / `PushAudioFrame` / `Destroy` 等）通过 thread-safe queue dispatch 到 SDK 驱动线程同步执行——vendor 内部 `run_until_complete(__writeData)` 因此能在该 thread 的 loop 内正常 fire
  - 现有"回调 marshal 回 main loop"方向（`OnJoinChannelResult` / `OnSubscribeAudioFrame` 通过 `self._loop.call_soon_threadsafe(self._main_handler)`）**保持不变**
  - 生命周期：`join` 入口启 SDK 线程；`leave` 信号退出 + `thread.join`；进程异常 `Destroy` 路径覆盖
- 既有外部 ABC（`isales_common.audio.rtc.RtcSession` 的 `join` / `leave` / `is_joined` / `audio_frames()` / `push_audio`）契约**不变**；只换内部 driver
- 不改 token 算法、不改 callback shape、不改 `audio_frames` AsyncIterator 的对外接口（PoC 跑通后 task 内验证 AsyncIterator + push_audio backpressure 在新模型下行为对齐）
- 新增 / 修订单元测试覆盖：drive 线程 spawn / shutdown / 异常下不泄漏；vendor mock 验证 dispatch queue 顺序
- ECS smoke `ecs_pcm_loopback_listen.py` 作为 e2e 验收 gate（必须看到 sidecar log 发请求到 `gw.rtn.aliyuncs.com` + Python 端 `OnJoinChannelResult` 回调 fire + 10s 录到回环 PCM）

## Capabilities

### New Capabilities
（无）

### Modified Capabilities
- `device-hardware`: 既有 Requirement"云端 isales-engine SHALL 在 `transport/aliyun_rtc.py` 中包装阿里 ARTC SDK for Linux Python"（来自 active change `arch-cloud-edge-split` 的 delta L195）规定了 wrapper 形状但**未约束 asyncio 集成模式**。本变更追加 Requirement，明确 wrapper MUST 用专用 SDK 驱动线程 + 周期 pump loop 模式承载 vendor `__recvCoroutine`，并经 ECS smoke e2e 验收 join 成功

## Impact

- **代码**：仅 `isales-engine`
  - `isales-engine/isales_engine/transport/aliyun_rtc.py` — 重构 `_AliyunArtcChannel` 主体
  - `isales-engine/isales_engine/transport/_rtc_sdk.py` — vendor SDK 调用入口、线程 / loop 持有
  - `isales-engine/tests/transport/` — 新增 / 修订 vendor mock 单元测试
- **配置 / 依赖**：无新增依赖（`threading` / `asyncio` / `queue` 全部 stdlib）；不动 ARTC SDK 版本 / 路径（仍 `/opt/isales/vendor/AliRTCSDK_Linux-7.10.2/Python`）
- **其他 sub-repo**：不动（`isales-common` / `isales-telephony` / `isales-api` / `isales-scheduler` / `isales-worker` / `isales-web` 全部 zero impact）
- **运行时**：每路 RTC session 额外 1 个 daemon thread；CPU overhead 由 pump period 决定（target 100ms 周期 ≈ vendor demo 节奏）
- **联动 active changes**
  - `arch-cloud-edge-split`：本变更是其 cloud-side ARTC SDK 集成的内部细化；不冲突
  - `windows-artc-pybind11` / `macos-artc-pyobjc`：纯 cloud-side 变更，边缘 binding 形态不动
  - `joint-mvp-gate-13301035545`：A2 e2e 验收前置依赖之一
- **风险**
  - 多并发 session 资源占用：每 session 1 daemon thread + 1 loop；v1.0 ≤8 路并发可承受（一台 ECS 上 ≤8 线程额外）
  - vendor 内部如有 `loop.run_until_complete(asyncio.sleep(...))` 之外的 long-running 协程注册，本模型仍能 pump（pump 周期就是给所有 ready task drive 机会）；如发现 vendor 在 init 后注册更多 long-running task，pump 周期可调短
  - 回退路径：保留 commit 7455cbf 作为 worktree branch base，重构 PoC 不通则 revert + 走 vendor pre-built sample app 对照重做
