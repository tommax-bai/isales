## ADDED Requirements

### Requirement: 进程内 EventBus 通道

engine 的**单通话内**协调 SHALL 使用一个进程内、类型化、双车道的 EventBus（每个 `CallSession` 一个实例），取代手工接线的 `asyncio.Queue` + `asyncio.Event` + 跨任务 `task.cancel()` + `main.cancel()` sentinel。该 EventBus 是 § 通信通道矩阵之外的**进程内通道类型**——它 MUST NOT 跨进程、MUST NOT 序列化进 Redis；engine ↔ 其它服务的边界仍**只**走 Redis Queue / Pub/Sub（矩阵不变）。Redis 越界 SHALL 只发生在显式的 bridge 订阅者处（control 入站 → bus 事件;bus 事件 → `EngineEvent` 出站）。

#### Scenario: 双车道投递语义

- **WHEN** 一个事件被 post 到 EventBus
- **THEN** 按事件**类型**选车道：**无损道**（unbounded，`put_nowait` 物理不丢）SHALL 承载 ASR final、打断、挂断、lifecycle、control —— 一句用户 final MUST NOT 被丢；**有损道**（bounded，drop-oldest）SHALL 承载 ASR partial、音频帧、VAD
- **AND** 未显式注册车道的事件类型 SHALL 默认无损（永不静默丢弃）；只有显式 `register_lane(LOSSY)` 才能让某类型可丢

#### Scenario: 每-handler 异常隔离（强制）

- **WHEN** 某个订阅 handler 在处理事件时抛出非 `CancelledError` 异常
- **THEN** EventBus MUST 捕获并记录该异常、隔离它，**继续投递给同类型的其它 handler 并保持 dispatcher 存活**；一个坏 handler MUST NOT 拖垮 dispatch 循环或兄弟 handler
- **AND** `CancelledError` MUST 被重抛（不得吞掉）——打断的自取消依赖它

#### Scenario: 车道隔离与单写者

- **WHEN** 有损道涌入大量 partial/音频帧
- **THEN** 每车道一个 dispatcher 协程：车道内 SHALL 串行投递（无损道上无 CallSession 状态写竞争）、跨车道 SHALL 并发——有损道洪水 MUST NOT 延迟无损道上的一句 final
- **AND** 重 handler（LLM 管线）MUST post-and-spawn，MUST NOT 在 dispatcher 协程内内联阻塞

#### Scenario: 关闭时排空无损道

- **WHEN** 通话结束、EventBus 被 `aclose`
- **THEN** EventBus SHALL 先排空关闭前已入队的无损道事件再停止两个 dispatcher——保 shielded-finalize / DECR-snap-to-0 不变量（关闭前入队的 final / CallEnded MUST 仍被投递）；排空 SHALL 有界（关闭后 handler 再 post 的无损事件不致死循环）
