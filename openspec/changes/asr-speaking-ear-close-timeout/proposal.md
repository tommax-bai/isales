## Why

用户在 mac dev 真通话（`call_record 138`, 2026-06-04）实测「AI 说话时打不断」。`pipeline-latency-tail` 把首音频降下来了，但 barge-in 在 AI 说话期间完全不触发。

ECS engine 日志实证根因（与早先被推翻的 DingRTC 混音/self-loopback/AEC 理论无关）：

- `asr_volcengine.py` 的 `websockets.connect(self._url, additional_headers=headers)` **没有传 `close_timeout`** → 用 websockets 库默认值 **10 秒**。
- 每轮 EOS 判定后，`_partial_stability_monitor` 调 `ws.close()`（`pipeline-stream-and-referee` 的 Q-fix，为跳过 vendor 慢 finalize），`_stream_one_connection` 的 `finally` 再 `await ws_ctx.__aexit__(...)` 关闭连接，**等 vendor 的 close 握手回应，等满 10s**。
- `_stream_one_connection` 因此卡 ~10s 才返回，外层 `stream_recognize` 的 `reconnect_after_clean_exit` 才触发重连。

日志时序对齐（call 138）：ASR 最后一条文本 `11:51:48,529` → `reconnect_after_clean_exit` 直到 `11:51:58,215`（~9.7s ≈ 库默认 10s）。这 ~10s 正好覆盖 AI 的整轮 SPEAKING：期间没有一个活的 ASR 连接在听用户，`_partial_monitor`（当前唯一活跃的 barge-in 路径；`_vad_monitor` 的 cancel 是 disabled prototype）收不到任何 partial，cancel 永不触发。

## What Changes

- `asr_volcengine.VolcengineASRProvider` 给 `websockets.connect(...)` 传一个**短 `close_timeout`**（默认 0.2s，构造参数可配），让 EOS-promote 后的连接关闭不再阻塞 ~10s，外层立即重连 → SPEAKING 期间 ASR 一直有耳朵，`_partial_monitor` 能在 AI 说话时收到 partial 并取消 `current_speaking_task`。
- close_timeout 做成构造参数 `ws_close_timeout_s`（默认 0.2），不写死。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `interruption-detection`: § "SPEAKING/FILLER 期间实时打断" 增补——ASR 连接 MUST 在 AI 说话期间保持可用（不被上一轮 EOS 的连接关闭阻塞），否则 barge-in 检测无音频可听。

## Impact

**受影响 sub-repo**：`isales-engine`（仅 `providers/asr_volcengine.py`）。

**无数据库 migration**。**无 isales-common / api / web 改动**。

**部署**：scp `asr_volcengine.py` → ECS + restart engine（editable install，同既有路径）。

**性能预期**：EOS-promote 后 ASR 重连从 ~10s 降到 ~200ms；AI 说话期间 ASR 持续在听，`_partial_monitor` 重获实时打断能力。

**风险**：
- close_timeout 太短 → 连接关闭握手没走完就丢弃 → 理论上可能漏 vendor 最后一帧。但本路径下我们已主动 `ws.close()` 并 promote 了 partial（不依赖 vendor 的最终 finalize），丢弃残余握手对识别结果无影响。**Mitigation**：保留 promote-on-EOS 语义不变；close_timeout 仅影响"等关闭确认"的时长，不影响已 yield 的结果。
- 重连更频繁 → 略增 vendor 连接建立开销。每轮一次，可接受（本就每轮重连，只是之前被 10s 阻塞拖慢）。

**Non-Goals**（明确不在本 change 改，列为 followup，均需真机 RMS 测量、不靠理论）：
- 不重新启用 `_vad_monitor` 的 cancel（2026-06-03 因 ambient-noise 误触发禁用）。
- 不重调 `voice_rms_threshold=1200`，不动 `_partial_monitor` 的 VAD-corroboration gate。这两者旧的 self-loopback/AEC 依据已于 2026-06-04 作废（call 138 数据不支持），重评估需要受控真机测量，另起 change。
- 不动 `_partial_stability_monitor` 的 `ws.close()`-on-promote 设计本身（它是为跳 vendor 慢 finalize，保留）。
