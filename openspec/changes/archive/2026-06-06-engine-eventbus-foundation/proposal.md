## Why

isales-engine 的「通话内协调」目前是手工接线的：两条 `asyncio.Queue`（finals/partials）+ 两个 `asyncio.Event`（hangup/asr_finished）+ 跨任务 reach-across 的 `session.current_speaking_task.cancel()` + `request_manual_hangup` 的 `main.cancel()` sentinel hack。更要命的是 pump 里**没有异常隔离**——一个未捕获异常会让整条 pump 静默暴毙（2026-05-31/06-05「电话→AI 没通」一类：`bridge.py` 一抛 `RtcError` 整条上行 pump 死）。

`engine-flat-refactor-blueprint.md` 的扁平化重构需要一个**类型化的进程内事件底座**作为后续多路 SelectRouter + 状态投影的基础。本 change 是该重构的**第 1 步(地基)**：引入双车道 EventBus + 信号事件词表，并把现有协调原语迁移到事件上——**行为逐字节不变**（由 change-0 的 golden-transcript 网兜底）。

## What Changes

- **新增进程内双车道 `EventBus`**（`isales_engine/eventbus.py`，port 自 voxen `core/eventbus`）：
  - **无损道**（unbounded `asyncio.Queue`，`put_nowait` 物理上不丢）承载 ASR final / 打断 / 挂断 / lifecycle —— **一句用户 final 绝不能丢**（voxen 统一 drop-oldest 在此是灾难）。
  - **有损道**（bounded，drop-oldest，voxen 语义）承载 ASR partial / 音频 / VAD。
  - **每-handler 异常隔离**（try/except，`CancelledError` 重抛）——根治上述「一抛异常整 pump 死」类。
  - 每车道一个 dispatcher 协程(车道内串行、跨车道并发);单 CallSession 作用域;`drain_inline()` 供测试确定性回放。
- **新增信号事件词表**（`isales_engine/events.py`，`@dataclass(slots=True, frozen=True)`）：`AsrFinal` / `AsrPartial` / `AsrStreamEnded` / `Connected` / `HangupDetected` / `InterruptRequested` / `ManualHangupRequested` / `TransferRequested` / `VadFrame`。与 pydantic `EngineEvent` Redis-wire 联合**刻意分离**（热路径不过 pydantic）。
- **迁移协调原语为 bus producer/subscriber**（Phase 1）：`_asr_pump`/`_ev_pump` post `AsrFinal`/`AsrPartial`/`HangupDetected`；`_partial_monitor`/`_vad_monitor` post `InterruptRequested`(取代 reach-across cancel,改 playback owner 自取消);`_main_turn_loop` **消费端逐字节不变**(经 bridge subscriber 把 bus 事件喂回现有队列,保 golden 不动)。
- **不替代 Redis**：Redis 仍是跨服务边界;EventBus 是**新的进程内通道**,在 service-communication spec 登记一条(渠道纪律要求)。

## Capabilities

### New Capabilities
<!-- 无新增 capability -->

### Modified Capabilities
- `service-communication`: 新增「进程内 EventBus 通道」Requirement —— 双车道(lossless 永不丢 / lossy drop-oldest)、单 CallSession 作用域、永不跨进程、每-handler 异常隔离强制、bridge 是唯一 Redis 越界点。是 Queue-vs-Pub/Sub 纪律的进程内对应。

(engine-session 同进程共置 / 打断走进程内 bus 而非 Redis 的说明放在 design.md，不另起 architecture spec delta —— 避免与 active 的 arch-cloud-edge-split 踩同一 spec 的 delta。)

## Impact

- **isales-engine**: 新增 `eventbus.py` / `events.py` / `tests/test_eventbus.py`(Phase 0,已实现,纯增量零行为风险);Phase 1 改 `run_loop.py` 的 `_ListenContext`/`_asr_pump`/`_ev_pump`/`_partial_monitor`/`_vad_monitor`/`_start_listen_pumps` + `main.py` 的 control 回调,消费端不动。
- **测试**: `test_eventbus.py`(lane 语义 / 无损永不丢 / 有损 drop-oldest / 异常隔离 / CancelledError 传播);`test_golden_transcript.py` + `test_run_session_contract.py`(change-0 网)全程保持绿。
- **无 alembic / 无跨仓 / 无 isales-common 改动**。
- **后续**: change-2(multi-route-dispatch)依赖本 bus 作为 route.selected / 状态投影的底座。
