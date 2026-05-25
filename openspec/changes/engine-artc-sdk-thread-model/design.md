## Context

`isales-engine/isales_engine/transport/aliyun_rtc.py` 包装 vendor `AliRTCSDK_Linux-7.10.2/Python/AliRTCEngineImpl.py`，作为 cloud-side engine 加入 Aliyun RTC PaaS 房间的入口。vendor SDK 的实际架构是 **Python 调用层 ↔ TCP sidecar (`AliRtcCoreService` C++ binary)**：

```
Python (AliRTCEngineImpl.py) ←── TCP socket localhost ──→ AliRtcCoreService sidecar
        ↑                                                       ↓
   InitializeEngine 时                                    DNS / NTP / signaling
   asyncio.ensure_future(                                 → gw.rtn.aliyuncs.com
   __recvCoroutine(reader))
```

`__recvCoroutine`（`AliRTCEngineImpl.py:1012`）是一个**长生命周期** `async for` 循环，持续从 sidecar TCP socket 读响应并 dispatch 到 callback；只有 loop 在 drive 时它才能跑。

vendor 自己的 `demo.py` (`/Users/bears/codes/vendor/AliRTCSDK_Linux-7.10.2/Python/demo.py:108-153`) 主循环模式：

```python
loop = asyncio.new_event_loop()
asyncio.set_event_loop(loop)
def sleepFor(s):
    loop.run_until_complete(asyncio.sleep(s))
# 主循环
while not done:
    sleepFor(0.1)   # ← 每 100ms pump 一次 loop，给 recvCoroutine 机会
```

每个 vendor SDK API 内部（`JoinChannel` 等）也都 `loop.run_until_complete(__writeData(...))` — 写完就让 loop 退出，等下次 `sleepFor` 把 recvCoroutine drive 起来。

**当前 wrapper（commit 7455cbf 之后）违反了这一假设**：`_do_join` 是 `asyncio.to_thread` worker，函数体内 `set_event_loop(new_event_loop())` 后调一次 `_channel.join(...)` 就 return → worker thread 退出 → 新建的 loop 被 GC → `__recvCoroutine` 永远没机会 drive → sidecar 实际没把 `JoinChannel` 信令发出。

ECS smoke 实证：sidecar log 里 18 个 HTTP 请求全部指向 httpdns 端点，**0** 个指向 `gw.rtn.aliyuncs.com`（Aliyun roomserver 信令网关）；Python 端 `[Python] join channel begin...` 之后就静止 30s 直至我们 wrapper 自己超时。

之前 memory commit `9f3968d` 记录的 `RTC join 0x01037D81` 经今天复盘**很可能不是 Aliyun roomserver 错误码**，因为请求根本没出去；具体来源待考证（早期 vendor enum / 其他 ret 非零路径），但**今天起这条不再是排查方向**。

## Goals / Non-Goals

**Goals:**

- `_AliyunArtcChannel` 内部具备一个持续 drive vendor recvCoroutine 的 asyncio loop，方式与 vendor demo 等价
- vendor SDK API 调用 dispatch 到该 loop 所在线程同步执行，避免线程不一致导致的 `RuntimeError: This event loop is already running` 或 socket 读写并发问题
- 既有 `RtcSession` ABC（`join` / `leave` / `is_joined` / `audio_frames` / `push_audio`）对外契约不变；调用方（engine session、audio_pipe）零修改
- ECS smoke `ecs_pcm_loopback_listen.py` 必须看到 sidecar HTTP 请求打到 `gw.rtn.aliyuncs.com` + Python 端 `OnJoinChannelResult` 回调正常 fire + 10s 录到回环 PCM

**Non-Goals:**

- 不改 vendor SDK 源码（vendor 是商业 binary + Python wrapper，仅消费）
- 不改 token mint 算法（v3.0 binary 已 byte-perfect 对齐 vendor sample）
- 不改 `RtcSession` ABC 对外形状（`isales-common/isales_common/audio/rtc.py`）
- 不动其他 sub-repo（telephony / common / api / scheduler / worker / web）
- 不引入 thread pool / process pool：每路 session 一个 daemon thread 足够（v1.0 ≤8 路并发）
- 不优化 pump 周期到次毫秒：100ms 即 vendor demo 同节奏，足够 join 信令往返

## Decisions

### Decision 1：单线程 + 周期 pump（仿 vendor demo）vs `loop.run_forever()`

**选**：单线程 + 周期 pump（`while not stop: loop.run_until_complete(asyncio.sleep(N/1000))`）

**理由**：
- vendor SDK 内部很多 API 用 `loop.run_until_complete(...)` 模式（既然他们 demo 这样写，证明 SDK 内部依赖这种"loop 不在 run state 时才能 run_until_complete"前提）
- 如果用 `loop.run_forever()`，外部线程要调 vendor API 时只能 `call_soon_threadsafe`，但 vendor 内部的 `run_until_complete` 会撞上 `RuntimeError: This event loop is already running`
- 周期 pump 在 100ms 节奏下 CPU overhead 可忽略（`asyncio.sleep` 期间 loop selector 处于 epoll/kqueue wait 状态，不忙等）

**Alternatives considered**：
- `loop.run_forever()` + `run_coroutine_threadsafe`：撞 vendor `run_until_complete`（如上）
- 让调用方（engine session）自己持有 RTC loop：违反封装；调用方对 vendor 内部模型不应该感知
- 用 thread pool：每路 session 单独 1 个线程已经足够（v1.0 ≤8 并发），pool 增加复杂度

### Decision 2：SDK 调用从外线程 dispatch 到 driver 线程的机制

**选**：`queue.Queue`-backed 命令队列 + driver 线程 pump loop 间隙 drain queue

driver 线程主循环：
```python
def _driver_loop(self):
    asyncio.set_event_loop(self._loop)
    while not self._stop.is_set():
        # 1. drain command queue（非阻塞）
        while True:
            try:
                cmd, fut = self._cmd_q.get_nowait()
            except queue.Empty:
                break
            try:
                result = cmd()   # cmd 内可能调 vendor API（含 run_until_complete）
                self._main_loop.call_soon_threadsafe(fut.set_result, result)
            except BaseException as exc:
                self._main_loop.call_soon_threadsafe(fut.set_exception, exc)
        # 2. pump loop（给 recvCoroutine drive 机会）
        self._loop.run_until_complete(asyncio.sleep(self._pump_interval))
```

外线程调 vendor API 通过 helper：
```python
async def _call_on_driver(self, fn, *args, **kwargs):
    fut = self._main_loop.create_future()
    self._cmd_q.put_nowait((lambda: fn(*args, **kwargs), fut))
    return await fut
```

**理由**：
- `queue.Queue` 是 GIL-safe，跨线程 enqueue / drain 无需额外锁
- 把 cmd 包成 `Callable[[], Any]` + main-loop `Future`，外部 `await` 体验和 `run_in_executor` 接近
- 命令在 driver 线程的 loop 内执行，vendor 的 `run_until_complete` 因此能跑

**Alternatives considered**：
- `asyncio.run_coroutine_threadsafe(coro, self._loop)`：要求 coro，但 vendor API 是 sync function 内嵌 `run_until_complete`，不能直接做 coro
- `concurrent.futures.ThreadPoolExecutor`：每个 task 起一次线程，无法复用 driver 线程的 loop / recvCoroutine 注册

### Decision 3：回调方向（vendor → wrapper）仍走 `call_soon_threadsafe` 到 main loop

**选**：保持现状不变（`OnJoinChannelResult` / `OnSubscribeAudioFrame` / 其他事件回调内 `self._main_loop.call_soon_threadsafe(self._handler, payload)`）

**理由**：
- 回调由 driver 线程的 `__recvCoroutine` 在 pump 周期内触发；handler 想 await / 想 marshal 到上层 session loop 必须 `call_soon_threadsafe`
- 这部分今天 7455cbf 已 OK，无需重做

### Decision 4：pump 周期默认值

**选**：100ms（与 vendor demo `sleepFor(0.1)` 相同）

**理由**：
- vendor sample 用 100ms 跑通商用通话，证明对信令往返 + 音频 callback 节奏足够
- 100ms 对 join 信令（一次往返 < 1s）感知不到延迟
- 后续音频 callback 由 sidecar 主动推（不依赖 pump 速率），pump 只是给 `__recvCoroutine` drive 机会
- 通过 env var `ISALES_ARTC_PUMP_INTERVAL_MS` 允许 override 调优（不进 spec，作 ops knob）

### Decision 5：线程生命周期与 `_AliyunArtcChannel` 实例对齐

**选**：`_AliyunArtcChannel.__init__` 不立刻起线程；`join()` 入口起线程；`leave()` 信号停 + `thread.join(timeout=5)`

**理由**：
- `__init__` 后可能因为 token mint 等异步前置失败 → 那种情况不该有线程在跑
- 显式生命周期边界 = `join` ↔ `leave` 对称
- 异常路径：`join` 中途异常 → `finally` 内停线程；`Destroy` 路径覆盖（避免线程泄漏 mac dev / ECS QA 长跑）

## Risks / Trade-offs

- **每路 session 1 daemon thread**：v1.0 ≤8 路并发上 + 8 个线程；ECS 4C8G 可承受。v2+ 高并发要复评，可能改 thread pool + 共享 SDK 实例（但 vendor 是否支持单实例多 channel 待 vendor 文档确认）→ **缓解**：v1.0 内仅每 session 1 线程
- **pump 周期下 vendor 长协程**：如发现 vendor 在 init 后注册其他 long-running task（不只 `__recvCoroutine`），pump 周期可能不够 → **缓解**：env var 调短到 50ms；监控 Python 层 log 是否漏 callback
- **driver 线程内未捕获异常**：若 `run_until_complete(asyncio.sleep)` 之外的代码抛异常，driver 线程会死 → recvCoroutine 停 drive → session 静默 → **缓解**：driver 主循环外层 `try/except BaseException` + ERROR log + 标记 session 不健康，主上层 session loop 可观察
- **回退**：本变更前的 commit `7455cbf` 已经能过 init 但不通 join；如本变更 PoC 跑通仍卡新 failure，退回 7455cbf 后从 vendor pre-built sample app `demo.py` 重做对照实验

## Migration Plan

无 schema / 配置迁移。代码层切换：

1. 在 isales-engine 上分 branch；改 `transport/aliyun_rtc.py` + `transport/_rtc_sdk.py`
2. 单元测试 / vendor mock 测试先绿
3. scp 改动到 ECS（路径见 memory `project_artc_join_diagnosis_2026_05_25.md` 末尾的 smoke 命令）
4. 跑 `ecs_pcm_loopback_listen.py` smoke；看 sidecar log 是否打 `gw.rtn.aliyuncs.com` + Python `OnJoinChannelResult` 回调
5. smoke 绿后正式 commit + push isales-engine；meta-repo 同步勾 `tasks.md` checkbox
6. 回滚：`git revert` + 同步 deploy

## Open Questions

- vendor `__recvCoroutine` 之外有没有其他 init 后注册的长协程？需要在 PoC 跑通后 grep `AliRTCEngineImpl.py` 确认（搜 `ensure_future` / `create_task`）。如有，影响 pump 周期下限
- `audio_frames()` AsyncIterator 在新模型下是否需要调整 marshal 方向？预期不需要（callback 已 `call_soon_threadsafe` 回 main loop），但 PoC 跑通后 must 验证
- `push_audio` 在 driver 线程繁忙时的 backpressure 表达：目前 vendor `PushAudioFrame` 是同步函数；命令队列大小是否要 cap？建议 256（≈ 5s @ 50ms 帧）；超出 raise `RtcPushBackpressure`（已存在的错误类型）
- 多 session 共享一个 driver 线程的可行性留 v2：vendor `AliRTCEngineImpl` 是否支持单实例多 channel 待文档确认；v1.0 不冒险
