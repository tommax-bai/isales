## 1. Slice 1 — 引擎淡出 + 路径统一（核心 UX 修复，无 migration）

<!-- Slice 1 done. engine 59b2fae (ambient.py apply_fadeout + rtc_telephony.py fade/unify-pump + tests). -->
- [x] 1.1 在 `isales-engine/isales_engine/realtime/ambient.py` 增加纯 `array('h')` 淡出 helper `apply_fadeout(frames)`：对整段帧做 per-sample 线性下行增益斜坡到 0（首样满幅、末样静音），复用 `_clip16`，无 audioop 依赖。<!-- 改成 per-sample 线性而非 per-frame 指数：避免 inter-frame zipper + 精确落在 0 不残留 -->
- [x] 1.2 改 `rtc_telephony.py:_flush_playout(fadeout_ms=0)`：drain 全队列→`>0` 时取队首 `ceil(fadeout_ms/10)` 帧经 helper 淡出后 `put_nowait` 重新入队、丢弃其余；`==0` 保留原硬切（D5）。task_done 计数守恒（drain 全 done、faded 帧由 pump 补 done）
- [x] 1.3 `feed_playout` 的 `CancelledError` 分支调 `self._flush_playout(self._barge_in_fadeout_ms)`；`_CallState` 持 `_barge_in_fadeout_ms`
- [x] 1.4 统一出向路径（D3）：新增 `start_outbound_pump()`（idempotent，建 `playout_q`+起 pump）；`enable_ambient` 只设 bg reader/gain；`_outbound_loop` 改为**每帧**读 `ambient_reader`/`ambient_gain`（修「pump 先起、ambient 后开」捕获 bug）
- [x] 1.5 改 `audio_out()`：去掉 `if state.ambient_active` 分支，`start_outbound_pump()`+`feed_playout`；删直推 `push_audio` 旧分支；`configure_ambient` 无条件起 pump。顺手删死代码 `next_timestamp_ms`/`_outbound_ts`/`outbound_frame_ms`
- [x] 1.6 引擎默认常量 `DEFAULT_BARGE_IN_FADEOUT_MS = 100`，`_CallState._barge_in_fadeout_ms` 默认取它
- [x] 1.7 单测（test_ambient.py）：`apply_fadeout` 端点/不变量/empty；`_flush_playout(0)` 硬切；bare-pump（无 ambient）TTS 原样透传 + 无 cushion 首音不延迟
- [x] 1.8 单测：barge-in 后 pump 逐帧递减落静音（ambient 开→落背景值、关→落 0）；R1 cushion 仅 ambient 时生效
- [x] 1.9 `pytest -q` = 484 passed / 1 failed（`test_gate_fails_open_to_main_on_referee_timeout`，已 git-stash 验证 clean HEAD 同样失败 = pre-existing，与本改无关）

## 2. Slice 2 — campaign 配置列全栈（promote 旋钮）

<!-- Slice 2 done. common e1d8bf9 (0.8.23, model+schema+alembic f0a1b2c3d4e5) / engine 59b2fae (runtime_config+telephony setter+run_loop) / web ab2ae59 (type+InterruptionTab). api: no code change. -->
- [x] 2.1 `models/campaign.py`：新增 `barge_in_fadeout_ms: Mapped[int]`（`Integer`, 非空, `server_default="100"`，放打断段）
- [x] 2.2 `schemas/campaign.py`：`CampaignBase` 加 `barge_in_fadeout_ms: int = Field(default=100, ge=0)`（Read/Create 继承）；`CampaignUpdate` 加 `barge_in_fadeout_ms: int | None = Field(default=None, ge=0)`。test_schemas_dto 两处补字段
- [x] 2.3 alembic `f0a1b2c3d4e5`（down=c4e6a8b0d2f3 单 head，add column server_default 100，downgrade drop）；`alembic heads` 验证单 head 无撞
- [x] 2.4 bump common 0.8.22→0.8.23；engine `RuntimeConfig.barge_in_fadeout_ms`(默认100) + `load_runtime_config` 取 `campaign.barge_in_fadeout_ms`；run_loop 在 configure_ambient 后 `telephony.set_barge_in_fadeout(call, config.barge_in_fadeout_ms)`；`TelephonyClient.set_barge_in_fadeout` 基类 no-op + RtcTelephonyClient override 写 `state._barge_in_fadeout_ms`（mirror configure_ambient 模式）
- [x] 2.5 isales-api（api 7bc2ec4）：**`CampaignNestedUpdate` 是 hand-kept extra=forbid mirror（不继承 common CampaignUpdate）→ 必须手动补 `barge_in_fadeout_ms`，否则 PATCH 422**（STATE.md hotfix 教训，初判「无需改」是错的）。Create 继承 CampaignBase 自动有。campaign 测试 21 passed（另 2 失败=pre-existing redis-steal，已用 `redis-cli client list` 实证 3 个长寿命 BLPOP daemon 偷消息）
- [x] 2.6 isales-web：`types/campaign.ts` 加字段+默认 100；`InterruptionTab.vue` 在「与模式无关」段加「打断收声淡出(ms)」`el-input-number`（mode-independent）。vitest 90 passed + `vue-tsc --noEmit` 干净
- [x] 2.7 common 为 editable 安装（engine/api venv `Editable project location` 指向 sibling）→ 下游自动取新版，无需改 pin

## 3. 验证与部署

- [x] 3.1 各仓 pytest/vitest 已分别跑：common 192✓ / engine 484✓(1 pre-existing gating) / api campaign 21✓(2 pre-existing redis-steal) / web 90✓+typecheck✓
- [x] 3.2 `openspec validate engine-barge-in-fade-out --strict` 通过
- [x] 3.3 ECS 全栈部署完成：common 3 文件+migration → `alembic upgrade head`（`c4e6a8b0d2f3 → f0a1b2c3d4e5`，2 campaign 回填 100）；engine 5 文件（run_loop md5 部署前实证 == box `b43a53e0` == git c5a07df，无并行漂移；部署后 grep 验 prewarm 15 hits 仍在=未 clobber 并行 work）；api `schemas.py`；web rebuild（`CampaignDetail-86mBisvx.js`）+ nginx reload；engine/api/scheduler/worker 全重启 active。探针：engine `isales_engine_started`+`credentials_loaded count=6` 无 traceback、`DEFAULT_BARGE_IN_FADEOUT_MS=100`、`set_barge_in_fadeout` 在、`RuntimeConfig.barge_in_fadeout_ms` 在；api openapi 含 `barge_in_fadeout_ms`（PATCH 不 422）
- [x] 3.4 首音延迟无回归：设计上保证（cushion 仅 ambient 时启用，bare-TTS 路径 primed 立即放帧），已 `test_bare_pump_no_cushion_first_audio_not_delayed` 单测；活体延迟测量并入 §4 真机
- [x] 3.5 `deploy/cloud/STATE.md` 已更新（同 meta commit）

## 4. 真机验收（deferred — 同 pipeline-stream-realmachine-acceptance）

- [ ] 4.1 真机 mic 打断对比：硬切 vs 默认淡出（100ms）听感，确认人声平滑收敛、无爆音、像真人收声
- [ ] 4.2 真机回声 / AEC 复核：淡出尾音 + 背景底噪不引入自激（与 ambient-background-mix 真机回声验收同批）
- [ ] 4.3 archive：`/opsx:archive engine-barge-in-fade-out`
