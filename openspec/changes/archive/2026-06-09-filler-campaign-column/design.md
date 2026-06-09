## Context

`filler-single-pool` 收成单池但保留了 `filler_phrase` 表（设计 D1 当时为保 `FillerEvent.filler_phrase_id` + stage-6 `audio_url`/`generation_status` + per-row CRUD）。用户决策（2026-06-09）：垫词改成一行分号输入、参照打断白名单 —— 即把垫词做成 `campaign` 上的 `list[str]` 列，UI 随 campaign PATCH 保存，彻底去掉表层。复核 D1 的三条保留理由在新需求下都不再成立：

1. `FillerEvent.filler_phrase_id` —— transcript 无强类型 FillerEvent，filler 事件只是 `full_transcript` 里的 dict，`filler_phrase_id` 无任何消费方（worker/transcript 均不读），改记文本即可。
2. `audio_url` / `generation_status` —— stage-6 OSS 预录字段 v1.0 全程休眠，属"为假想未来预留的死字段"，按 `[[feedback_avoid_multilayer_fallback]]` 应删；未来若上 OSS 预录由独立 change 重新设计承载结构。
3. per-row CRUD —— 分号输入天然是整列替换语义（参照 `interruption_whitelist`），per-row 端点反而别扭。

## Goals / Non-Goals

- **Goal**：垫词 = `campaign.filler_phrases: list[str]`，与 `silence_phrases` / `interruption_whitelist` 同构；UI 一行分号输入随 campaign PATCH。
- **Non-Goal**：不改 `filler_enabled` / `filler_delay_ms` 时间门控（仍是 campaign 标量列，正交）。
- **Non-Goal**：不为 stage-6 OSS 预录预留任何字段/分支（真要做时独立 change）。

## Decisions

### D1 — `campaign.filler_phrases: list[str]` JSONB 列

`campaign` 加 `filler_phrases: Mapped[list[Any]] = mapped_column(JSONB, nullable=False, default=list)`（与 `silence_phrases` 行为完全一致）。删 `filler_phrase` 表 + `FillerPhrase` 模型/schema。`CampaignBase.filler_phrases: list[str] = Field(default_factory=list)`；partial-update schema 加 `filler_phrases: list[str] | None`。

### D2 — engine 收 `list[str]`，按文本去重

`FillerManager.__init__(session, phrases: list[str], ...)`；`_pick_phrase`：`ready = [p for p in phrases if p.strip()]`，`unused = [p for p in ready if p not in used]`，空则 `used.clear()`，`random.choice(unused)`。`CallSession.used_filler_phrase_ids: set[int]` → `used_filler_phrases: set[str]`。删 `FillerPhraseSpec`。`append_event("filler", text=phrase, duration_ms=...)`（去 `filler_phrase_id`）。`RuntimeConfig.filler_phrases: list[str]`，`load_runtime_config` 读 `[str(p) for p in (campaign.filler_phrases or [])]`（与 `silence_phrases` 同写法）。

### D3 — api：filler_phrases 作 CampaignBase 标量字段

删 `routers/filler_phrases.py` + `main.py` include。`schemas.py` 删 `FillerPhraseNestedWrite` / `FillerPhraseRead`；`CampaignNestedCreate` 去掉 `filler_phrases` override（继承 `CampaignBase.filler_phrases: list[str]`）；`CampaignNestedUpdate` 改 `filler_phrases: list[str] | None`；`CampaignDetailRead` 去掉 override（继承）。`campaigns.py`：`_load_detail` 删 filler_phrase 查询（filler_phrases 随 campaign 列直出）；`_campaign_base_fields` excluded 去掉 `filler_phrases`（它现在是要存的 base 字段）；`_replace_children` 删 filler 分支；删 `FillerPhrase` import。

### D4 — web：一行分号输入（参照打断白名单）

`FillerEditor.vue` 改为单个 `ExpandingTextarea` 绑 `fillerText`（ref），`@change` 时 `form.filler_phrases = fillerText.split(/[;；\n]/).map(trim).filter(Boolean)`，`watch(form.filler_phrases)` 回填 `join("；")`（与 `InterruptionTab` 白名单逐字同范式）。去掉 `campaignId` prop 与 `fillersApi`（不再即时存，随底部「保存」走 campaign PATCH）。`CAMPAIGN_DEFAULTS` 加 `filler_phrases: []`（否则 `buildPayload` 白名单不发该字段）。`CampaignDetail.vue` 去掉 `<FillerEditor :campaign-id>`。删 `api/fillers.ts`。`types`：`CampaignBase.filler_phrases: string[]`，删 `FillerPhrase*` + 聚合 override + endpoint DTO。intro 保留 Info 图标（scoped，自包含，不依赖全局 tab-intro）。

### D5 — migration（有损 downgrade）

upgrade（`f1a2b3c4d5e6` → `b2f3a4c5d6e7`）：`campaign` 加 `filler_phrases` JSONB NOT NULL DEFAULT `'[]'` → `UPDATE campaign SET filler_phrases = (SELECT coalesce(jsonb_agg(fp.phrase ORDER BY fp.id), '[]') FROM filler_phrase fp WHERE fp.campaign_id = campaign.id)` → `DROP TABLE filler_phrase`。downgrade：重建 `filler_phrase` 表（id/campaign_id/phrase/audio_url(NULL)/generation_status('pending')/时间戳）→ 从 `campaign.filler_phrases` 数组逐元素 INSERT → drop 列。`audio_url`/`generation_status` 不可复原（本就休眠）。

## Risks / Trade-offs

- **又一次 drop 表**：`filler-single-pool` 刚建的 `filler_phrase` 表本 change 即删。可接受 —— 两步是同方向连续收敛（set→表→列），同 session 趁热做完（`[[feedback_large_change_momentum]]`），3 句线上数据随迁移保留。
- **失去 per-phrase 结构**：未来 OSS 预录需独立 change 重新设计；v1.0 无此需求，不预留死字段。
- **common 0.8.3 → 0.8.4** + engine/api pin 抬到 `>=0.8.4`。
