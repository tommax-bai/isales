## Why

用户在 mac dev 真通话连续实测「说完话 AI 要愣 5–11 秒才接茬」（`call_record 150/151/152`，2026-06-05）。对话经常 2–6 轮就因 `silence_max_reached` 崩掉。

ECS engine 日志 + **火山 V3 SAUC 官方文档**实证根因（与早先被推翻的 DingRTC 混音/AEC、以及上一版 `asr-speaking-ear-close-timeout` 的 close_timeout/连接关闭理论都无关）：

- 我们把 DingRTC 的 **10ms 帧 1:1 转发**给 vendor（`asr_volcengine._push_audio` 每个 inbound chunk 一次 `ws.send`，约 **100 包/秒**）。
- vendor 文档明确：**「单包音频大小建议 100~200ms，发包间隔 100~200ms，不能过大或者过小，否则均会影响性能」**。10ms 比规格小 10–20×。
- 后果：① `end_window_size`（强制判停静音阈值，我们设 400ms）形同失效，vendor 把 `definite=true` 整句 finalize 拖到 **5–11s**；② WebSocket 每 ~50–60s 因 `keepalive ping timeout (1011)` 重连一次，丢掉当时 in-flight 的半句。
- **关键反证**：用客户端噪声门给 vendor 喂 100% 干净的数字静音，它**照样拖 1.2–4.3s** 才 finalize（call 151）。证明不是输入音质/底噪，而是发包方式违规。

次要现象：dev-no-modem mic 在用户停说话后仍有 ~800 RMS 环境底噪，vendor 的静音 VAD 看不到「真静音」，`end_window_size` 的计时器起不来——这是 finalize 慢的放大因素，但**主因仍是发包太碎**。

## What Changes

- `asr_volcengine.VolcengineASRProvider._push_audio`：**攒包到 ~100ms**（`sample_rate × 0.1 × 2B`）再 `ws.send`，不再 1:1 转发 10ms 帧。连接仍是单条长连接、不做 per-turn EOS/close，由 vendor 按 `end_window_size` 切句。
- `rtc_telephony._inbound_loop`：喂 ASR 那一路加**噪声门**（env 可调，默认 `RMS<1500` 连续静音超 `300ms hangover` → 替换成数字静音），让 `end_window_size` 的静音计时跑得起来。VAD 那一路（`vad_q`）保持原始音频，不门控（barge-in 检测要真信号）。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `provider-abc`：ASR Provider 契约增补——向上游 vendor 发送音频时 MUST 遵守 vendor 规定的发包粒度（单包/间隔），并通过该粒度让 vendor 的静音判停（`end_window_size`）及时输出 `definite`，使每轮 finalize 尾延迟落在亚秒级。

## Impact

**受影响 sub-repo**：`isales-engine`（`providers/asr_volcengine.py` + `realtime/rtc_telephony.py`）。**无 isales-common / api / web 改动**。

**无数据库 migration**（噪声门参数当前走 env；config 固化列为 followup task）。

**部署**：scp 两文件 → ECS + restart engine（editable install，已于本 session 完成，md5 对齐）。

**性能实证**（mac dev-no-modem，三通对照）：

| | call 150 无改 | call 151 仅噪声门 | call 152 攒包+门 |
|---|---|---|---|
| ASR finalize | 5–11s | 1.2–4.3s | **0.2–0.46s** |
| keepalive 重连 | 1 次 | 1 次 | **0** |
| 对话轮数 | 6 轮 | 2 轮崩 | **8 轮自然收尾** |

诊断/量化工具：`isales-telephony/scripts/call_timeline.py`（commit `f93ac02`），合并 edge + engine 双端日志成一条时间线 + 自动标空档。engine 修复 commit `e0bb356`。

**风险**：
- 噪声门阈值太高 → 削掉轻声用户的句尾。Mitigation：默认 1500 介于底噪 ~950 与人声 ~1900 之间 + 300ms hangover 覆盖词中停顿；call 152 八轮无碎句/无丢字。env 可调。
- 攒包到 100ms → 每轮 first-partial 理论上晚 ~100ms 出。可接受（换来 finalize 从 5-11s 到 <0.5s）。

**Non-Goals / Followup**（列为 tasks，不在本 change 一次做完）：
- 噪声门 env → `campaign` 配置固化（`asr_noise_gate_rms` / `_hangover_ms`），需 isales-common schema + alembic + 4 仓。
- 验证「单靠攒包是否就够、能否去掉噪声门」（本次两刀一起上，未单独隔离）。
- 评估改用 vendor 更优 endpoint `bigmodel_async`（结果变化才返回）；负包 EOS（`message_type_specific_flags=0b0010`）是显式判停但会终止整段识别，不适合 per-turn 持久连接。
- keepalive：攒包后重连已消失，暂不加 application-level ping；若复现再评估。

## Supersedes

取代 `asr-speaking-ear-close-timeout`（2026-06-04，已作废）。该 change 基于「per-turn `ws.close()` + close_timeout 默认 10s 阻塞重连 → SPEAKING 期间 ASR 失聪」的旧推论，其 `close_timeout=0.2` 真机 call 141/142 实测把 ASR recv loop 整个 wedge 掉、已 revert。当前部署代码早已删掉 per-turn `ws.close`、改单条持久连接 + `end_window_size` 切句，「连接被关」在线上不存在；真正卡顿是本 change 处理的发包粒度。
