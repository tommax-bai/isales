# Tasks — silence-drop-no-progress-timeout

<!-- common 5f8ef48 / engine 0fdfc39 / api 91f5794 / web 85a6c1f -->

## 1. isales-common（model + schema + migration）

- [x] 1.1 `models/campaign.py`：删 `max_no_progress_seconds` 列
- [x] 1.2 `schemas/campaign.py`：删 `CampaignBase.max_no_progress_seconds` + `CampaignUpdate.max_no_progress_seconds`
- [x] 1.3 新 alembic migration `d5e6f7a8b9c0`（down_revision `c4d5e6f7a8b9`）：upgrade drop_column / downgrade add_column。单一线性 head 确认
- [x] 1.4 `tests/test_schemas_dto.py`：删两处 `max_no_progress_seconds` fixture 键（已随 prune 3bd1815 一并落地）
- [x] 1.5 `HangupCause.NO_PROGRESS_TIMEOUT` 保留 + 加注释（内部异常兜底 cause）
- [x] 1.6 version 0.8.5→0.8.6 + CHANGELOG；`pytest` 182 passed

## 2. isales-engine（删计时器机制）

- [x] 2.1 删 `isales_engine/realtime/no_progress_timer.py`
- [x] 2.2 `run_loop.py`：删 import + `last_progress_ms` 起算/复位 + 计时器分支（非 `user_final` 直接 `continue`）
- [x] 2.3 `runtime_config.py`：删 `RuntimeConfig.max_no_progress_seconds` 字段 + 装配赋值
- [x] 2.4 `settings.py`：删 `engine_max_no_progress_seconds`
- [x] 2.5 run_loop:209 + dial_consumer:160 异常兜底 `NO_PROGRESS_TIMEOUT` 保留
- [x] 2.6 tests：删 `test_realtime_detectors` no_progress 段 + import；`test_run_loop` 去 kwarg。`test_run_session_contract` no_progress_timeout 保留（枚举仍有效）
- [x] 2.7 `pytest` 396 passed（1 pre-existing gate fail 无关，已 stash 验证）

## 3. isales-api（schema）

- [x] 3.1 `isales_api/schemas.py` `CampaignNestedUpdate`：删 `max_no_progress_seconds`
- [x] 3.2 `pytest` campaign CRUD/configs 绿（2 pre-existing redis-steal fail 无关，已 stash 验证）

## 4. isales-web（UI）

- [x] 4.1 `src/types/campaign.ts`：删 `CampaignBase.max_no_progress_seconds` + `CAMPAIGN_DEFAULTS`
- [x] 4.2 `SilenceTab.vue`：删「无进展超时 (s)」form-item；挂断兜底语 hint 明确「直接挂断；留空不播话术」
- [x] 4.3 typecheck + eslint + vitest 75 + build 全绿

## 5. specs（delta，本 change 内）

- [x] 5.1 `silence-activation`：MODIFIED「与其他模块的优先级」
- [x] 5.2 `call-state-machine`：MODIFIED「关键状态转换」+「真硬件 URC 驱动状态转换」
- [x] 5.3 `data-model`：MODIFIED「表归属与全表清单」
- [x] 5.4 `openspec validate --strict` 通过

## 6. 部署 + 收口

- [x] 6.1 commit + push 4 sub-repo（已推 origin）+ meta
- [x] 6.2 ECS 部署：scp common+engine+api editable 源码 → 先重启全队列 → `alembic upgrade head`（仅 d5e6f7a8b9c0）。ECS head `c4d5e6f7a8b9 → d5e6f7a8b9c0`
- [x] 6.3 web build → rsync dist → nginx reload（entry `index-DgcL657t.js`）
- [x] 6.4 smoke：列已 drop / openapi 无该字段 / 4 服务 active+clean / `/health` 200 / 公网 SPA 200
- [x] 6.5 更新 `deploy/cloud/STATE.md`
- [x] 6.6 `openspec archive silence-drop-no-progress-timeout`
