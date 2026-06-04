## Context

`asr_volcengine.VolcengineASRProvider.stream_recognize` 是一个 forever-loop：每次 `_stream_one_connection` 处理一段 utterance，EOS 后 `_partial_stability_monitor` promote latest partial 为 final + 主动 `ws.close()`（跳过 vendor V3 SAUC 的慢 finalize，~7s+），外层 loop `reconnect_after_clean_exit` 重连等下一段用户输入。

barge-in（SPEAKING 期间打断）依赖 `run_loop._partial_monitor` 消费 `asr_partials_q`——而该队列由这个 ASR 连接喂。若 ASR 连接在 AI 说话期间是关着的，partial_monitor 无 partial 可判，barge-in 不触发。

诊断证据（`call_record 138`, ECS engine 日志, 2026-06-04）：
- ASR 最后一条 `volcengine_asr_NONEMPTY_TEXT` @ `11:51:48,529`
- `volcengine_asr_reconnect_after_clean_exit` @ `11:51:58,215`（gap ~9.7s）
- 期间 AI 在 SPEAKING（多条 `tts_first_byte` 11:51:49–50），无 partial、无 interrupt
- `websockets.connect(...)` 未传 `close_timeout` → 库默认 10s；~9.7s ≈ 10s

## Goals / Non-Goals

**Goals**：
- EOS-promote 后 ASR 重连从 ~10s 降到 ~200ms，使 SPEAKING 期间 ASR 持续在听。
- 让 `_partial_monitor` 在 AI 说话时重获实时打断能力。
- close_timeout 可配，不写死。

**Non-Goals**：
- 不重启用 `_vad_monitor` cancel；不重调 `voice_rms_threshold`；不动 VAD-corroboration gate（均需真机测量，另起 change）。
- 不改 `ws.close()`-on-promote 设计；不改 promote-on-silence-EOS 语义。
- 不动 TTS / LLM / 其他 provider。

## Decisions

### 决策 1：短 close_timeout 传给 websockets.connect

`websockets.connect` 接受 `close_timeout`（关闭握手等待上限）。当前不传 → 默认 10s。改为构造参数 `ws_close_timeout_s`（默认 0.2），传给 connect：

```python
ws_ctx = websockets_module.connect(
    self._url,
    additional_headers=headers,
    close_timeout=self._ws_close_timeout_s,
)
```

**Rationale**：本路径已主动 `ws.close()` 并 promote 了结果，不依赖 vendor 把 close 握手走完；`close_timeout` 仅决定 `__aexit__` 等关闭确认多久。降到 0.2s → teardown 快 → 外层立即重连。

**Alternatives**：
- (A) 并发重连（不 await 旧连接 close 就开新连接）：能更快，但要管理两个连接的生命周期 + 防 audio_chunks 双消费，复杂度高。否决，close_timeout 是最小改动。
- (B) 不 `ws.close()`、改别的方式跳 vendor finalize：改动大、回归风险高（promote/silence-EOS 是 6/01 真机调出来的）。否决。

### 决策 2：默认值 0.2s

0.2s 给关闭握手一点点时间又不阻塞。太小（如 0）可能在某些网络下偶发 warning；0.2s 实测足够。做成构造参数，真机验证后可调。

## Risks / Trade-offs

- **漏 vendor 残余帧**：close_timeout 短 → 可能丢弃 vendor 在 close 后还想发的帧。但我们已 promote partial 作为该 utterance 的 final，残余帧本就会被 suppress（`_promote_yielded`）。无功能影响。
- **重连开销**：每轮一次连接建立（本就如此，只是之前被 10s 拖慢）。vendor 连接建立 ~50ms（call 138 `asr_connected` logid ~51ms）。可接受。

## Migration Plan

1. `asr_volcengine`：加 `ws_close_timeout_s` 构造参数（默认 0.2）+ 传给 connect。
2. 单测：构造默认 0.2；connect 收到 close_timeout（mock websockets.connect 断言 kwarg）。
3. 部署：scp `asr_volcengine.py` → ECS + restart engine。
4. 真机验证：mac dev-no-modem 受控通话，量 `reconnect_after_clean_exit` 间隔 ~200ms + AI 说话中途插话出现 partial + `current_speaking_task` cancel。

## Open Questions

- **Q1**：0.2s 是否够稳？→ 暂定 0.2，真机看是否有 close warning，必要时调 0.3。
- **Q2**：重连快了之后，`_partial_monitor` 的 VAD-corroboration gate（需 `vad_voice_active_ms ≥ min_duration`）会不会仍挡住真打断？→ 本 change 先只修 close_timeout 让 ASR 有耳朵；若 gate 仍挡，归入 Non-Goal 的 VAD 重评估 followup（需真机 RMS 测量）。真机验证时一并观察记录。
