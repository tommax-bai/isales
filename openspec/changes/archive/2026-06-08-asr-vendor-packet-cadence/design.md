# Design

## 背景：被连续推翻的两层旧理论

ASR finalize 尾延迟（"说完话 AI 愣几秒"）经历了三轮根因推论，前两轮已被实证推翻：

1. **DingRTC 混音 / self-loopback / AEC**（最早）→ call 138 `post_downmix_rms` 数据证伪（AI 说话时入站 RMS 低且不稳，无"自己 TTS 灌满入站"特征）。
2. **per-turn `ws.close()` + close_timeout 默认 10s 阻塞重连**（`asr-speaking-ear-close-timeout`，2026-06-04）→ `close_timeout=0.2` 真机 call 141/142 把 recv loop wedge 掉、更差，已 revert；且当前代码已不做 per-turn close。
3. **发包粒度违反 vendor 规格**（本 change，2026-06-05）→ vendor 官方文档 + 三通对照实证，且"喂纯静音也拖 1-4s"反证排除了输入音质因素。

教训沉淀在 memory `[[project_pipeline_latency_tail_field_finding]]`：面对"vendor 拿不到/慢返回识别结果"，先对照 vendor 文档的输入规格，再推断内部因果。

## 决策 1：攒包到 100ms（主刀）

vendor 文档原文：「单包音频大小建议在 100~200ms 左右，发包间隔建议 100~200ms，不能过大或者过小，否则均会影响性能。」我们原来 1:1 转发 DingRTC 的 10ms 帧（resample 后 320B/帧 @ 16k mono），约 100 包/s，比下限小 10×。

实装在 `_push_audio` 累积缓冲：
```
target_bytes = int(sample_rate * 0.1) * 2   # 100ms mono int16 = 3200B
buf += chunk
while len(buf) >= target_bytes:
    ws.send(buf[:target_bytes]); del buf[:target_bytes]
```
- **为何 100ms 不是 200ms**：200ms 是 vendor 标注的"最优"，但 100ms 仍在推荐区间内且首-partial 延迟更低。先取区间下沿；若仍有余量可调到 200ms。
- **不会饿死**：DingRTC `OnPlaybackAudioFrame` 连续 ~100fps（含静音帧），buffer 每 100ms 必满一次。
- **连接生命周期不变**：仍单条长连接、无 per-turn EOS/close，由 vendor `end_window_size` 切句——保留当前（正确的）设计，只改发包大小。

## 决策 2：噪声门喂真静音（配套刀）

`end_window_size`（默认 800，我们设 400，最小 200）的语义是"静音时长超过该值 → 直接判停输出 definite"。但它需要 vendor **看到**静音。dev-no-modem mic 在用户停说话后仍有 ~800-950 RMS 环境底噪，vendor 的能量 VAD 可能一直判"有声"，计时器不启动。

实装在 `rtc_telephony._inbound_loop`（喂 ASR 那一路，line ~294 `inbound_q.put` 前）：
```
if _final_rms >= gate_rms:   # 1500
    silence_ms = 0; asr_pcm = pcm
else:
    silence_ms += frame_ms
    asr_pcm = zeros if silence_ms > hangover_ms(300) else pcm
inbound_q.put(asr_pcm)       # ASR 路：门控后
vad_q.put(pcm)               # VAD 路：永远原始
```
- **迟滞 + hangover**：避免裸逐帧门把词中停顿削成静音、导致 vendor 半句 finalize。300ms hangover 让自然停顿不触发，只有真句末静音才喂零。
- **阈值 1500**：底噪实测 ~950、人声 post_downmix ~1900-11000，1500 居中留余量。
- **VAD 路不门控**：`interruption-detection` 的 barge-in 要原始信号，门控会污染。
- **env 可调**：`ISALES_ASR_NOISE_GATE_RMS`（0 关闭）/ `ISALES_ASR_NOISE_GATE_HANGOVER_MS`。

## 决策 3：两刀都上，暂不隔离

call 151（仅噪声门）finalize 仍 1.2-4.3s；call 152（攒包+门）才到 0.2-0.46s。说明攒包是主刀。但"单靠攒包、去掉噪声门够不够"没单独测——生产 GSM 线路的底噪特征与 dev mic 不同，可能不需要门。列为 followup 隔离测试；当前两刀都保留是已验证的安全配置。

## 决策 4：不换 endpoint / 不用负包 EOS

- vendor 有 `bigmodel_async`（优化版，结果变化才返回，首尾字时延更优）和 `bigmodel_nostream`（发负包后返回，更准）。换 endpoint 涉及结果解析路径变化（async 版二遍识别 definite 只在 nostream 出），改动面更大。攒包是更小、风险更低的一刀，先做。
- 负包（`message_type_specific_flags=0b0010`，"仅指示此为最后一包"）是显式判停信号，但它**终止整段识别会话**——对 per-turn 持久连接不适用（发了就得重建连接，回到被否定的 per-turn close 老路）。所以不走负包，靠 `end_window_size` 自动切句。

## 验收口径

mac dev-no-modem 真通话（ECS engine journalctl + `call_timeline.py` 为真值）：
- ASR finalize（`asr_noise_gate ENGAGED` → `volcengine_asr_FINAL`）每轮 < 1s。
- 一通内 `volcengine_asr_reconnect` = 0。
- 多轮（≥6）自然对话不因 `silence_max_reached` 中途崩；能走到 goal/user_hangup/正常收尾。
- `call_timeline.py --call-id N` 无空档告警。

call 152 已全部满足。
