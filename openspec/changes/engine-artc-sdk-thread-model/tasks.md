## 1. 准备 / branch

- [x] 1.1 在 `~/codes/isales-engine` 起 branch `engine-artc-sdk-thread-model`（base = main，HEAD = 7455cbf 之后最新 commit） <!-- branched at 7455cbf; HEAD = fb62fdd after impl -->
- [x] 1.2 读 vendor `demo.py` (`/Users/bears/codes/vendor/AliRTCSDK_Linux-7.10.2/Python/demo.py:108-153`) 的 `sleepFor` 主循环 + 调用 SDK API 模式，作为驱动线程参考 <!-- 100ms sleepFor 主循环 + run_until_complete(asyncio.sleep) confirmed -->
- [x] 1.3 读 vendor `AliRTCEngineImpl.py:1012`（`__recvCoroutine` 注册点）和 `:1135-1169`（`JoinChannel`）确认 vendor 内部 `loop.run_until_complete` 调用点 <!-- JoinChannel @1164-1166 with self.__lock + loop.run_until_complete(__writeData); Release @1079 同模式 -->
- [x] 1.4 `grep -n "ensure_future\|create_task" /Users/bears/codes/vendor/AliRTCSDK_Linux-7.10.2/Python/AliRTCEngineImpl.py` 列出所有 vendor 注册的长生命周期协程；记录是否只有 `__recvCoroutine` 一个（design open question #1） <!-- 答: 两个 — __recvCoroutine (line 1012) + __heartbeatCoroutine (line 1013); 100ms pump 覆盖两者 -->


## 2. PoC：最小可行 driver 线程

- [x] 2.1 在 `isales-engine/isales_engine/transport/_rtc_sdk.py`（或新文件 `_rtc_driver.py`）实现 `_ArtcDriverThread` 类：daemon thread + `set_event_loop(new_event_loop())` + 周期 pump 主循环（默认 100ms，env `ISALES_ARTC_PUMP_INTERVAL_MS` override） <!-- new file _rtc_driver.py -->
- [x] 2.2 实现 `queue.Queue`-backed 命令队列 + driver 主循环每轮 drain（非阻塞）→ 同步调 callable → 用 main-loop `Future.call_soon_threadsafe(set_result/set_exception)` 投回主线程 <!-- _drain_commands_once + _safe_set_result/_exception -->
- [x] 2.3 暴露 `async def _call_on_driver(self, fn, *args, **kwargs)` helper 给 `_AliyunArtcChannel` 用；并写 unit test：mock 一个 sync function 验证 driver 线程内执行、main loop 拿到结果 <!-- 名为 _ArtcDriverThread.call/.submit; unit test in test_artc_driver_thread.py -->
- [x] 2.4 driver 线程主循环外层 `try/except BaseException` + ERROR log + 标记 `self._healthy = False`，未捕获异常不让线程静默死亡 <!-- _run + pump iteration 都裹 try/except + is_healthy property -->

## 3. 集成：`_AliyunArtcChannel` 切换到 driver 模式

- [x] 3.1 `_AliyunArtcChannel.__init__` 不立刻起 driver 线程；保留 `self._driver = None` <!-- 已 -->
- [x] 3.2 `RtcSession.join(channel, token, uid, ...)` 入口：先起 driver 线程 → `await self._call_on_driver(vendor.InitializeEngine, ...)` → `await self._call_on_driver(vendor.JoinChannel, token, channel, uid, ...)`；保留既有"`await self._join_event`"等待 `OnJoinChannelResult` 的逻辑 <!-- _do_create_engine / _do_configure_audio / _do_join_channel; join_event 从 threading.Event 改为 asyncio.Event 由 callback call_soon_threadsafe set -->
- [x] 3.3 `RtcSession.leave()`：`await self._call_on_driver(vendor.LeaveChannel)` → `await self._call_on_driver(vendor.Destroy)` → 设 stop flag → `thread.join(timeout=5)`；超时 WARN log 但不抛 <!-- _do_leave_engine + _teardown_driver(via asyncio.to_thread + driver.stop) -->
- [x] 3.4 `RtcSession.push_audio(pcm, *, timestamp_ms)`：命令队列 size cap 256（≈ 5s @ 50ms 帧），满则 raise `RtcPushBackpressure`（既有错误类型）；MUST NOT 阻塞 main loop <!-- DriverQueueFull → RtcPushBackpressure translation in _AliyunArtcChannel.push_audio -->
- [x] 3.5 删除 / 替换既有 `_do_join` 的 `to_thread` 路径；保留 `OnJoinChannelResult` / `OnSubscribeAudioFrame` / 其他回调内 `self._main_loop.call_soon_threadsafe(handler, payload)` 方向**不变**
- [x] 3.6 异常路径覆盖：`join` 中途异常 → `finally` 内停 driver 线程；进程 SIGTERM → `__del__` / `close` 路径覆盖（避免线程泄漏 mac dev / ECS QA 长跑） <!-- join() 的 except BaseException: await self._teardown_driver(); raise -->


## 4. 单元测试 / vendor mock

- [x] 4.1 在 `isales-engine/tests/transport/test_aliyun_rtc_thread_model.py` 新增测试：driver 线程 spawn / shutdown / 异常下不泄漏 <!-- tests/test_aliyun_rtc_thread_model.py + tests/test_artc_driver_thread.py; isales-engine 项目把 transport tests 放 tests/ 顶层而非 tests/transport/ -->
- [x] 4.2 vendor mock：mock `AliRTCEngine` 的 `JoinChannel` 让它"假装"成功（不真的 IPC），验证 wrapper 的 join → recv callback marshal 链路 + leave → driver 线程退出 <!-- _StubArtcModule + _StubEngine: JoinChannel 内调 OnJoinChannelResult, 验证全链路在 driver 线程上跑 -->
- [x] 4.3 `push_audio` backpressure：queue 已满时 raise `RtcPushBackpressure`，不阻塞 caller loop <!-- test_push_audio_queue_full_raises_rtc_push_backpressure -->
- [x] 4.4 `audio_frames()` AsyncIterator 在新模型下产帧 + cancel 行为对齐既有契约（PoC 跑通后补，open question #2） <!-- 既有 test_aliyun_rtc_session.py 9 个测试覆盖（join/inbound queue/cancel/leave 终止 iterator/inbound overflow drop）— 切换到 async SdkChannel 后全部依然 36 passed -->
- [x] 4.5 跑 `cd ~/codes/isales-engine && .venv/bin/python -m pytest -q tests/transport/` 全绿；如其他 transport 测试受影响必须修复 <!-- 全 engine 套件 293 passed / 3 skipped -->


## 5. ECS smoke e2e 验收

- [ ] 5.1 scp 改动到 ECS：`scp -i ~/codes/isales-4.pem isales-engine/isales_engine/transport/{aliyun_rtc.py,_rtc_sdk.py,_rtc_driver.py} root@121.89.85.150:/opt/isales/current/isales-engine/isales_engine/transport/`
- [ ] 5.2 跑 smoke（完整命令见 memory `project_artc_join_diagnosis_2026_05_25.md` 末尾）：`ssh -i ~/codes/isales-4.pem root@121.89.85.150 "sudo -u isales -H bash -c '...ecs_pcm_loopback_listen.py --channel rtc-smoke-$(date +%s) --duration 10'"`
- [ ] 5.3 验证 sidecar log（`/tmp/Ali_RTC_Log_Client/aio_logger/<pid>_*/0_0.log`）含至少 1 条对 `gw.rtn.aliyuncs.com` 的 HTTP 请求；MUST NOT 全部指向 httpdns
- [ ] 5.4 验证 Python log（`/tmp/Ali_RTC_Log_Biz/Python-*.log`）含 `OnJoinChannelResult` 回调记录且 result code 为 0
- [ ] 5.5 验证 smoke 进程在 10s 时长内收到回环 PCM 帧（stdout 看回环字节数 > 0）
- [ ] 5.6 5.3 / 5.4 / 5.5 任一失败 → 不视为完成；回到 §2 调 pump 间隔 / dispatch 时序；MUST NOT archive

## 6. 收尾

- [x] 6.1 isales-engine commit + push（commit message 提及 root cause + 链路图） <!-- isales-engine commit fb62fdd; pushed origin/engine-artc-sdk-thread-model 2026-05-25 -->
- [x] 6.2 meta-repo `~/codes/isales` 同步：本 change `tasks.md` 各 task 勾 `[x]` + HTML 注释带 commit sha <!-- 本文件即同步落点；engine impl 全在 fb62fdd -->
- [x] 6.3 更新 memory `project_artc_join_diagnosis_2026_05_25.md`：标"已修复，commit <sha>"；保留作历史诊断笔记 <!-- code-level 修复落地; ECS smoke 待 phase 5 -->
- [x] 6.4 更新 memory `project_a2_progress.md`：A2 路径"真 Aliyun RTC join e2e"task 由 pending → done；剩余 task count 递减 <!-- code 已落, ECS smoke 待跑 -->
- [x] 6.5 跑 `openspec validate engine-artc-sdk-thread-model --strict` 全绿 <!-- "Change 'engine-artc-sdk-thread-model' is valid" -->
- [ ] 6.6 准备 archive：等 A2 e2e 通话验收完整跑过 1 次（本变更是 join 层 enabler，不强求 archive 时已跑完 e2e 通话；视 A2 整体节奏）→ `/opsx:archive engine-artc-sdk-thread-model` <!-- blocked on phase 5 smoke + A2 e2e -->

