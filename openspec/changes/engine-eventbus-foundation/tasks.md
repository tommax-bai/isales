## 1. Phase 0 — EventBus foundation (纯新增,零行为风险)

- [x] 1.1 `isales_engine/eventbus.py`:双车道 `EventBus`(LOSSLESS unbounded / LOSSY drop-oldest)+ `register_lane` + name-based 默认(未注册→LOSSLESS 安全)+ `subscribe`/`post`/`start`/`aclose` + 每-handler try/except 隔离(CancelledError 重抛)+ 每车道一 dispatcher + `drain_inline` 测试态
- [x] 1.2 `isales_engine/events.py`:信号事件词表 `@dataclass(slots=True, frozen=True)` —— `AsrFinal`/`AsrStreamEnded`/`Connected`/`HangupDetected`/`InterruptRequested`/`ManualHangupRequested`/`TransferRequested`(无损)+ `AsrPartial`/`VadFrame`(有损)
- [x] 1.3 `tests/test_eventbus.py`:lane 默认 + 注册覆盖 / 无损永不丢(10k flood)/ 有损 drop-oldest + dropped 计数 / 每-handler 异常隔离 / CancelledError 传播 / async handler await / 后台 dispatch + aclose 排空
- [x] 1.4 确认 change-0 golden + 契约网仍逐字节绿(Phase 0 纯增量)

## 2. Phase 1 — 信号迁移到 bus(消费端逐字节不变)

- [ ] 2.1 `run_loop._start_listen_pumps`:在 session 上建 `EventBus`,`register_lane(AsrPartial/VadFrame, LOSSY)`,`await bus.start()`;`_stop_listen_pumps` 里 `await bus.aclose()`
- [ ] 2.2 `_asr_pump`:final → `post(AsrFinal)`,partial → `post(AsrPartial)`,流终止 → `post(AsrStreamEnded)`(取代 queue.put / asr_finished.set)
- [ ] 2.3 `_ev_pump`:remote/local hangup / device_error → `post(HangupDetected(cause))`(取代 hangup_event.set)
- [ ] 2.4 **bridge subscriber**:订阅 `AsrFinal`/`AsrPartial`/`HangupDetected`/`AsrStreamEnded`,喂回现有 `asr_finals_q`/`asr_partials_q`/`hangup_event`/`asr_finished`——`_main_turn_loop` 消费端**逐字节不变**
- [ ] 2.5 `_partial_monitor`/`_vad_monitor`:探测逻辑逐字保留(text≥2 gate / wall-clock 锚点 / 300ms hangover / VAD-disabled),触发改 `post(InterruptRequested(source, user_text))`;playback owner 订阅并**自取消**(取代 reach-across `current_speaking_task.cancel()`);`barge_in_active` flat flag 取代 `interruption_signaled`
- [ ] 2.6 `main.py` `_on_manual_hangup`/`_on_transfer`:改 `bus.post(ManualHangupRequested/TransferRequested)`(取代 `request_manual_hangup` + `main.cancel()` sentinel);删 `_ManualHangupRequested` 异常类
- [ ] 2.7 **真机/真实时序前**保留 legacy reach-across cancel 路径作为可回退分支(removal trigger = change-2 router 接管 + call-143 race 真机复验)
- [ ] 2.8 `test_golden_transcript.py` + `test_run_session_contract.py` 全程逐字节绿;`test_realtime_interruption.py` / `test_run_loop.py` 全绿

## 3. 校验 + 部署

- [ ] 3.1 `openspec validate engine-eventbus-foundation --strict` 通过
- [ ] 3.2 `make test-all PYTEST_ARGS="-k 'eventbus or run_loop or golden or interruption'"` 绿
- [ ] 3.3 部署 engine 到 ECS soak(零行为风险,先发本 change);STATE.md 更新
- [ ] 3.4 archive 本 change 后再开 `engine-multi-route-dispatch`(避免 ai-pipeline delta 互覆盖)
