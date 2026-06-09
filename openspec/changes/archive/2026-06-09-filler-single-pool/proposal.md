## Why

`filler`（垫词）当前是两层数据模型：`campaign → filler_set（多组，name + sort_order）→ filler_phrase（每组多条）`。多 `filler_set` 的唯一作用是按 `sort_order` 跨对话轮次轮询（spec § 多 filler_set 轮询 + § 集合内随机不重复 + Scenario「多 filler_set 不区分语义类型」）——spec 已明确禁止把多组当语义路由用，多组只是「分组与轮询单元」。

实际诉求里「垫词不重复」单靠一个池子组内随机不重复就已满足；跨组轮询只带来更复杂的配置心智（运营要先建组、命名，再往组里填词）和一层只服务于轮询的 `filler_set` 表 / 模型 / API / 前端组管理。按 `[[feedback-avoid-multilayer-fallback]]`「能去掉一层就去掉根因」，`filler_set` 是可消除的中间层：去掉它，`filler_phrase` 直挂 `campaign`，一个 campaign = 一个扁平垫词池。

## What Changes

- **数据模型**：删除 `filler_set` 表；`filler_phrase.filler_set_id` → `filler_phrase.campaign_id`（FK `campaign` ON DELETE CASCADE）。
- **engine**：`FillerManager` 去掉跨 `filler_set` 轮询，改为单池内随机不重复（call_session 维护单个 `used_filler_phrase_ids`，用尽清空）。`RuntimeConfig.fillers: list[FillerSetSpec]` → `filler_phrases: list[FillerPhraseSpec]`。
- **api**：`/filler-sets` CRUD（含嵌套 `/{id}/phrases`）整组替换为 `/filler-phrases` CRUD（按 `campaign_id`）；campaign 聚合读写的 `filler_sets` 子节点 → `filler_phrases`。
- **web**：`FillerEditor` 去掉「新增垫词组 / 组命名 / 删组」，改为单一扁平垫词列表；删除死代码 `FillerSetDialog.vue` + `FillerTab.vue`（详情页只用 `FillerEditor`）。
- **filler spec**：REMOVE「多 filler_set 轮询」；「集合内随机不重复」RENAME 为「垫词池随机不重复」并改写为单池语义；「失败兜底」场景去掉 filler_set 措辞。
- 不引入兜底层：无可用 `filler_phrase` 文本即「无声等 reply」，语义不变。

## Capabilities

### New Capabilities

<!-- 无新增能力 -->

### Modified Capabilities

- `filler`: 选择策略从「多 filler_set 按 sort_order 轮询 + 集合内随机不重复」收敛为「单 campaign 垫词池随机不重复」；删除 filler_set 分组与轮询语义。
- `web-admin-ui`: per-campaign 外呼策略配置中垫词持久化对象由 `filler_set / filler_phrase` 收敛为 `filler_phrase`（直挂 campaign），详情页编辑区由「组 + 词」两级降为单级词列表。

## Impact

- **isales-common**：`models/filler.py`（删 `FillerSet`、`FillerPhrase` 改 `campaign_id`）、`schemas/filler.py`（删 `FillerSet*`、`FillerPhrase` 改 `campaign_id`）、`models/__init__.py` 导出、新 alembic migration（破坏性：合并各组词入 campaign 池后 drop `filler_set`）、version 0.8.2→0.8.3 + engine/api pin 抬到 `>=0.8.3`。
- **isales-engine**：`realtime/filler_manager.py`、`call_session.py`、`runtime_config.py`、`run_loop.py`、`tests/test_filler_manager.py`。
- **isales-api**：`routers/filler_sets.py`→`routers/filler_phrases.py`、`main.py`、`routers/campaigns.py`、`schemas.py`、相关测试。
- **isales-web**：`components/Campaign/FillerEditor.vue`、删 `FillerSetDialog.vue` + `views/Campaigns/Tabs/FillerTab.vue`、`api/fillers.ts`、`types/config.ts`、`types/campaign.ts`、相关测试。
- **specs**：`filler`、`web-admin-ui`（delta）；`data-model` 表目录第 42-43 行 + `filler` 的 `## Data Schema` 索引块在 archive 合并时手工同步（free-form，非 Requirement，删 `filler_set` 行、`filler_phrase` 列改 `campaign_id`）。
- **破坏性 migration**：多组 campaign 的词会合并进单池，原 set 分组不可逆恢复（downgrade 尽力重建一个默认 set 兜住）。`scheduler` / `worker` / `telephony` 对 filler 零引用，不受影响。
