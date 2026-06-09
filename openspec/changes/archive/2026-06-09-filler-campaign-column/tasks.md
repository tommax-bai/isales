# Tasks — filler-campaign-column

> Done 2026-06-09. SHAs: common `fa57f6d` / engine `9a3c208` / api `9c23a80` /
> web `eeae194` / meta (this). Deployed to ECS (alembic `f1a2b3c4d5e6 →
> b2f3a4c5d6e7`); smoke green (filler_phrase table dropped, 3 phrases migrated to
> `campaign.filler_phrases = ["嗯","啊","嗯嗯"]`, /filler-phrases 404, SPA 200).

## 1. isales-common <!-- fa57f6d -->

- [x] 1.1 `models/campaign.py`：加 `filler_phrases: Mapped[list[Any]] = mapped_column(JSONB, nullable=False, default=list)`
- [x] 1.2 `schemas/campaign.py`：`CampaignBase` 加 `filler_phrases: list[str]`；partial-update 加 `filler_phrases: list[str] | None`
- [x] 1.3 删 `models/filler.py` + `schemas/filler.py`；`models/__init__.py` 去 `FillerPhrase`
- [x] 1.4 alembic `b2f3a4c5d6e7`（down `f1a2b3c4d5e6`）：加 `campaign.filler_phrases` → 回填 jsonb_agg(filler_phrase.phrase) → drop filler_phrase；有损 downgrade
- [x] 1.5 `pyproject.toml` 0.8.3 → 0.8.4（engine/api pin → `>=0.8.4`）
- [x] 1.6 pytest 185 passed（修 test_schemas_dto fixture 加 filler_phrases）

## 2. isales-engine <!-- 9a3c208 -->

- [x] 2.1 `filler_manager.py`：删 `FillerPhraseSpec`；`FillerManager(session, phrases: list[str])`；按文本随机不重复；`append_event` 去 `filler_phrase_id`
- [x] 2.2 `call_session.py`：`used_filler_phrase_ids: set[int]` → `used_filler_phrases: set[str]`
- [x] 2.3 `runtime_config.py`：`RuntimeConfig.filler_phrases: list[str]`；读 `[str(p) for p in (campaign.filler_phrases or [])]`
- [x] 2.4 `tests/test_filler_manager.py` 重写（list[str] 单池）；`test_run_loop.py` + `test_state_machine.py` 修
- [x] 2.5 pytest 398 passed（1 pre-existing gate 失败，干净 HEAD 同 fail，无关）

## 3. isales-api <!-- 9c23a80 -->

- [x] 3.1 删 `routers/filler_phrases.py` + `main.py` include
- [x] 3.2 `schemas.py`：删 `FillerPhraseNestedWrite`/`FillerPhraseRead` + GenerationStatus import；`CampaignNestedCreate`/`CampaignDetailRead` 去 override（继承 list[str]）；`CampaignNestedUpdate` 改 `list[str] | None`
- [x] 3.3 `routers/campaigns.py`：删 `FillerPhrase` import + `_load_detail` 查询 + `_replace_children` 分支 + excluded 去 `filler_phrases`
- [x] 3.4 tests 修（filler_phrases 作 base 字段 list[str]；删 /filler-phrases 测试 + DB cascade FillerPhrase 检查）
- [x] 3.5 pytest filler+campaign 全绿（2 pre-existing redis-steal 环境失败无关）

## 4. isales-web <!-- eeae194 -->

- [x] 4.1 `FillerEditor.vue`：单 `ExpandingTextarea` 绑 `form.filler_phrases`（分号 split/join `[;；\n]`，@change commit，仅 `filler_enabled` 时显示）；去 `campaignId` + `fillersApi`；保留 Info-icon intro
- [x] 4.2 删 `api/fillers.ts`
- [x] 4.3 `types/campaign.ts`：`CampaignBase.filler_phrases: string[]` + `CAMPAIGN_DEFAULTS`；删 `FillerPhrase*` + 聚合 override。`types/config.ts`：删 `FillerPhrase*` + 清 GenerationStatus import
- [x] 4.4 `CampaignDetail.vue`：`<FillerEditor>` 去 `:campaign-id`
- [x] 4.5 typecheck + eslint + vitest 17/74 + build 全绿（修 campaignDetail.test filler_phrases 现入 payload）

## 5. specs

- [x] 5.1 `specs/filler/spec.md` delta：MODIFIED「垫词池随机不重复」(按文本去重)；RENAMED「预生成 + 动态补充音频」→「运行时合成垫词音频」+ MODIFIED（删 audio_url/generation_status）；MODIFIED「失败兜底允许无声延迟」
- [x] 5.2 `specs/web-admin-ui/spec.md` delta：MODIFIED「per-campaign 外呼策略配置」（垫词改 campaign PATCH 分号输入 + 新 scenario）
- [x] 5.3 `openspec validate filler-campaign-column --strict` 绿
- [x] 5.4 archive 合并：`filler/spec.md` Data Schema + `data-model/spec.md` 表目录（删 filler_phrase 行 + campaign 加 filler_phrases(JSONB)）

## 6. 收口

- [x] 6.1 四仓测试绿（2 处 pre-existing/环境失败已甄别，与本 change 无关）
- [x] 6.2 commit + push：common / engine / api / web + meta
- [x] 6.3 ECS：pg_dump（`/opt/isales/backups/filler-campaign-column-20260609-162838.sql`）→ alembic upgrade → restart 全队列 → smoke 绿；web build（HEAD `9853730`，顺带 ship 用户 persona 工作）→ rsync → nginx reload → SPA 200（备份 `web-filler-campaign-column-*.tgz`）
- [x] 6.4 `deploy/cloud/STATE.md` 更新 alembic head + 部署条目
- [x] 6.5 archive change + memory
