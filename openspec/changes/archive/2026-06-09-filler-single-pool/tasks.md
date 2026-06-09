# Tasks — filler-single-pool

> Done 2026-06-09. SHAs: common `17adb31` / engine `e91834b` / api `47b193e` /
> web `7280b03` / meta (this). Deployed to ECS (alembic `c9d0e1f2a3b4 →
> f1a2b3c4d5e6`); smoke green (filler_set dropped, 3 phrases preserved with
> campaign_id, /filler-phrases 401, /filler-sets 404, SPA 200).

## 1. isales-common — 数据模型收敛 <!-- 17adb31 -->

- [x] 1.1 `models/filler.py`：删 `FillerSet`；`FillerPhrase.filler_set_id` → `campaign_id`（FK campaign ondelete CASCADE, index）
- [x] 1.2 `schemas/filler.py`：删 `FillerSet*`；`FillerPhraseCreate/Read.filler_set_id` → `campaign_id`
- [x] 1.3 `models/__init__.py`：导入 + `__all__` 去掉 `FillerSet`
- [x] 1.4 alembic `f1a2b3c4d5e6`（down_rev `c9d0e1f2a3b4`）：add campaign_id → 回填 FROM filler_set → NOT NULL + FK + index → drop filler_set_id → drop filler_set；downgrade 有损重建默认 set
- [x] 1.5 `pyproject.toml` 0.8.2 → 0.8.3（engine/api pin → `>=0.8.3`）
- [x] 1.6 pytest 185 passed

## 2. isales-engine — 单池 FillerManager <!-- e91834b -->

- [x] 2.1 `realtime/filler_manager.py`：删 `FillerSetSpec`；`FillerManager(session, phrases, ...)`；`_pick_phrase` 单池 random-no-repeat；删 `_sorted_sets`
- [x] 2.2 `call_session.py`：→ 单个 `used_filler_phrase_ids: set[int]`
- [x] 2.3 `runtime_config.py`：`RuntimeConfig.filler_phrases`；load `FillerPhrase.where(campaign_id==)`
- [x] 2.4 `run_loop.py`：`FillerManager(session, config.filler_phrases, ...)`
- [x] 2.5 `tests/test_filler_manager.py` 重写（单池不重复 + 用尽重置 + per-call）；`test_run_loop.py` 修构造
- [x] 2.6 pytest 399 passed（1 pre-existing 失败 `test_gate_fails_open_to_main_on_referee_timeout`，干净 HEAD 同样 fail，与本 change 无关）

## 3. isales-api — /filler-phrases <!-- 47b193e -->

- [x] 3.1 `routers/filler_sets.py` → `routers/filler_phrases.py`：`/filler-phrases` CRUD 按 `campaign_id`
- [x] 3.2 `main.py`：include `filler_phrases.router`
- [x] 3.3 `schemas.py`：删 `FillerSet*`；`FillerPhraseRead.campaign_id`；campaign 聚合 `filler_sets` → `filler_phrases`
- [x] 3.4 `routers/campaigns.py`：`_load_detail` / `_campaign_base_fields` / `_replace_children` / create / update
- [x] 3.5 pytest（filler + campaign CRUD 全绿；2 pre-existing 失败 = legacy launchd isales-scheduler BLPOP 偷 redis 测试消息，环境问题与本 change 无关）

## 4. isales-web — 扁平垫词编辑器 <!-- 7280b03 -->

- [x] 4.1 `FillerEditor.vue`：单一扁平垫词列表（删组管理）
- [x] 4.2 删 `FillerSetDialog.vue` + `FillerTab.vue` + `fillerSetDialog.test.ts`（死代码）
- [x] 4.3 `api/fillers.ts` → `/filler-phrases`
- [x] 4.4 `types/config.ts` + `types/campaign.ts`：删 `FillerSet*`；`filler_set_id` → `campaign_id`；聚合 `filler_sets` → `filler_phrases`
- [x] 4.5 typecheck + eslint + vitest 16/65 + prod build 全绿

## 5. specs

- [x] 5.1 `specs/filler/spec.md` delta：REMOVE「多 filler_set 轮询」；RENAME「集合内随机不重复」→「垫词池随机不重复」+ MODIFIED；MODIFIED「失败兜底允许无声延迟」
- [x] 5.2 `specs/web-admin-ui/spec.md` delta：MODIFIED「per-campaign 外呼策略配置」filler_set → filler_phrase（+ 单池垫词列表 scenario）
- [x] 5.3 `openspec validate filler-single-pool --strict` 绿
- [x] 5.4 archive 合并时：`data-model/spec.md` 表目录删 `filler_set` 行 + `filler_phrase` 列改 `campaign_id`；`filler/spec.md` `## Data Schema` 块同步

## 6. 收口

- [x] 6.1 四仓测试绿（2 处 pre-existing/环境失败已甄别，与本 change 无关）
- [x] 6.2 commit + push：common / engine / api / web + meta
- [x] 6.3 ECS 部署：pg_dump 兜底（`/opt/isales/backups/filler-single-pool-20260609-153716.sql`）→ alembic upgrade → restart 全队列 → smoke 绿；web build → rsync → nginx reload → SPA 200（备份 `web-filler-single-pool-20260609-153913.tgz`）
- [x] 6.4 `deploy/cloud/STATE.md` 更新 alembic head + 部署条目
- [x] 6.5 archive change + 更新 memory
