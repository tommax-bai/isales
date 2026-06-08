## Context

垫词链路三处状态彼此矛盾：

1. **filler spec**（`openspec/specs/filler/spec.md` Requirement「预生成 + 动态补充音频」）规定垫词音频 SHALL 预生成到 OSS、运行时 MUST NOT 实时 TTS。
2. **engine 实装**（`isales_engine/realtime/filler_manager.py:181-196`）走的是运行时实时 TTS：`self._tts.synthesize_stream(phrase.text, voice_id)`，`self._tts` 已被 `CachingTTSProvider`（tts-cache-and-gated-filler）包成进程级 LRU 缓存；**从不读 `audio_url`**。
3. **engine 选取门槛**（同文件 `_pick_phrase` line 128-132）却仍按 spec 原意要求 `generation_status == READY and p.audio_url`。

v1.0 没有 OSS、没有 `regenerate_filler_audio` worker，`audio_url` 恒为 NULL、`generation_status` 恒为 `pending`（model 默认值，全 sub-repo 无任何写 READY 的代码点）。因此选取门槛恒不满足 → `_pick_phrase` 恒返回 None → `filler_skip_no_ready_phrase` → 垫词从不触发。运营在 `BasicTab.vue` 打开 `filler_enabled` 也无效。

约束：本 change 不引入 OSS、不新建 worker、不改 schema（相关字段全已存在）；遵循单主路径原则，不堆叠「先查 OSS 再 fallback TTS」的双层逻辑。

## Goals / Non-Goals

**Goals:**
- 让 v1.0 实时合成路径在 `filler_enabled=true` 时能真正播出垫词。
- 让 spec 与实装一致：v1.0 主路径 = 运行时实时 TTS + 进程缓存。
- 运营在客户面详情页 `CampaignDetail.vue` 可见并可改 `filler_enabled` / `filler_delay_ms`。

**Non-Goals:**
- 不实现 OSS 预生成 / `regenerate_filler_audio` worker（stage-6 未来工作）。
- 不实现「audio_url ready 则推流、否则合成」的双分支（提前实现即违反单主路径原则）。
- 不动 `filler_phrase` schema、不动 `audio_url` / `generation_status` 列（保留给 stage-6）。
- 不改时间门控（§B，属 `tts-cache-and-gated-filler`）。

## Decisions

### D1：选取门槛改为「text 非空」，丢弃 audio_url / generation_status 硬依赖

`_pick_phrase` 的 `ready` 过滤从
```python
if p.generation_status == GenerationStatus.READY.value and p.audio_url
```
改为
```python
if p.text.strip()   # v1.0 实时合成只需文本；audio_url/generation_status 是 stage-6 OSS 路径字段
```

**为何不保留 generation_status 判断**：v1.0 没有任何代码把它置为 READY，保留即等于永远 skip。`pending` 是「未预生成」，但实时合成路径压根不需要预生成，所以 `pending` 在 v1.0 语义下就是「可合成」。

**替代方案（否决）**：保留 `audio_url` 优先、为空再合成的双分支。否决理由——v1.0 `audio_url` 恒空，该分支是纯死代码 + 多层 fallback，违反 `[[feedback-avoid-multilayer-fallback]]`。stage-6 真正引入 OSS 时再以独立 change 加回，并带「当 worker + OSS 就绪」的明确恢复条件。

### D2：spec 修订降级 OSS 为 stage-6 可选，而非删除

「预生成 + 动态补充音频」requirement 改写为「v1.0 运行时实时 TTS 合成 + 进程缓存」，并在 requirement 文本里以一句话保留 stage-6 OSS 优化方向 + 恢复触发条件（worker + OSS 落地）。不直接 REMOVE，避免丢失 stage-6 设计意图。

「失败兜底」三个 scenario 从「预生成未完成 / OSS 下载失败 / 全部未 ready」改写为实时合成语境：「短语文本为空跳过 / TTS 合成异常跳过 / 全部 set 无可用文本则整通不再尝试」，兜底动作不变（无声等 reply、无万能垫词）。

### D3：web 详情页复用 BasicTab 绑定范式

`CampaignDetail.vue` 加 `filler_enabled` el-switch + `filler_delay_ms` el-input-number（`v-if="filler_enabled"`），直接复用 `BasicTab.vue:53-75` 的控件与 hint 文案、`CampaignBase` 既有字段、既有 PATCH `/campaigns/{id}` 通路。与 `greeting` 详情页（commit a2573be）同范式，无新 API、无新 schema。

## Risks / Trade-offs

- **[首轮垫词有 ~330ms 合成延迟]** → 进程级 LRU 缓存命中后 ~0ms；垫词文案短（≤60 字命中缓存阈值），首通首轮一次性成本，可接受。
- **[运营误开 filler 拖慢节奏]** → spec 已声明 streaming 主链路首音频 ~500ms、filler 仅慢模型建议开；hint 文案保留该提示；默认 `filler_enabled=false` 不变。
- **[单测回归]** → 现有断言「无 audio_url 即 skip」的用例与新行为冲突，必须同步改为「有 text 即可选」，否则红。属预期改动，不是风险外溢。

## Migration Plan

1. engine 改 `_pick_phrase` + docstring/注释；改单测。
2. web 改 `CampaignDetail.vue`。
3. spec delta 随 archive 合并。
4. 部署：engine SCP 覆盖 + restart（参 `[[feedback_ecs_deploy_scp]]`）；web 构建发布。无 migration、无数据变更，回滚即还原两文件。

## Open Questions

- 无。stage-6 OSS 路径恢复留作独立 change，不在本 change 决策范围。
