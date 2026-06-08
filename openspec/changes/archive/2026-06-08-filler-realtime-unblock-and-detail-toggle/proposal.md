## Why

当前 `filler` spec 要求垫词音频在拨打前由 worker 预生成到 OSS、运行时 MUST NOT 实时调用 TTS（spec.md Requirement「预生成 + 动态补充音频」）。但 v1.0 没有 OSS、也没有 `regenerate_filler_audio` worker，`filler_phrase.audio_url` 永远为 NULL、`generation_status` 永远停在 `pending`。而 engine 的实装恰恰相反：`filler_manager._stream_audio` 早已走实时 TTS 合成 `phrase.text`（外包一层进程级 LRU 缓存 `CachingTTSProvider`），根本不读 `audio_url`。

两者矛盾的后果是：`filler_manager._pick_phrase`（filler_manager.py:131）的选取门槛 `generation_status == READY and p.audio_url` 在 v1.0 永远不可能满足 → 每轮都 `filler_skip_no_ready_phrase` → **即使运营在 web 打开 `filler_enabled` 也永远播不出垫词**。这是把 stage-6（OSS 预录）的判断混进 stage-4（实时合成）主路径造成的隐式锁死，属于 `[[feedback-avoid-multilayer-fallback]]` 所指的残留逻辑。

此外，`filler_enabled` / `filler_delay_ms` 开关目前只在 campaign 编辑页（`BasicTab.vue`）暴露，客户面详情页 `CampaignDetail.vue` 没有（`greeting` 已于 commit a2573be 补入详情页，filler 未跟上），运营在详情页看不到垫词是否开启。

## What Changes

- **engine**：`filler_manager._pick_phrase` 选取门槛改为只要求 `phrase.text` 非空，移除对 `audio_url` 非空与 `generation_status == READY` 的硬依赖，让 v1.0 实时合成路径能正常触发垫词。
- **filler spec**：修订「预生成 + 动态补充音频」与「失败兜底」两条 requirement——把 v1.0 主路径明确为「运行时实时 TTS 合成 + 进程级缓存」，OSS 预生成降级为 stage-6 可选优化（带明确的「何时恢复 audio_url 优先分支」触发条件，不提前实现）。
- **web**：`CampaignDetail.vue` 增加 `filler_enabled` 开关 + `filler_delay_ms`（开关开启时显示），与 `BasicTab.vue` / `greeting` 详情页范式对齐。
- 不引入任何「万能兜底垫词」，失败兜底仍是「跳过垫词、无声等 reply」。

## Capabilities

### New Capabilities
<!-- 无新增能力 -->

### Modified Capabilities
- `filler`: 垫词音频来源 requirement 从「预生成到 OSS + 运行时禁止 TTS」改为「v1.0 运行时实时 TTS 合成 + 进程缓存为主路径，OSS 预生成为 stage-6 可选」；选取与失败兜底 requirement 改为以 `phrase.text` 可用性为判据，不再以 `audio_url` ready 为门槛。
- `web-admin-ui`: campaign 详情 view 增加垫词开关 + 触发延迟的展示与编辑（与 greeting 一致落在客户面详情页）。

## Impact

- **isales-engine**：`isales_engine/realtime/filler_manager.py`（`_pick_phrase` 选取逻辑 + docstring/注释）；相关单测 `tests/` 中断言「无 audio_url 即 skip」的用例需更新为「有 text 即可选」。
- **isales-web**：`src/views/Campaigns/CampaignDetail.vue`（新增 filler 开关 + 延迟控件，复用 `BasicTab.vue` 既有绑定）。
- **specs**：`openspec/specs/filler/spec.md`、`openspec/specs/web-admin-ui/spec.md`。
- **无 schema / migration 变更**：`filler_enabled` / `filler_delay_ms` / `audio_url` / `generation_status` 字段均已存在。
- **关联但不合并**：`tts-cache-and-gated-filler`（active，21/27）加的是时间门控（§B）与缓存，本 change 解的是更早的 `audio_url` 选取门槛锁死，互不冲突。
