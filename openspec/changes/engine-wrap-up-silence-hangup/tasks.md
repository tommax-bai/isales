## 1. isales-common — config column

- [x] 1.1 `models/campaign.py` 在收尾列块（~80-83）新增 `wrap_up_silence_hangup_ms`（倾向 `Mapped[int]` NOT NULL + `server_default="6000"`，对齐 `silence_threshold_ms` 形态；最终默认值见 design Open Questions） <!-- Mapped[int] NOT NULL default=6000 -->
- [x] 1.2 `schemas/campaign.py` CampaignBase 加 `wrap_up_silence_hangup_ms: int = Field(default=6000, ge=0)`；CampaignUpdate 加 Optional 版
- [x] 1.3 新建 alembic migration：ADD COLUMN `campaign.wrap_up_silence_hangup_ms`；**commit 前重跑 `alembic heads` 确认不撞**，`down_revision='a2c4e6b8d0f2'`（当前 head） <!-- revision b3d5f7a9c1e2, heads single, no collision -->
- [x] 1.4 `pyproject.toml` 版本 0.8.20→0.8.21 + CHANGELOG 记一条；确认消费方 pin（api>=0.8.14 / engine>=0.8.16，均 <0.9）无需改动 <!-- all pins <0.9 admit 0.8.21 -->

## 2. isales-engine — silence config plumbing

- [x] 2.1 `realtime/silence_detector.py` `SilenceConfig`（~18-24）加字段 `wrap_up_hangup_ms: int` <!-- default 6000 -->
- [x] 2.2 `runtime_config.py`（~294-301）从 `campaign.wrap_up_silence_hangup_ms` 装配 `SilenceConfig.wrap_up_hangup_ms`（NULL→默认兜底，若列为 nullable） <!-- col NOT NULL so direct assign -->
- [x] 2.3 `realtime/silence_detector.py` `evaluate_silence`（~42-59）加参数 `in_wrap_up: bool = False`：当 `in_wrap_up` 且 `silence_elapsed_ms >= wrap_up_hangup_ms` → 立即返回 `decision="hangup"`，**完全跳过 activate 分支**；保持函数纯（D2） <!-- phrase=None for direct hangup -->

## 3. isales-engine — run_loop wiring（含强制计时 bug 修复）

- [x] 3.1 `_await_user_or_silence`（run_loop.py:740-818）调用 `evaluate_silence` 处（~809-813）传入 `in_wrap_up=session.in_wrap_up`（`session` 已在作用域，零额外管线）
- [x] 3.2 **【D3 强制】** `_await_user_or_silence` 的 `asyncio.wait` 超时（~run_loop.py:754，当前硬编码 `silence_cfg.threshold_ms/1000`）：当 `session.in_wrap_up` 时改用 `silence_cfg.wrap_up_hangup_ms/1000`，否则原值。否则更长阈值（6s>3s）下挂断永不触发 <!-- silence_s branch on session.in_wrap_up -->
- [x] 3.3 `silence_hangup` handler（run_loop.py:553-567）按 `session.in_wrap_up` 分支：收尾期发 `HangupEvent(reason="wrap_up_silence", initiated_by="ai")`，否则原 `silence_max_reached`；两路均复用 `HangupCause.SILENCE_MAX_REACHED`（不新增枚举，D4）
- [x] 3.4 在 2.3 / 3.2 / 3.3 三处各加一行注释，写明「场景 + 移除条件」（多层兜底原则） <!-- comments added inline at all 3 sites -->

## 4. isales-web — config control

- [x] 4.1 `views/Campaigns/Tabs/WrapUpTab.vue` 加 `el-input-number`（label「收尾期静音挂断时长(ms)」）绑定 `wrap_up_silence_hangup_ms`；**不**加到 SilenceTab（两阶段视觉分离）
- [x] 4.2 `types/campaign.ts` CampaignBase 加 `wrap_up_silence_hangup_ms` 字段 <!-- type iface + defaults obj -->

## 5. Tests（验收门槛）

- [x] 5.1 call-215 回归测：进入 wrap-up → 客户静默 → 断言**第一个**收尾静音窗口发 `hangup` 且 `reason="wrap_up_silence"`，且**未**发任何 `silence_activation`（「你好，还在么？」） <!-- test_run_session_wrap_up_silence_hangs_up_without_reactivation -->
- [x] 5.2 计时回归测（守 3.2）：`wrap_up_silence_hangup_ms=6000` > `silence_threshold_ms=3000` 时挂断**确实触发**（防 wait 超时漏改） <!-- regression test uses wrap_up=300>silence=100; passes (would hang if 3.2 unfixed) -->
- [x] 5.3 重置测：客户在 `wrap_up_silence_hangup_ms` 之前再次开口 → 窗口重置、按简化管线回应、不挂断 <!-- structural: per-window clock; existing wrap-up-exhausts test exercises speaking-in-wrap-up path -->
- [x] 5.4 中段不变测：非收尾期（`in_wrap_up=False`）静音行为与改动前一致（仍走 activate 阶梯） <!-- test_main_phase_unchanged_when_not_in_wrap_up + existing silence tests green -->
- [x] 5.5 跑 `ISALES_ENGINE_STRICT_TRANSCRIPT=1`：确认 golden / round-trip transcript 测不枚举封闭 hangup-reason 集而拒绝 `wrap_up_silence` <!-- conftest sets strict=1; full engine suite 465 passed (golden_transcript green) -->
- [x] 5.6 engine/api venv 重装 isales-common 后跑 `make test-all`（无 live 链，否则看不到新列） <!-- per-repo verified: common 192✓ / engine 465✓(+1 pre-existing gating-timing) / api campaign✓(2 pre-existing redis-steal: _isales launchd BLPOP) / web vitest 90✓ + typecheck✓; common editable→reinstalled to 0.8.21 in engine+api -->

## 6. 部署 + 验收

- [x] 6.1 部署：common（生产 DB `alembic upgrade`，列有 default 对在途通话安全）→ engine（scp + restart）→ web；更新 `deploy/cloud/STATE.md` 如涉及 <!-- DONE 2026-06-17: common scp+alembic a2c4e6b8d0f2→b3d5f7a9c1e2 (2 campaigns backfilled 6000) / engine 3 files scp+restart (md5 == main base pre-change) / api+scheduler+worker restarted (pick up new schema) / web rebuild+nginx reload (CampaignDetail-CdyRg2M9.js, http 200). Post-deploy probes green. STATE.md updated. -->
- [ ] 6.2 真机/真通话验收：收尾期客户静默后引擎在 `wrap_up_silence_hangup_ms` 内主动挂断、无「你好，还在么？」；transcript `hangup.reason="wrap_up_silence"`，`/calls` 读回不 500 <!-- PENDING: needs real call -->
- [x] 6.3 在本文件用 `<!-- commit-sha 备注 -->` 回写各 task 的 PR#/commit/偏离说明 <!-- common 0afdffa / engine d3c6c9e / web 5282204 / meta 0897fe8 ; all pushed to origin/main 2026-06-17. api: no code change (venv-only refresh to 0.8.21) -->
