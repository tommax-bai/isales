<!-- SUPERSEDED 2026-06-08 by `engine-interruption-rule-tree`.
     该 change 的两个意图——(1) 把 prototype 的 min_text_length 提升成配置、
     (2) 废掉 _vad_monitor 的 VAD-source cancel（VAD 仅留 corroboration mirror）——
     已被 `engine-interruption-rule-tree` 整体吸收：min_text_length 成为可组合规则树
     里的 `length` 叶子，VAD-source cancel deprecate 作为该 change 的一条 spec
     Requirement 落地。本 change 未单独 apply，直接随 `engine-interruption-rule-tree`
     一起 archive，标 SUPERSEDED。 -->

## Why

iSales 当前 barge-in 设计有**双信号源**: (1) `partial_monitor` 看 ASR vendor partial text + VAD corroboration (550902d), (2) `_vad_monitor` 看 audio energy + voice_active_ms 阈值**独立触发 cancel speaking task**（fa413b1）。**VAD-source cancel 的本质问题是用了错的信号** — VAD energy 不抗噪 (噪音也有 energy), 真 mic ambient noise burst 容易过 voice_active_ms (200ms) + RMS 阈值 (~1500), 误触发打断 AI 长回应。

2026-06-03 mac dev-no-modem 真 mic 多轮对话实测（call_record #128/#129）:
- mac mic baseline RMS ~700-1100, 椅子/风扇/呼吸 burst spike 到 1500-2000 持续 200ms → 触发 vad cancel
- AI 销售话术 52 字 / 96 字 goal-driven 长回应被打断（transcript 显示 `source="vad" rms=1705 voice_active_ms=200`）
- user 没真说话, 只是椅子动一下

尝试 DingRTC SDK 内置 `setAudioDenoise` (mode=1 DSP / mode=2 Enhance) — empirical A/B/A 测试 (dump engine OnPlaybackAudioFrame raw audio 3 次对比 RMS 时序) 证明: **external audio source mode (iSales 用 `set_external_audio_source + push_external_audio`) bypass SDK 内部 NS pipeline**, setAudioDenoise rc=True 但 RMS 不下降（OFF/DSP/Enhance 三模式 baseline 都 ~600-1700, 在环境噪音浮动范围内）。SDK denoise 不是出路。

真因在"用错信号源"。用 vendor ASR partial **文字内容**当 barge-in 信号天然抗噪: vendor V3 SAUC 模型只识别人声成中文文字, ambient noise 通常识别不出文字 / 识别成空。

prototype #136 验证 (2026-06-03): `evaluate_partial` 加 hardcoded `min_text_length=2` gate + `_vad_monitor` cancel 段加 `continue` 跳过 → 跑真 mic 4 轮对话, **3 段 AI 长回应全部 `interrupted=FALSE` (含 62 字销售话术完整播出), 0 个 interruption event**。对照 #129 同 setup VAD-source 启用时 Turn 3+4 全 `interrupted=TRUE` 被打断。换信号源思路验证完毕, 该 promote 到正规 spec。

## What Changes

1. **`InterruptionConfig` 加字段 `min_text_length: int` (default 2)** — partial text strip 后 char count 必须 ≥ 此值才允许触发 barge-in。单字 ("对/好/嗯") 或空字符串过滤掉。
2. **`evaluate_partial` 新增 text length gate** — 在 whitelist check 之后, min_duration_ms check 之前: `len(text.strip()) < config.min_text_length` 返回 `InterruptionVerdict(verdict="ignored", reason="text_too_short")`。形成三重过滤: whitelist → text_length → duration → triggered。
3. **`_vad_monitor` cancel side-effect deprecate** — vad_monitor task 保留作 `session.vad_voice_active_ms` mirror (partial_monitor 仍需要 corroboration), **不再独立 `speaking_task.cancel()`** 也**不再写 transcript event source="vad"**。
4. **保留所有现有 InterruptionConfig 字段** — `whitelist` + `min_duration_ms` 语义不变。
5. **不改 partial_monitor 整体调用方式** — _asr_pump → asr_partials_q → partial_monitor → evaluate_partial 链路不变。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `interruption-detection`: 修改"双条件 partial 判定 (whitelist + min_duration_ms)"成"三条件 partial 判定 (whitelist + min_text_length + min_duration_ms)"; 新增"VAD-source cancel deprecate, VAD 仅作 corroboration mirror" Requirement; 现有 partial_monitor 调用面 / whitelist / min_duration_ms 语义保留。

## Impact

**受影响代码**:
- `isales-engine/isales_engine/realtime/interruption_detector.py` (~10 行: InterruptionConfig 加 `min_text_length` 字段 + evaluate_partial 加 text length check)
- `isales-engine/isales_engine/run_loop.py` (~15 行: `_vad_monitor` 内 line 942-956 段 cancel 路径删除, 保留 voice_active_ms mirror + transcript event source="vad" 写入删)
- `isales-engine/isales_engine/runtime_config.py` (~3 行: 加 `min_text_length` 从 PG campaign 表读取, default 2)
- `isales-engine/tests/test_interruption_detector.py` (新加 testcase: text_too_short / text_meets_min_length_passes)
- `isales-engine/tests/test_realtime_interruption.py` (调整 vad_monitor 不再 cancel 的断言)

**受影响 spec**:
- `openspec/specs/interruption-detection/spec.md` — 1 个 Modified Req + 1 个 ADDED Req

**不受影响**:
- partial_monitor task 框架 / asr_pump / asr_partials_q 链路不动
- `session.vad_voice_active_ms` mirror 仍提供 (550902d 防自环 corroboration 机制保留)
- whitelist / min_duration_ms 现有字段语义不变
- 其他 sub-repo (telephony/api/scheduler/worker/web) 不动
- call_record schema 不变 (transcript event 字段 schema 同; source="vad" event 新通话不再产生, 历史数据保留)

**数据库**:
- PG campaign 表加 `interruption_min_text_length` 列 (int default 2), runtime_config 读取
- alembic migration 在 isales-common 仓 (跟既有 campaign 字段扩展同 pattern)
- dev campaign 1 set min_text_length=2 复测 prototype 数据

**APIs / 协议**: 无 (InterruptionConfig 是 engine 内部 dataclass; campaign schema 加列但 schema-additive, 现有消费方不动)

**风险 + 缓解**:
- user 单字快速回应 ("对/好/嗯") 不能打断 AI → trade-off 接受 (whitelist 已过滤同类短词, 设计一致); 生产业务可按 campaign 配 `min_text_length=1` 覆盖
- 真说话场景 vendor partial 早期可能只识别出 1 字 ("等等" 先出"等"), 短期 < 2 字 gate 过滤, 等 vendor 推完整 partial 才触发打断 → 打断延迟轻微增 200-500ms (vendor cadence 内可接受)
- VAD-source cancel 失效 → 未来若发现"必须有 VAD-direct cancel"业务场景, 可补 followup change `interruption-vad-fast-path`

**followup changes** (不在本 change scope):
- `interruption-detection-vad-source-removal-cleanup`: 完全删除 `_vad_monitor` cancel 段 dead code + transcript schema 注释 source="vad" 已 deprecate
- `interruption-detection-per-campaign-tuning`: web admin UI 暴露 min_text_length 调节面板
