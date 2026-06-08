## Context

iSales barge-in 设计源自 `interruption-detection` capability spec, 实现散在 `isales-engine/isales_engine/realtime/interruption_detector.py` + `isales_engine/run_loop.py::_partial_monitor` + `isales_engine/run_loop.py::_vad_monitor`。当前**两个并行 cancel 路径**:

- **partial_monitor** (`run_loop.py:760+`): 消费 `asr_partials_q`, 对每个 partial 调 `evaluate_partial`, 判定 triggered 则 cancel `current_speaking_task`. 5/28 `550902d` commit 加 VAD corroboration — 需要 `session.vad_voice_active_ms >= threshold` 才接受 partial (防 dev self-loopback 误触)。
- **vad_monitor** (`run_loop.py:900+`, fa413b1): 消费 `audio_in_vad`, 累计 voice_active_ms; 若 `voice_active_ms >= min_duration_ms` (200ms) + SPEAKING state 中, 独立 `speaking_task.cancel()` + 写 `transcript event source="vad"`。这是 "ASR-bypass VAD monitor" — 不等 vendor 出 partial 就快速 cancel。

VAD-source cancel 的初衷是**响应快**: vendor partial 有 latency (1-5s), VAD audio energy 实时, 真打断场景 (user 抢说) VAD 比 partial 早 1-3s 触发 cancel, user 体验更接近自然电话。

但 2026-06-03 真 mic 实测打破了这个假设:
- mac mic ambient noise (椅子/呼吸/风扇) baseline RMS ~800-1100, 偶尔 burst 1500-2000 持续 200ms → VAD `voice_active_ms` 累到 200ms 阈值, 触发 cancel
- 实测 call #128/#129 transcript: `interruption source="vad" rms=1705 voice_active_ms=200` 打断 AI 销售话术 52/96 字
- user 报告"两轮之后 AI 没再说" — 实际 AI 在说但 mac speaker 输出被 cancel

VAD energy 信号本质问题: **能量域无法区分"人说话"vs"噪音"**。提高 VAD 阈值 (RMS / voice_active_ms) 只是 noise floor 移高一点, 持续噪音 (键盘连打 / 持续风扇 / 持续低语) 仍能过。

尝试过 DingRTC SDK 内置 audio processing (`setAudioDenoise` mode=0/1/2 A/B/A 实测): SDK 接受 rc=True 但 engine inbound RMS 不下降 — iSales 用 `set_external_audio_source + push_external_audio` 模式跳过 SDK 内部 NS pipeline, denoise 只对 SDK 自动 mic 流生效, 对自定义 push 的 audio 失效。SDK denoise 路径作废。

正解是**换信号源**: 用 vendor ASR partial 文字内容当 barge-in 信号。vendor V3 SAUC 模型只把人声识别成中文, 噪音通常识别不出文字（识别成空字符串或全静音 partial）。把"字数 ≥ N" 作为闸, 噪音天然过不去。

prototype #136 (2026-06-03 13:53) 实证: hardcoded `min_text_length=2` in evaluate_partial + `_vad_monitor` cancel 段 `continue` 跳过 → 真 mic 4 轮对话 3 段 AI reply 全 `interrupted=false`, 0 个 interruption events, AI 62字销售话术完整播出。设计验证完毕。

## Goals / Non-Goals

**Goals:**
- 消除 ambient noise / self-loopback 误触发 barge-in 打断 AI 长回应的问题。
- 让 partial_monitor 成为**唯一** barge-in 触发源, 通过 `min_text_length` gate 过滤短噪音 partial。
- 保留 partial_monitor 的 VAD corroboration 防自环机制 (550902d), 不破坏现有 partial_monitor 调用面。
- 保留 InterruptionConfig 现有字段 (`whitelist` / `min_duration_ms`) 语义, 加新字段 `min_text_length` 是 schema-additive 不破坏既有 caller。

**Non-Goals:**
- **不**完全删除 `_vad_monitor` task — 它仍负责 mirror `session.vad_voice_active_ms` 给 partial_monitor corroboration; 完全删属于 followup change。
- **不**改 partial_monitor 调用结构 / `_asr_pump` / `asr_partials_q` 数据流。
- **不**做 audio 端降噪 (rnnoise / webrtc-audio-processing 等); SDK setAudioDenoise A/B/A 已证 external mode 下无效, application-layer NS 是 followup 选项。
- **不**改 transcript event schema — 只是 source="vad" interruption event 新通话不再产生 (历史数据保留)。
- **不**改 call_record / cross-service message contract / scheduler / worker / web。

## Decisions

### 决策 1: 新增 `min_text_length` 字段, default = 2

```python
@dataclass
class InterruptionConfig:
    whitelist: tuple[str, ...]
    min_duration_ms: int
    min_text_length: int = 2   # 新增
```

`evaluate_partial` 内三重过滤次序:
```python
if text.strip() in config.whitelist:        → ignored("whitelist")
if len(text.strip()) < config.min_text_length: → ignored("text_too_short")
if elapsed < config.min_duration_ms:        → ignored("below_threshold")
return triggered("exceeds")
```

**Rationale**:
- 2 字阈值: 真生产 user 主动打断通常是 "等等" / "不要" / "我现在" / "你说" 2 字以上; 单字 ("对/好/嗯") 太短不区分 (a) 真单字短回应 (b) 噪音误识别 (c) vendor partial 早期 1 字片段还在累积
- 字段 default = 2 不破坏现有 caller (现有 InterruptionConfig 构造无 min_text_length 参数也能用 dataclass default)
- per-campaign override: 业务需求快速 user 单字打断的场景 (e.g. 客服快回应), 配 `min_text_length=1` 即可

**Alternatives considered**:
- (A) `min_text_length=1`: 单字也算打断 — 噪音"对"被识别误触发, 还是没解决根因
- (B) `min_text_length=3`: 更保守 — user 真主动 2 字打断 ("等等") 反应慢
- (C) 完全删除 partial-trigger barge-in, 只靠 final → 但 vendor 7+ s 才出 final, AI 永远说不完都没机会打断

### 决策 2: `_vad_monitor` cancel side-effect deprecate, 但 task 保留

VAD-source cancel **完全禁用** (移除 `speaking_task.cancel()` + transcript `source="vad"` event 写入), 但 `_vad_monitor` task 本身**保留**, 因为:
- `session.vad_voice_active_ms` mirror 给 partial_monitor corroboration (550902d 防自环机制): partial_monitor 收到 partial 时先 check vad_voice_active_ms > 0 才接受, 防 dev self-loopback engine TTS echo 触发 partial → 误打断
- 删除 vad_monitor task 等于删除 corroboration → 影响范围远超本 change

`_vad_monitor` 的代码改动:
```python
# Before (run_loop.py:942-956):
if voice_active_ms < interruption_cfg.min_duration_ms:
    continue
session.interruption_signaled = True
session.append_event("interruption", source="vad", ...)
speaking_task.cancel()
# ... (15 行)

# After:
if voice_active_ms < interruption_cfg.min_duration_ms:
    continue
# VAD-source cancel deprecate; vad_monitor only mirrors voice_active_ms
# for partial_monitor corroboration (session.vad_voice_active_ms set above).
# Barge-in trigger 完全交给 partial_monitor + evaluate_partial 的
# min_text_length gate (interruption-detection-text-length-gate change).
continue
```

**Rationale**: 最小破坏 — vad_monitor task 框架 / voice_active_ms 累计逻辑 / mirror to session 全保留, 只删 cancel + transcript 写入 5-10 行。

**Alternatives considered**:
- (A) 完全删除 `_vad_monitor` task: 减代码量但破坏 partial_monitor corroboration → 需先做 alternative corroboration 才能删
- (B) 保留 VAD cancel + 强化护栏 (提高 RMS 阈值到 3000, voice_active_ms 到 500): 治标不治本, 持续噪音仍误触发
- (C) VAD-direct cancel 只在 `min_text_length=0` 配置下启用 (业务显式 opt-in): 复杂度高且没明确需求

### 决策 3: 复用现有 InterruptionVerdict.reason 字段, 新加 "text_too_short" 值

`InterruptionVerdict.reason: str` 当前可能值 `"whitelist" / "below_threshold" / "exceeds"`, 加新值 `"text_too_short"`。无 schema 改动, 字段已是 free-form str。

transcript event 现有结构:
- 旧 source="vad" cancel: `{type:"interruption", source:"vad", voice_active_ms:N, rms:N}` 不再产生
- 旧 partial-source ignored: 不写 event (verdict=ignored 不触发 cancel + 不写 transcript)
- 新 text_too_short ignored: 同上 (不写 transcript event); 仅在 `_partial_monitor` 内 `logger.info("partial_monitor_skip_text_too_short text=%r")` 记录, 便于 ops grep tuning 阈值

**Rationale**: 不增加 transcript event noise; verdict=ignored 是 partial_monitor 内部信号, 跨服务消费方不关心。

### 决策 4: PG campaign 表加 `interruption_min_text_length` 列

按 iSales 既有 campaign 字段扩展 pattern (campaign 表已有 `silence_threshold_ms` / `interruption_min_duration_ms` 等):
- Type: `int`, NOT NULL, default 2
- 由 `runtime_config.py::build_runtime_config` 读取并填进 `InterruptionConfig.min_text_length`
- alembic migration 在 `isales-common/alembic/versions/` 加一个文件
- dev campaign 1 通过 SQL 改成 2 复测 prototype 数据 (生产 campaign 用 default = 2)

**Rationale**:
- per-campaign 配置粒度跟 iSales 既有架构一致 (不同业务可调不同阈值)
- 不读 PG 直接用 dataclass default = 2 也行, 但生产场景调阈值需重启 engine, per-campaign DB 配置更灵活

**Alternative**: 不入 PG, 只用 dataclass default + env override. 简化但失去 per-campaign tunability.

## Risks / Trade-offs

- **Risk**: user 单字快速回应 ("对/好/嗯") 不能打断 AI long reply
  → **Mitigation**: whitelist 已在过滤同类短词, 设计原则一致; 业务需求快回应可 per-campaign 配 `min_text_length=1` override

- **Risk**: 真说话场景 vendor partial 早期只识别 1 字 ("等等" 先出"等"), gate 过滤导致打断延迟轻微增加
  → **Mitigation**: vendor partial 通常 100-300ms cadence 推完整 utterance, 实际延迟增 200-500ms 在自然对话节奏内不显著

- **Risk**: VAD-source cancel 失效, 未来若发现"必须 VAD 快速 cancel"业务场景 (e.g. vendor latency 极高 + 紧急打断)
  → **Mitigation**: 起 followup change `interruption-vad-fast-path` 恢复带新护栏的 VAD 路径 (e.g. 仅在 RMS > 5000 + 持续 800ms + ASR confirm) — 但需先有真业务证据

- **Trade-off**: 完全依赖 vendor V3 SAUC partial 识别准确度; vendor 极少数情况把噪音误识别成字 (如 "啊" / "哎") 会绕过 text_too_short 落入 whitelist filter
  → **接受**: whitelist 设计已覆盖此类常见误识别; 配合 InterruptionConfig 每 campaign 调优可控

- **Trade-off**: 失去"VAD-direct 早 cancel"的响应速度优势; 真 user 主动打断现在需等 vendor 出 ≥2 字 partial
  → **接受**: 实测 vendor partial cadence (smoke #136 verify) ~1-2s 出 stable partial, 比 VAD 误打断的 AI 损失 (整段 60+ 字 reply 被 cancel) trade-off 更值

## Migration Plan

**部署顺序**:
1. mac local 改 `interruption_detector.py` + `run_loop.py` + `runtime_config.py`
2. 跑 isales-engine pytest (含新 testcase) 全绿
3. commit + push feature branch
4. alembic migration: isales-common 仓加 `add_campaign_interruption_min_text_length.py`
5. ECS 执行 alembic upgrade (PG schema migration)
6. scp 改动到 ECS `/opt/isales/current/isales-engine/`
7. `systemctl restart isales-engine`
8. mac dev-no-modem 真 mic 多轮 smoke 验证 (同 #136 setup) → 期望 3+ 段 AI reply 全 `interrupted=false`, 0 个 interruption events
9. 真拨号 e2e (Windows + GSM, task 5.x) → 验证 user 真说话 2 字以上能正常触发打断

**Rollback**: revert commit + scp 旧版本 3 文件覆盖 ECS + restart。alembic migration column 是 schema-additive (NOT NULL + default 2), 不需要 rollback DB schema (旧代码不读这个列不影响)。Rollback 5 分钟内完成。

**部署窗口**: 任何时段; engine restart 期间在途 call 会断 (已有行为)。

## Open Questions

- **Q1**: `min_text_length` 在中文 vs 英文/数字混合场景下是按 char count 还是按 utf-8 byte 算?
  → **暂定**: char count (Python `len(text.strip())`), 中文 1 字 = 1 char. 英文单词 "ok" = 2 char 算够, "no" = 2 char 算够. 业务实际若中英混跑出问题再 followup change.

- **Q2**: 是否需要给 `min_text_length` 加 web admin UI 配置面板?
  → **暂定**: 不在本 change scope; 留 followup change `interruption-detection-per-campaign-tuning` 跟 silence_threshold 等其它 campaign 调参面板一起做。

- **Q3**: 若 VAD-source cancel deprecate 后 ops 发现 partial_monitor 仍有边缘 case (e.g. vendor 极慢导致打断响应不及时), 是否要加 fallback?
  → **暂定**: 先验证当前设计在真生产稳定运行 N 周, 监控 transcript event source / interrupted 字段比例, 出问题再 followup `interruption-vad-fast-path`.
