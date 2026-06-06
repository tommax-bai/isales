## 1. Phase 0 — EventBus foundation (纯新增,零行为风险)

- [x] 1.1 `isales_engine/eventbus.py`:双车道 `EventBus`(LOSSLESS unbounded / LOSSY drop-oldest)+ `register_lane` + name-based 默认(未注册→LOSSLESS 安全)+ `subscribe`/`post`/`start`/`aclose` + 每-handler try/except 隔离(CancelledError 重抛)+ 每车道一 dispatcher + `drain_inline` 测试态
- [x] 1.2 `isales_engine/events.py`:信号事件词表 `@dataclass(slots=True, frozen=True)` —— `AsrFinal`/`AsrStreamEnded`/`Connected`/`HangupDetected`/`InterruptRequested`/`ManualHangupRequested`/`TransferRequested`(无损)+ `AsrPartial`/`VadFrame`(有损)
- [x] 1.3 `tests/test_eventbus.py`:lane 默认 + 注册覆盖 / 无损永不丢(10k flood)/ 有损 drop-oldest + dropped 计数 / 每-handler 异常隔离 / CancelledError 传播 / async handler await / 后台 dispatch + aclose 排空
- [x] 1.4 确认 change-0 golden + 契约网仍逐字节绿(Phase 0 纯增量)

## 2. Phase 1 — 信号迁移到 bus(消费端逐字节不变)

> **拆 1a / 1b(2026-06-06 执行决策)**:1a = ASR/hangup 信号迁移(纯 bridge,golden+全套
> 测试兜底,零行为风险,**本会话已完成**);1b = barge-in 反转 + manual-hangup(改时序 /
> 与 main.py 未提交 WIP 纠缠,**需真机或独立处理,deferred**)。理由见各条 NOTE。

### Phase 1a — 安全 bridge(✅ 已完成,commit 待提交)

- [x] 2.1 `run_loop._start_listen_pumps`(改 `async`):建 `EventBus`,`register_lane(AsrPartial, LOSSY)`,`await bus.start()`;`run_session` call-site 改 `await`;`_stop_listen_pumps` 里 cancel pumps 后 `await ctx.bus.aclose()`。
  - NOTE:bus 暂存在 `_ListenContext.bus`(非 session)——1a 只有 run_loop 内部用;`session.bus` 留给 2.6(main.py 控制回调需要)时再加。
  - NOTE:**VadFrame 故意未 register_lane**——本 pass 不碰 `_vad_monitor`,无人 post VadFrame,注册空 lane 属"为做而做";其 LOSSY 注册随 2.5 的 producer 一起进。
- [x] 2.2 `_asr_pump`:final → `post(AsrFinal(text))` + 清 `current_user_speech_started_ms`(保留),partial → `post(AsrPartial(text))`,`finally` 流终止 → `post(AsrStreamEnded())`(取代 `queue.put` / `asr_finished.set`)。
- [x] 2.3 `_ev_pump`:remote/local hangup / device_error → `post(HangupDetected(cause=ev_type))`(取代 `hangup_event.set`)。
- [x] 2.4 **bridge subscriber**(在 `_start_listen_pumps` 内,start 前注册):`AsrFinal`/`AsrPartial` → `put_nowait(ASRResult(text=…, is_final=…, timestamp_ms=0))` 喂回 `asr_finals_q`/`asr_partials_q`(两个消费端只读 `.text`,重建对消费端 byte-identical);`HangupDetected`→`hangup_event.set()`;`AsrStreamEnded`→`asr_finished.set()`(`asr_finished` 当前 vestigial,无人消费)。`_main_turn_loop` + 两个 monitor **逐字节不变**。
- [x] 2.8 `test_golden_transcript.py` + `test_run_session_contract.py` 逐字节绿;`test_realtime_interruption.py`(直接喂 `_partial_monitor` 自己的 `asr_partials_q`,与 bus 解耦,故仍绿)/ `test_run_loop.py` 全绿。**全套 326 passed / 27 skipped / 0 failed**。
- [x] 2.9 **新增 `tests/test_listen_pumps_bridge.py`**(5 例)补 review 查出的覆盖盲区:golden fixtures 无 `interruption` 事件、`test_eventbus` 用 `drain_inline`(单协程)、`test_realtime_interruption` 绕过 bus——故"信号经真双车道 dispatcher + bridge 落回队列"此前零覆盖。新测试驱动真 `_start_listen_pumps`,确定性断言 final/partial/hangup/stream-ended 经真 dispatcher 落回 `asr_finals_q`/`asr_partials_q`/`hangup_event`/`asr_finished` + lane 注册 + partial flood 不饿死 lossless final + `bus.dropped==0`。
  - review 跟进①(audit knob):`_stop_listen_pumps` 末尾 `bus.dropped>0` 时 WARN log——让唯一有损偏差(AsrPartial 上 256 drop-oldest 道)可观测。
  - review 跟进②(change-2 HAZARD):`await bus.start()` 后留显式注释——当前 start→return 之间无可抛点故 run_session finally 安全托管 bus;change-2 一旦在此窗口加可抛 `await`,必须 try/except 兜 `bus.aclose()` 否则泄漏 dispatcher 协程。**故意不加当前不可达的防御死代码**(避免"为做而做"),改留 loud marker。
  - review 裁定:`fix-then-ship` / `must_fix=[]`——cross-lane 重排 & partial 丢弃为真但经 monitor latch+gate / drop-oldest-keep-best 证不可观测,byte-identity 成立。

### Phase 1b — manual-hangup 迁移(✅ 2.6 已完成)+ barge-in 反转(⏸ 2.5 DEFERRED)

- [x] 2.6 `main.py` `_on_manual_hangup`/`_on_transfer`:改 `sess.bus.post(ManualHangupRequested/TransferRequested)`;删 `_ManualHangupRequested` 异常类 + 死 `except` 块 + `request_manual_hangup`。
  - **bus 生命周期上移**:bus 从「`_start_listen_pumps` 建 / `_stop_listen_pumps` 销」改成「**run_session 入口建 + `session.bus` + start;finally aclose**」——因为控制面挂断要从拨号起就能用(`request_manual_hangup` 旧行为靠 dial_consumer 在拨号时设的 `session.tasks["main"]`,从通话一开始就在),bus 若等到 greeting 后才建会丢 greeting 期挂断。`_start_listen_pumps` 改用 `session.bus`(`assert not None`),不再 start/aclose。`call_session.py` + `bus: EventBus | None` 字段。
  - **控制 bridge**:`_subscribe_control_bridges(session, bus)` 订阅 `ManualHangupRequested`/`TransferRequested` → `_terminate(cause)`(= 旧 `request_manual_hangup` 体:设 `MANUAL_HANGUP` + `main.cancel()`),**逐字节等价**(含 transfer→MANUAL_HANGUP 的 stage-4 stub)。死 `except _ManualHangupRequested` 确认从不触发(`main.cancel()` 抛裸 CancelledError),删除无行为影响;manual-hangup 的实际 finalize 一直在 dial_consumer/finalize 侧,本 change 没动。
  - **测试**:新 `tests/test_control_bridges.py`(4 例,补此前零覆盖的 manual-hangup 机制);`tests/test_listen_pumps_bridge.py` 改成 bus 从 session 建+收。全套 **331 passed / 27 skipped**,ruff 净。
  - **HAZARD 解除**:bus 归 run_session.finally 托管后,1a 留的 change-2 dispatcher 泄漏隐患自动消解(_start_listen_pumps 即便中途抛,finally 仍 aclose)。
  - **WIP 处理**:`git stash` 那 9 文件 multi-Edge WIP → 干净树做 2.6 → commit → `git stash pop` 复原(已核 main.py 区域不重叠,pop 干净)。
- [ ] 2.5 `_partial_monitor`/`_vad_monitor`:触发改 `post(InterruptRequested(source, user_text))`;playback owner 订阅并**自取消**(取代 reach-across `current_speaking_task.cancel()`);`barge_in_active` flat flag 取代 `interruption_signaled`。
  - **DEFER 理由**:① 改打断 signal-then-cancel 时序(call-143 race),memory 明记"需真机复验、别盲推";golden net 确定性 mock,**不覆盖** barge-in 竞态。② `test_realtime_interruption.py` 直接 unit-test monitor 的 reach-across,改 producer 会破坏它。③ 自然 gate = change-3 真机真拨 UX gate(blueprint §7,需物理 SIM7600 rig)。
- [ ] 2.7 保留 legacy reach-across cancel 作为可回退分支(removal trigger = change-2 router 接管 + call-143 真机复验)。
  - NOTE:monitor 未碰,**reach-across 仍是唯一且默认路径**;本条只在 2.5 落地、新 self-cancel 成为默认后才有意义。当前无双路径、无 fallback 叠层。

## 3. 校验 + 部署

- [ ] 3.1 `openspec validate engine-eventbus-foundation --strict` 通过(本会话跑)
- [x] 3.2 engine 全套测试绿(`-k 'eventbus or run_loop or golden or interruption'` 子集 39 绿 + 全套 326 绿)。meta-repo `make test-all` 受 sibling venv 探测影响,以 engine 内直跑为准。
- [ ] 3.3 部署 engine 到 ECS soak(Phase 1a 零行为风险,可先发);STATE.md 更新 —— **待用户决定**(见会话末选项)。
- [ ] 3.4 Phase 1b 收尾后再 archive 本 change,然后才开 `engine-multi-route-dispatch`(避免 ai-pipeline delta 互覆盖)。
