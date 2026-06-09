## Why

`filler-single-pool`（2026-06-09 archived）把垫词收成单池，但仍保留了独立的 `filler_phrase` 表 + `/filler-phrases` CRUD 端点 + per-phrase 的 `audio_url` / `generation_status`（stage-6 OSS 预录字段，v1.0 全程休眠）。

实际上垫词就是「一组短文本」，和 `silence_phrases` / `interruption_whitelist` / `wrap_up_closing_phrases` 完全同构 —— 那些都是 `campaign` 上的一个 `JSONB list[str]` 列，前端一行分号分隔输入、随 campaign PATCH 保存。垫词单独搞一张表 + 一套 CRUD 端点 + 休眠字段，是比那些更重的中间层。按 `[[feedback_avoid_multilayer_fallback]]`，把 `filler_phrase` 表也消除掉、收成 `campaign.filler_phrases: list[str]` 列，与既有短语类配置范式一致。

## What Changes

- **数据模型**：删除 `filler_phrase` 表（连同 `FillerPhrase` 模型/schema、`audio_url` / `generation_status` 休眠字段）；新增 `campaign.filler_phrases`（JSONB `list[str]`，default `[]`，与 `silence_phrases` 同范式）。
- **engine**：`FillerManager` 收 `list[str]`，随机抽文本、按文本去重（`CallSession.used_filler_phrases: set[str]`）；`RuntimeConfig.filler_phrases: list[str]` 直接读 `campaign.filler_phrases`；filler 事件不再带 `filler_phrase_id`（无消费方）。
- **api**：删除 `/filler-phrases` router；`filler_phrases` 变成 `CampaignBase` 的 `list[str]` 标量字段，随 campaign 聚合读写（campaign PATCH）走，不再是嵌套子节点。
- **web**：`FillerEditor` 改为单行分号分隔输入（`ExpandingTextarea`，参照打断白名单），绑 `form.filler_phrases`，随页面底部「保存」走 campaign PATCH；删 `api/fillers.ts`。
- **filler / data-model / web-admin-ui spec**：垫词存储改为 `campaign.filler_phrases` 列；选择按文本去重；删 stage-6 预录字段相关 requirement。

## Capabilities

### New Capabilities

<!-- 无新增能力 -->

### Modified Capabilities

- `filler`: 垫词存储从独立 `filler_phrase` 表收成 `campaign.filler_phrases: list[str]` 列；选择改为按文本随机不重复；删 `audio_url` / `generation_status` 预录字段与对应 requirement。
- `web-admin-ui`: per-campaign 垫词编辑从 `/filler-phrases` 即时 CRUD 改为一行分号输入随 campaign PATCH 保存（参照打断白名单）。

## Impact

- **isales-common**：删 `models/filler.py` + `schemas/filler.py` + `models/__init__` FillerPhrase 导出；`campaign.py` 加 `filler_phrases` 列；`schemas/campaign.py` 加 `filler_phrases: list[str]`；新 alembic migration（`f1a2b3c4d5e6` → `b2f3a4c5d6e7`：加 `campaign.filler_phrases` → 从 `filler_phrase.phrase` 回填 → drop `filler_phrase`；有损 downgrade 重建表）；version 0.8.3 → 0.8.4 + engine/api pin。
- **isales-engine**：`realtime/filler_manager.py`、`call_session.py`、`runtime_config.py`、`tests/test_filler_manager.py` + `test_run_loop.py`。
- **isales-api**：删 `routers/filler_phrases.py` + `main.py` include；`schemas.py`（删 FillerPhrase* DTO、filler_phrases 继承 CampaignBase）、`routers/campaigns.py`（删 FillerPhrase 子节点处理）、tests。
- **isales-web**：`components/Campaign/FillerEditor.vue`、删 `api/fillers.ts`、`types/campaign.ts` + `types/config.ts`、`views/Campaigns/CampaignDetail.vue`（去 `:campaign-id`）、tests。
- **specs**：`filler`、`web-admin-ui`（delta）；`data-model` 表目录（free-form，archive 合并：删 `filler_phrase` 行 + campaign 列表加 `filler_phrases(JSONB)`）。
- **承接 filler-single-pool**：本 change 进一步消除 `filler_phrase` 表层；3 句线上 dev 数据迁移进 `campaign.filler_phrases`。scheduler/worker/telephony 对 filler 零引用。
