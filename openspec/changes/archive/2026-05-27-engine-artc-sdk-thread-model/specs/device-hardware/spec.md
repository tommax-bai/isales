## ADDED Requirements

### Requirement: 云端 isales-engine `transport/aliyun_rtc.py` 通过专用 SDK 驱动线程承载 vendor recvCoroutine

云端 isales-engine 的 `_AliyunArtcChannel`（`isales-engine/isales_engine/transport/aliyun_rtc.py` + `isales-engine/isales_engine/transport/_rtc_sdk.py`）SHALL 用**专用 SDK 驱动线程 + 周期 pump asyncio loop** 的模式承载 vendor `AliRTCEngineImpl` 内 `InitializeEngine` 时注册的 `__recvCoroutine`，以驱动其持续读 sidecar (`AliRtcCoreService`) TCP socket 响应；MUST NOT 用 `asyncio.to_thread` 一次性 worker、纯 `loop.run_forever()` 后 `call_soon_threadsafe` vendor API、或任何让 vendor 注册的长生命周期协程失去 drive 机会的模式。

本 Requirement 服务于诊断结论 (memory `project_artc_join_diagnosis_2026_05_25.md`)：vendor SDK 是 Python ↔ TCP sidecar IPC 模型，`__recvCoroutine` 不被 drive 时 sidecar 实际不会把 `JoinChannel` 信令发出到 `gw.rtn.aliyuncs.com`，roomserver 静默，wrapper 30s 超时；本 Requirement 之前 ECS smoke 始终 join 不通。

#### Scenario: `_AliyunArtcChannel` 在 `join()` 入口起 driver 线程，`leave()` 信号停

- **WHEN** `RtcSession.join(channel, token, uid, *, send_sample_rate, send_channels)` 被调用
- **THEN** `_AliyunArtcChannel` SHALL 起一个 daemon thread（命名 `artc-driver-<call_id>` 便于诊断）；thread 内 SHALL `asyncio.set_event_loop(asyncio.new_event_loop())` 创建独立 loop；MUST NOT 复用调用方 main loop
- **WHEN** `RtcSession.leave()` 被调用 或 `_AliyunArtcChannel.close()` / `__del__` 触发
- **THEN** SHALL 设 stop flag → driver 线程退出主循环 → `thread.join(timeout=5)` 等待；超时 SHALL log WARN 不抛硬错

#### Scenario: driver 线程周期 pump loop 给 recvCoroutine drive 机会

- **WHEN** driver 线程主循环每轮迭代
- **THEN** SHALL 调用 `loop.run_until_complete(asyncio.sleep(pump_interval))`，pump_interval 默认 SHALL 为 100ms（与 vendor demo `sleepFor(0.1)` 一致）；环境变量 `ISALES_ARTC_PUMP_INTERVAL_MS` SHALL 允许 override 默认值
- **WHEN** vendor `__recvCoroutine` 在该周期内收到 sidecar 响应
- **THEN** SHALL 在同一 driver 线程的 loop 内正常被 drive；vendor 回调（`OnJoinChannelResult` / `OnSubscribeAudioFrame` 等）SHALL 通过 `main_loop.call_soon_threadsafe(handler, payload)` marshal 回 main loop

#### Scenario: vendor SDK API 调用通过命令队列 dispatch 到 driver 线程

- **WHEN** 外线程需要调 vendor API（`InitializeEngine` / `JoinChannel` / `LeaveChannel` / `PushAudioFrame` / `Destroy` 等）
- **THEN** SHALL 通过 thread-safe 命令队列把 callable 投递给 driver 线程，由 driver 线程在 pump 周期间隙同步执行；vendor 内部 `loop.run_until_complete(__writeData(...))` SHALL 因此能在该 driver 线程的 loop 内正常 fire；MUST NOT 在外线程直接调 vendor sync API（会撞 `RuntimeError: This event loop is already running` 或导致 socket 读写并发）
- 命令调用方 SHALL 拿到一个 main-loop `asyncio.Future`，`await` 它取结果或异常；MUST NOT 用阻塞 `Future.result()`（会卡死 main loop）

#### Scenario: `push_audio` 在命令队列繁忙时 raise `RtcPushBackpressure`

- **WHEN** `RtcSession.push_audio(pcm, *, timestamp_ms)` 被调用且命令队列已达上限（默认 256，≈ 5s @ 50ms 帧）
- **THEN** SHALL raise 既有 `RtcPushBackpressure` 错误类型（与 `WindowsRtcSession` / `MacosArtcPyObjCSession` 失败模式对齐）；MUST NOT 阻塞 main loop 等队列容量

#### Scenario: driver 线程未捕获异常不让 session 静默死亡

- **WHEN** driver 线程主循环内任何非预期异常逃出 `try`
- **THEN** SHALL ERROR log（含 stack）+ 设置 session 不健康标记；上层 engine session loop SHALL 可观察该标记并走主动 leave / `RtcError` 上报路径；MUST NOT 让 driver 线程静默死亡导致 session 表面"还活着"但实际不收 sidecar 响应

#### Scenario: ECS smoke 端到端验收 join 真发出且 callback fire

- **WHEN** 在 ECS（`121.89.85.150`）跑 `isales-engine/scripts/ecs_pcm_loopback_listen.py --channel rtc-smoke-<ts> --duration 10` smoke
- **THEN** sidecar log（`/tmp/Ali_RTC_Log_Client/aio_logger/<pid>_<datetime>_<ts>/0_0.log`）SHALL 含至少一条对 `gw.rtn.aliyuncs.com` 的 HTTP 请求；Python 层 log（`/tmp/Ali_RTC_Log_Biz/Python-<datetime>.log`）SHALL 含 `OnJoinChannelResult` 回调记录且 result code 为 0；smoke 进程 SHALL 在 10s 时长内收到回环 PCM 帧
- **WHEN** smoke 任一断言失败
- **THEN** 本变更 MUST NOT 视为完成；MUST NOT archive

#### Scenario: 不破坏 RtcSession ABC 与边缘形态

- **WHEN** 本变更落地后任何调用方查询
- **THEN** `isales_common.audio.rtc.RtcSession` ABC（`join` / `leave` / `is_joined` property / `audio_frames()` async iterator / `push_audio`）SHALL **NOT** 被修改
- `isales_telephony/audio_bridge/windows_rtc_session.py::WindowsRtcSession`（`windows-artc-pybind11` 实装）SHALL **NOT** 被修改
- `isales_telephony/audio_bridge/macos_artc_pyobjc.py::MacosArtcPyObjCSession`（`macos-artc-pyobjc-binding` 实装）SHALL **NOT** 被修改
- `isales_telephony/audio_bridge/session.py::MacosRtcSession`（同进程 loopback mock）SHALL **NOT** 被修改
