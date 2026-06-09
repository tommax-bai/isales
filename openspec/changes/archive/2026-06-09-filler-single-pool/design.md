## Context

垫词两层模型（`filler_set` → `filler_phrase`）落地于 `web-admin-campaign-workflow`。运行期 `FillerManager` 按 `sort_order` 跨 set 轮询、set 内随机不重复（filler_manager.py:122-152）。`filler` spec 第 57-60 行明确：多 set **MUST NOT** 承载 thinking/confirming/casual 语义，仅作分组与轮询单元。即 `filler_set` 层除「跨轮换池」外不携带任何业务信息。

用户决策（2026-06-09）：收成单组，组内多条即可。落地取「彻底拆掉组层」而非「保留表锁定单组」，因为后者会留下一张永远只有 1 行、不携带语义的 `filler_set` 表 —— 正是 `[[feedback-avoid-multilayer-fallback]]` 要消除的中间层。

## Goals / Non-Goals

- **Goal**：`filler_phrase` 直挂 `campaign`，运行期单池随机不重复，前后端去掉「组」概念。
- **Goal**：行为对运营透明 —— 仍是「该 campaign 配若干句垫词，触发时随机播一句、同通不重复」。
- **Non-Goal**：不引入任何按场景/语义选词的路由（spec 本就禁止；本 change 只是删掉为轮询服务的分组层，不新增选择维度）。
- **Non-Goal**：不动 `filler_enabled` / `filler_delay_ms` 时间门控（campaign 列字段，与本 change 正交）。
- **Non-Goal**：不动 stage-6 OSS 预录路径的休眠状态（`audio_url` / `generation_status` 字段保留在 `filler_phrase` 上）。

## Decisions

### D1 — `filler_phrase` 直挂 `campaign`，删 `filler_set` 表

`filler_phrase.filler_set_id`（FK filler_set）→ `filler_phrase.campaign_id`（FK campaign，ON DELETE CASCADE，index）。`filler_set` 表整张删除。`filler_phrase` 其余列（`phrase` / `audio_url` / `generation_status`）不变 —— 保留 `filler_phrase` 表（而非塌成 `campaign.filler_phrases` JSONB 字符串数组），因为：

1. `transcript.FillerEvent.filler_phrase_id` 仍引用稳定的 phrase id；
2. `audio_url` / `generation_status` 是 stage-6 OSS 预录字段，未来恢复时仍挂在 phrase 行上；
3. CRUD 端点与 web 编辑器按行增删改的范式不变，改动面最小。

### D2 — 运行期单池随机不重复

`CallSession.used_filler_phrase_ids_per_set: dict[int, set[int]]` + `current_filler_set_index: int` → 单个 `used_filler_phrase_ids: set[int]`。`FillerManager.__init__(session, phrases: list[FillerPhraseSpec], ...)`（不再收 sets）。`_pick_phrase`：`ready = [p for p in phrases if p.text.strip()]`；`unused = [p for p in ready if p.id not in used]`；空则 `used.clear()` 后整池重抽；`random.choice(unused)`。`FillerSetSpec` 删除，`RuntimeConfig.fillers` → `filler_phrases`。

### D3 — API：`/filler-sets` → `/filler-phrases`

phrase CRUD 直接按 `campaign_id`：`GET /filler-phrases?campaign_id=`、`POST /filler-phrases`（body 带 campaign_id）、`PATCH /filler-phrases/{id}`、`DELETE /filler-phrases/{id}`。campaign 聚合（`CampaignDetailRead` / `CampaignNestedCreate` / `CampaignNestedUpdate`）子节点 `filler_sets`（嵌套 phrases）→ 扁平 `filler_phrases: list[FillerPhraseNestedWrite|Read]`。`_replace_children` 的 filler 分支由「删 set（CASCADE 带走 phrase）→ 逐 set 建 + 逐 phrase 建」改为「删该 campaign 全部 filler_phrase → 逐 phrase 建（campaign_id=campaign_id）」。

### D4 — 破坏性 migration（合并入池）

upgrade：`filler_phrase` 加 `campaign_id`（先 nullable）→ `UPDATE ... FROM filler_set` 回填 → `SET NOT NULL` + FK + index → drop `filler_phrase.filler_set_id`（连带其 FK/index）→ `DROP TABLE filler_set`。多组 campaign 的所有 phrase 在此合并进同一 campaign 池（即用户要的效果）。

downgrade（**有损**，仅保证结构可回退、不保证还原分组）：重建 `filler_set` 表 → 给每个出现过的 `campaign_id` 建 1 个默认 set（name=`默认垫词组`，sort_order=0）→ `filler_phrase` 加回 `filler_set_id` 指向该默认 set → drop `campaign_id`。原始多组结构无法重建，迁移注释写明。

### D5 — web：扁平垫词列表

`FillerEditor.vue` 删 `addSet` / `onRenameSet` / `removeSet` / 「新增垫词组」按钮 / 按 set 分组的 `<article>`，改为一个 campaign 级扁平 phrase 列表（add / save / remove 单句）。`fillersApi` 改 `/filler-phrases`（list/create/update/remove 按 campaign_id 或 phrase id）。死代码 `FillerSetDialog.vue`（旧 dialog 范式，未被 CampaignDetail 引用）+ `FillerTab.vue`（唯一引用 FillerSetDialog 的死 tab）删除，连同其单测。`types/config.ts` + `types/campaign.ts` 删 `FillerSet*`、`FillerPhrase*.filler_set_id` → `campaign_id`、campaign 聚合 `filler_sets` → `filler_phrases`。

## Risks / Trade-offs

- **数据不可逆合并**：已配多组的 campaign 在 upgrade 后 set 边界消失。可接受 —— spec 本就规定多组无语义，合并不丢业务信息；downgrade 仅作结构兜底。
- **跨 4 仓 + common 版本联动**：common 0.8.2→0.8.3，engine/api pin 抬到 `>=0.8.3`。本地 editable install 自动生效，ECS 走 scp 覆盖 + alembic upgrade。同 session 一并完成（`[[feedback-large-change-momentum]]`）。
- **轮换均匀性**：单池 random-no-repeat 在「池内全用过→清空重抽」边界处理与原 set 内逻辑一致，多轮通话垫词仍不连续重复；去掉的只是「跨组确定性轮转」，对运营无感。

## Migration

新增 `isales-common` migration（down_revision = 当前 head `c9d0e1f2a3b4`），revision id 取一个未占用的滚动 id（写前 `grep` 全量校验不撞，见 `[[feedback_alembic_revision_id_collision]]`）。部署侧：ECS `alembic upgrade head` 前先 `pg_dump` `filler_set` + `filler_phrase` 兜底，再 restart `isales-api` + `isales-engine`。
