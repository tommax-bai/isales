# cloud deployment — current state snapshot

**Last updated**: 2026-06-11 10:42 CST — **per-role-llm-config-and-restructure-card deployed**（common + engine + api + web 全栈，**无 alembic**）。让每个 AI 角色（role_config）的 LLM provider/model 真正端到端生效 + 补 webui 缺失的「重组(restructure)」配置卡。**根因**：引擎为整进程建单一全局 LLM（`main.py` `build_llm(engine_llm_provider)`），所有 slot（main/persona/referee/restructure）的 PipelineStream 都复用它、`chat_stream` 只透传 temp/top_p、从不读 `spec.model`/`ext_params.provider` → 运营在角色卡选的 provider/model 一直是摆设；restructure 引擎已支持但前端无入口（唯一 `RoleConfigDialog` 在未挂载孤儿 `RoleConfigTab`）。**改法**：①common `_SlotSpec` 加 `provider` 字段（SSOT=`role_config.ext_params.provider`）+ `RestructureSpec.label` 改可选；②engine 新 `providers/llm_registry.py` `LLMRegistry`：`resolve(provider,model)` 惰性 `build_llm(...,model=)` + 按 `(provider,model)` 缓存 + **单层**全局回落（provider 空/缺凭据→WARN `llm_slot_provider_fallback`+用默认，不中断通话），`runtime_config._spec_for` 读 ext_params.provider 进 spec，`run_loop`/`orchestrator` 6 调用点 + `start()` per-referee 经 registry 解析 client，per-call `aclose_all`；③api `routing_validation` 去掉 `RESTRUCTURE` 的 label 必填；④web `CampaignDetail` 加 restructure singleton 卡（无 label / RefreshCw / gray）。transfer-LLM 仍用全局默认（Non-Goal）。extractor 在 worker+mock，ExtractorSpec 已带 provider，worker 接真 LLM 时再 honor（本期引擎不动）。**无 alembic**（provider 复用既有 ext_params JSONB，model 列已存在）。**部署**：scp common(pipeline.py)+engine(main/run_loop/runtime_config/orchestrator + 新 llm_registry.py)+api(routing_validation.py) editable 源码（current=releases/20260517-222944，engine+api 共用 venv，common editable 一处两端生效）→ ast-parse + import smoke（`LLMRegistry` import OK + `_SlotSpec.provider=True`）→ 重启 engine+api。web build（entry `index-BlidkFk7.js`，`CampaignDetail-BWfEagoV.js` 含重组卡）→ scp `dist/{assets,index.html}` → `/var/www/isales-web`（未 rsync --delete，旧 hashed assets 留存无害）。**smoke**：engine `cloud_edge_grpc_server_started`+`credentials_loaded count=5 providers=['dashscope','volcengine']`+`isales_engine_started` clean、api active、nginx `/`→200、index.html 引用新 bundle。commit common `0c48d5a`(0.8.8→0.8.9) / engine `87cc26f` / api `5523f7b` / web `cc516ba` / meta（本条提交）。测试：common 10(pipeline) / engine **405 passed**（+8 新 `test_llm_registry`；1 pre-existing gate `test_gate_fails_open_to_main_on_referee_timeout` 失败无关，stash 验证 clean tree 同红）/ api routing 20（含新 restructure-no-label；2 pre-existing redis-steal 无关，stash 验证）/ web **88** + vue-tsc clean。**⚠️ 行为变化**：per-slot model 从「被忽略」变「生效」——运营既有 campaign 角色的 provider/model 选择从此真生效；provider 未配的 slot 仍走全局默认（行为不变），只有显式配了非默认 provider 的 slot 才切换。**真机验收（tasks 5.2/5.3）待做**：配非默认 provider 的 slot 看 `llm_slot_provider_fallback`/resolution 日志 + 建 restructure 卡 + 路由规则 → barge-in 验重组真触发（需 mac 拨测）。**openspec `per-role-llm-config-and-restructure-card` 待 archive**。**回滚**：scp 旧源码（engine 各文件 + `rm llm_registry.py`、common pipeline.py、api routing_validation.py）+ 重启 engine+api + web 重 build 前一 commit 重新 scp（本次无 tgz 备份）+ nginx reload（无 alembic 无 DB 回滚）。

Prior: 2026-06-11 10:08 CST — **打断配置 模式切换改单按钮 + 非高级→普通模式 改名 deployed**（web only，纯表现层）。承接前一条 interruption-min-chars-and-mode-toggle：把「打断配置」卡的两段 segmented control（高级设置 ∣ 非高级设置）改成**单个切换按钮**——当前普通模式按钮显示「切换到高级模式」、当前高级模式显示「切换到普通模式」，旁加「当前：X模式」el-tag 指示；`非高级设置`→`普通模式`、`高级设置`→`高级模式` 全量改名（hint / 确认弹窗 / 注释 / 测试名）。默认仍普通模式（`interruption_rules==null` 哨兵）。**模式互斥语义 / 切回普通的 edited-tree 确认守卫 / seed 逻辑均不变，纯表现层**；无 api/engine/DB/schema 改动。**部署**：web build（HEAD `72763bd`，entry `index-C7mTywFH.js`→`index-DqEixk15.js`）→ rsync `--delete` dist → nginx reload，备份 `/opt/isales/backups/web-mode-toggle-button-20260611-100833.tgz`，公网 SPA 200。测试：vitest 87 + vue-tsc + build 全绿。commit web `72763bd`。**非 openspec 行为变更**（web-admin-ui spec「两段互斥模式切换」行为仍成立；widget=button vs segmented + 标签 普通/高级 属面板内部表现、spec 不 pin；同 门控路由/旁路监管 纯显示串改名先例）。**回滚**：rsync 回 `web-mode-toggle-button-20260611-100833.tgz` + nginx reload。

Prior: 2026-06-10 17:45 CST — **interruption-min-chars-and-mode-toggle deployed**（common + engine + api + web 全栈）。把 barge-in 缺省默认树的「最小打断字数」门控从 engine 硬编码 `default_rule(min_text_length=2)` 提升为 Campaign 级可配字段 `campaign.interruption_min_chars`（int, NOT NULL, server_default 2, ge≥1），与 `interruption_min_duration_ms` 对称；**仅在 `interruption_rules` 为 NULL（非高级模式）时被 engine 读取合成默认树**，配了显式规则树（高级模式）忽略该列。web 端：「打断保护」卡改名「**打断配置**」+ 把原来 divider 并排的 basic/advanced 改成**互斥模式切换**「高级设置 ∣ 非高级设置」（由 `interruption_rules==null` 哨兵派生）：非高级配 白名单/最小时长/**最小打断字数**，高级配规则树，`最大连续打断`+`连续打断策略` 移到切换器下方常显；切回非高级会清空规则树（仅在树被编辑过时弹确认，controlled radio 取消回弹）。**alembic `e6f7a8b9c0d1 → f7a8b9c0d1e2`**（纯加性 ADD COLUMN，`server_default="2"` 回填存量行，NOT NULL 无 NULL 窗口、非破坏；downgrade 干净 drop）。common 0.8.7→0.8.8。**部署**：**先 scp 单 migration 文件 → `alembic upgrade head`（加列、server_default 回填；旧在跑服务的 ORM SELECT 不含新列故零影响）→ 再 scp common(campaign model+schema+pyproject)+engine(runtime_config 读列 / run_loop 注释同步)+api(schemas CampaignNestedUpdate 加字段) editable 源码 → chown isales:isales → 重启 engine+api+scheduler+worker 全队列**（additive 故零报错窗口，先迁后重启更稳）。web build（HEAD `6ab90df`，entry `index-C7mTywFH.js`）→ rsync `--delete` dist → nginx reload，备份 `/opt/isales/backups/web-interruption-min-chars-20260610-174448.tgz`（旧 entry `index-IIPyIaUt.js`）。**smoke**：`alembic current`=f7a8b9c0d1e2；列 `integer NOT NULL default 2`；campaign 1(有 rules，advanced)+2(rules NULL，走默认树) 均回填 `interruption_min_chars=2`（与历史硬编码 2 逐字节等价）；openapi 含 `interruption_min_chars`；`/health`→200、`/campaigns`→401、公网 SPA 200；engine `credentials_loaded count=5`+`isales_engine_started` clean、api `Application startup complete`，0 error/traceback。**未做 live authenticated PATCH**（会改真实 campaign 配置；写路径已由 api `test_interruption_min_chars_create_default_and_patch` round-trip + openapi 暴露 + DB 列回读覆盖）。commit common `9a6f5be` / engine `71ce573` / api `007a5ed` / web `6ab90df` / meta `51726ea`(propose+apply)+本条 STATE。测试：common 182 / engine 397（1 pre-existing gate `test_gate_fails_open_to_main_on_referee_timeout` 失败无关，stash 验证 clean tree 同红）/ api 107（2 pre-existing redis-steal 环境失败无关）/ web 85 + build。**5 维对抗式 review（workflow）verdict=ship、0 blocker**，折入 1 medium（web 切非高级清树加确认）+1 low（api round-trip 测试）+2 nit（engine 注释 / spec 800→400）。**openspec `interruption-min-chars-and-mode-toggle` 待 archive**（本 session 随后做）。**回滚**：alembic downgrade `f7a8b9c0d1e2 → e6f7a8b9c0d1`（drop 列，null-rule campaign 字数门控回退到历史硬编码 2、无害）+ scp 旧源码（恢复 engine 硬编码 2 + 旧 campaign.py/schemas）+ 全队列重启 + web rsync 回 `web-interruption-min-chars-20260610-174448.tgz` + nginx reload。

Prior: 2026-06-10 15:10 CST — **fix-transcript-schema-drift deployed**（common + engine + api，无 web）。修外呼记录页（`/calls`）整页打不开 = `GET /calls` 500：引擎往 transcript 的 `ai_reply` 事件写了未登记的 `interrupted` 字段，撞 `isales-api` `CallRecordRead` 的 `extra="forbid"` → 含 `ai_reply` 的记录逐条 ValidationError。方向 B（去根因+清存量）：引擎 4 处 `append_event("ai_reply",…)` 删 `interrupted`（worker/api/web 全链路无人读，打断信息已由独立 `interruption` 事件+pipeline_trace 承载）；删 `state_changed` 死分支（`**meta` spread 与 forbid-union 天然冲突、生产零调用方）+ 其 enum 项 + `transition_to` 的 `meta` 参数。common 的 `TranscriptEvent` union 补 `StateWarningEvent`+`StateErrorEvent`（call-state-machine spec 已要求写 transcript、union 一直缺；字段 attempted/from_state/to_state）。**部署前全量审计 transcript JSONB** 抓到第二处历史漂移：`interruption` 事件带旧版引擎写的 VAD 字段 `rms`/`source`/`voice_active_ms`（当前引擎只写 interrupted_event_id+user_text_at_interruption，纯历史、无人读）→ **data migration 一并清洗**。**alembic `d5e6f7a8b9c0 → e6f7a8b9c0d1`**（纯数据 UPDATE：strip ai_reply.interrupted + interruption.{rms,source,voice_active_ms}，幂等，仅改命中行，WITH ORDINALITY 保序；downgrade no-op）。common 0.8.6→0.8.7（pyproject 后被并行 change 改到 0.8.8）。**部署**：scp common(transcript.py+migration)+engine(call_session/run_loop/state_machine) editable 源码 → chown isales:isales → 只读评估（170 记录中 38 含 ai_reply.interrupted / 13 state_warning / 3 state_error / **0 state_changed**）→ `alembic upgrade e6f7a8b9c0d1`（**显式 revision，非 head**——避开并行在途 `interruption-min-chars-and-mode-toggle` 的未就绪 migration `f7a8b9c0d1e2`，该 change 文件刻意不 scp）→ 重启 engine+api+scheduler+worker 全队列。api 运行时代码无改动（仅 pin+测试），靠共享 editable common + 重启拾起新 union。**无 web 改动**（web 用自有 TS 类型读 transcript、容错）。**smoke**：`alembic current`=e6f7a8b9c0d1；清洗后违规行 ai_reply.interrupted=0 + interruption.vad-fields=0；4 服务 active（engine `isales_engine_started`+`credentials_loaded count=5`、api `Application startup complete`，0 error）；`/calls`→401、`/health`→200、重启后日志 0 条 extra_forbidden/ValidationError；**机器级全量校验：`CallRecordRead.model_validate` 跑全部 170 条记录 → 170 PASS / 0 FAIL**（取代浏览器点验）。commit common `931b22b`(union+migration+0.8.7)+`a9a1c8f`(migration 扩展 interruption 清洗) / engine `e8dbd3d` / api `bd4bc48` / meta `e816669`(propose+apply)+本条 STATE。测试：common 182 / engine 396（1 pre-existing gate `test_gate_fails_open_to_main_on_referee_timeout` 失败无关，stash 验证 clean tree 同红）/ api calls 9（含 2 新回归：GET /calls 读含 state_warning 的 transcript=200 + ai_reply 含 interrupted 被 reject）。worker 经审计把 transcript 当 opaque list 喂 summarize、不经 schema 校验，不受影响。**openspec `fix-transcript-schema-drift` 待 archive**。**⚠️ 并行在途**：`interruption-min-chars-and-mode-toggle`（common 0.8.8 + migration `f7a8b9c0d1e2` 链在本 head `e6f7a8b9c0d1` 之后 + campaign.interruption_min_chars 列）由另一 session 在做，**未部署**，ECS 现 head=`e6f7a8b9c0d1`（我的）。**回滚**：alembic downgrade `e6f7a8b9c0d1 → d5e6f7a8b9c0`（no-op，剥掉的冗余字段不可复原但无害）+ scp 旧源码（恢复 engine 4 处 interrupted 写入 + state_changed 分支 + 旧 transcript.py）+ 全队列重启。

Prior: 2026-06-10 10:33 CST — **silence-drop-no-progress-timeout deployed**（common + engine + api + web 全栈）。删 `campaign.max_no_progress_seconds`「无进展超时(s)」独立秒级计时器：它与「沉默超限挂断」（`max_silence_activations` + `silence_threshold_ms` + `silence_hangup_phrase` → `silence_max_reached`）重复且误导（命名错 / hint 写「可挂断」/ 生产恒 NULL），统一收口到沉默超限一条路径——达到最大激活次数后客户再次静音达阈值 → 播挂断兜底语 → **直接挂断**。删 common 模型列 + `CampaignBase`/`CampaignUpdate` schema、engine `realtime/no_progress_timer.py` + run_loop 计时器分支/起算/复位 + `runtime_config` 字段 + `settings.engine_max_no_progress_seconds`、api `CampaignNestedUpdate` 字段、web `SilenceTab` 的「无进展超时」form-item（挂断兜底语 hint 明确「直接挂断；留空不播话术」）。**保留** `HangupCause.NO_PROGRESS_TIMEOUT` 枚举（仍是 engine `run_session` / `dial_consumer` 内部异常兜底 cause + worker 分类 + 历史行）。**alembic `c4d5e6f7a8b9 → d5e6f7a8b9c0`**（DROP COLUMN campaign.max_no_progress_seconds；nullable、生产恒 NULL，非破坏）。common 0.8.5→0.8.6。**部署**：scp common(campaign model+schema+migration)+engine(run_loop/runtime_config/settings，rm no_progress_timer.py)+api(schemas) editable 源码 → chown isales:isales → **先重启 engine+api+scheduler+worker 全队列（新模型无该列 → 零报错窗口）→ 再 `alembic upgrade head`（仅跑 d5e6f7a8b9c0）**。web build（HEAD `85a6c1f`）→ rsync `--delete` dist → nginx reload，备份 `/opt/isales/backups/web-silence-drop-20260610-103320`，entry `index-DgcL657t.js`。**smoke**：`alembic current`=d5e6f7a8b9c0；campaign.max_no_progress_seconds 列已 drop；openapi 无该字段（grep=0）；`/health`→200；4 服务 active + engine `cloud_edge_grpc_server_started`+`credentials_loaded count=5`+`isales_engine_started` clean、api `Application startup complete`；公网 SPA 200。commit common `5f8ef48` / engine `0fdfc39` / api `91f5794` / web `85a6c1f` / meta `b840212`(+本条 STATE)。测试：common 182 / engine 396（1 pre-existing gate `test_gate_fails_open_to_main_on_referee_timeout` 失败无关，stash 验证 clean tree 同红）/ api campaign CRUD+configs 绿（2 pre-existing redis-steal 无关，stash 验证）/ web typecheck+eslint+vitest 75+build。**openspec `silence-drop-no-progress-timeout` 待 archive**。**Trade-off**（用户确认）：删独立计时器后「客户持续发无效噪声、从不真正沉默」的极端僵局不再有秒级兜底自动挂断；该字段生产恒 NULL，现网行为不变。**回滚**：alembic downgrade `d5e6f7a8b9c0 → c4d5e6f7a8b9`（重建 nullable 空列）+ scp 旧源码（恢复 no_progress_timer.py + 各文件）+ 全队列重启 + web rsync 回 `web-silence-drop-20260610-103320` + nginx reload。

Prior: 2026-06-10 10:05 CST — **admin-prune-vestigial-features deployed**（common + engine + api + web 全栈）。删三个 vestigial 功能（预约 / 音色目录 / 转人工任务）端到端 + 修节假日页。删 `Appointment`/`VoiceModel`/`HandoffTask` 模型+schema+api router+web view/组件/路由/导航、枚举 `AppointmentStatus`/`AppointmentAction`/`HandoffStatus` + `LeadStatus.APPOINTED`/`VISITED`（保留 `LOST`）、死字段 `TransferMarkedEvent.handoff_task_id`、预约的 `CreateAppointmentDialog` 外呼记录入口 + lead 状态联动。**保留**：引擎转人工检测（标 `marked_for_handoff`+挂断）、worker `lead=transferred`、自由文本 `campaign.voice_id`（engine TTS 读）、`goal_type="appointment"` 标签、`agent` 表、`TransferTriggerType` 枚举。节假日页修 `Page`-vs-数组绑定 bug（列表永远空白）+ 加新增/删除对话框 + region 列（新 `src/api/holidays.ts`）。**alembic `b2f3a4c5d6e7 → c4d5e6f7a8b9`**（DROP appointment/voice_model/handoff_task 三表 + 索引；三表均 write-never，部署前 row count 全 0；downgrade 结构性重建，不复原已斩断的 campaign→voice_model FK）。**部署**：pg_dump 兜底（`/opt/isales/backups/admin-prune-vestigial-20260610-100029.sql`，三表 schema-only 321 行）→ scp common(enums / models `__init__` / tts / transcript / pyproject + migration，rm 6 删除文件)+engine(run_loop / manager)+api(main，rm 3 router) editable 源码 → 清 `__pycache__` + chown isales:isales → import sanity（37 routes 无 vestigial）→ `alembic upgrade head`（drop 3 表）→ 重启 engine+api+scheduler+worker 全队列。web build（HEAD `b720473`）→ rsync `--delete` dist → nginx reload，备份 `/opt/isales/backups/web-admin-prune-20260610-100337.tgz`，entry `index-BK6DHKBr.js`。**smoke**：`alembic current`=c4d5e6f7a8b9；三表已 drop；`/voice-models`+`/appointments`+`/handoff-tasks`→404（路由删）、`/holidays`+`/calls`→401（路由在+鉴权）、`/health`→200、openapi 无 vestigial path、公网 SPA 200；4 服务 restart clean（engine `isales_engine_started`+`credentials_loaded count=5`、api `Application startup complete`、scheduler/worker started、0 error）；engine run_loop `marked_for_handoff` 仍在（转人工检测保留）。commit common `3bd1815` / engine `1c7ef2e` / api `b2db404` / web `b720473` / meta `4972c17`(+本条 STATE)。测试：common 182 / engine 转人工链路绿（1 pre-existing gate-rename `test_gate_fails_open_to_main_on_referee_timeout` 失败无关，clean tree 也红）/ api 105（2 pre-existing redis-steal 环境失败无关）/ web vue-tsc + vitest 75 + build。**openspec `admin-prune-vestigial-features` 待 archive**。**回滚**：alembic downgrade `c4d5e6f7a8b9 → b2f3a4c5d6e7`（结构性重建三空表）+ scp 旧源码（恢复 6 删除文件 + 3 router）+ 全队列重启 + web rsync 回 `web-admin-prune-20260610-100337.tgz` + nginx reload；或 restore `admin-prune-vestigial-20260610-100029.sql`。**并行在途（已收口）**：`silence-drop-no-progress-timeout`（common 0.8.6 + migration `d5e6f7a8b9c0`，链在本 head `c4d5e6f7a8b9` 之后）已于 10:33 单独部署，ECS 现 head `d5e6f7a8b9c0`（见上方 Last updated 条目）。

Prior: 2026-06-09 16:30 CST — **filler-campaign-column deployed**（common + engine + api + web 全栈）。承接 filler-single-pool，进一步消除 `filler_phrase` 表层：垫词改成 `campaign.filler_phrases`（JSONB `list[str]`，与 `silence_phrases` / `interruption_whitelist` 同范式），删 `filler_phrase` 表 + `FillerPhrase` 模型/schema + `/filler-phrases` 端点 + 休眠的 `audio_url`/`generation_status` 字段；engine `FillerManager` 收 `list[str]` 按文本随机不重复；web `FillerEditor` 改单行分号输入（参照打断白名单），随 campaign PATCH 保存。**alembic `f1a2b3c4d5e6 → b2f3a4c5d6e7`**（campaign 加 filler_phrases → `jsonb_agg(filler_phrase.phrase)` 回填 → drop filler_phrase 表；3 句 dev 数据迁入 `campaign 1 = ["嗯","啊","嗯嗯"]`）。**部署**：pg_dump 兜底（`/opt/isales/backups/filler-campaign-column-20260609-162838.sql`）→ scp common(3+migration，删 filler.py model+schema)+engine(3)+api(3，删 filler_phrases.py) → chown → `alembic upgrade head` → 重启 engine+api+scheduler+worker。web build（HEAD `9853730`，顺带 ship 用户并行 persona 卡工作）→ rsync `--delete` → nginx reload，备份 `/opt/isales/backups/web-filler-campaign-column-*.tgz`，entry `index-DmAara83.js`。**smoke**：`alembic current`=b2f3a4c5d6e7；filler_phrase 表已 drop；campaign.filler_phrases 迁移正确；`/filler-phrases`→404、`/campaigns`→401、`/health`→200、公网 SPA 200。commit common `fa57f6d` / engine `9a3c208` / api `9c23a80` / web `eeae194`。测试：common 185 / engine 398（1 pre-existing gate 失败无关）/ api filler+campaign 全绿（2 pre-existing redis-steal 环境失败无关）/ web 17 文件 74 tests + build。**openspec `filler-campaign-column` archived**。**回滚**：alembic downgrade `b2f3a4c5d6e7 → f1a2b3c4d5e6`（从数组重建 filler_phrase 表，audio_url/generation_status 不可复原；或 restore `filler-campaign-column-20260609-162838.sql`）+ scp 旧源码 + 全队列重启 + web rsync 回备份 + nginx reload。

Prior: 2026-06-09 16:11 CST — **线索列表默认排序 newest-first deployed**（api only，纯排序）。线索管理列表 `list_leads` 的 `order_by(Lead.id)` → `order_by(Lead.id.desc())`：新线索在上、旧线索在下（`id` 自增主键与创建时间单调一致，故 id desc 即 newest-first，无需引入 `created_at`）。前端不做任何排序、原样展示后端顺序（`LeadList.vue` 的 `filtered` 只过滤搜索）。**无 schema / alembic / 后端契约改动**（端点仍只收 campaign_id/status/page/page_size，无 sort 参数）。**部署**：scp 单文件 `leads.py` → `/opt/isales/current/isales-api/isales_api/routers/` + chown isales:isales + `systemctl restart isales-api`（`Application startup complete`）。**smoke**：deployed `grep order_by`=`Lead.id.desc()` 确认；`/leads`→401（路由在 + 鉴权门）、`/health`→200、服务 active。commit api `5ae88d9`。测试：`test_leads_voice_holidays.py` 12 passed（列表测试只断言 total，不依赖顺序）。**非 openspec 行为变更**（纯默认排序）。**未携带**：isales-api `pyproject.toml` 工作树里有一处与本次无关的 `isales-common>=0.8.3→0.8.4` pin（pre-existing WIP，cosmetic on ECS 共享 venv），本次刻意未提交未部署。**回滚**：scp 回旧 `leads.py`（`order_by(Lead.id)`）+ restart，或 `git revert 5ae88d9`。

Prior: 2026-06-09 15:47 CST — **场景详情面板表头统一 deployed**（web only，纯表现层）。
所有配置面板表头统一为：对齐标题 + 灰色 info 图标 + 灰字注解。①`.tab-intro`/`.tab-intro__icon` 提为全局 utility（新 `src/styles/utilities.css`，main.ts 引入），info 图标改**灰色**（muted-foreground）；门控路由/工具触发/回调 删本地 scoped 副本。②tier/filler 描述（主对话/门控监管/extractor/垫词）前补灰 info 图标。③标题对齐：`.tier__head`/`.filler__head` gap 对齐 `.card__head`（space-2），16px 图标面板与 form 卡对齐；主对话(main) 保留 36×36 彩框（按用户定，略缩进）。④给 6 个无注解的行为面板各补一句注解（沉默激活/打断保护/转人工/收尾/重试·跟进/勿打；顶部三卡不补）。⑤用户断句判定：注解=端点说明，字段 hint 缩为灰字「留空使用默认 400ms。」（数字默认值随 placeholder 置灰的通则）。**无 api/后端/DB 改动**。**部署**：web build → rsync `--delete` dist → nginx reload，公网+本地 SPA 200，entry `index-BHmvtfBZ.js`→`index-aeBgtZFY.js`。备份 `/opt/isales/backups/web-panel-headers-20260609-154711`。commit web `b6b942c`（基于并行 `7280b03` filler 重构 + `27be846` 门控监管改名之上；filler info 图标+对齐被并行 commit 冲掉后已重补）。测试：typecheck+eslint+vitest 65+build 全绿。**非 openspec 行为变更**。**回滚**：rsync 回 `web-panel-headers-20260609-154711` + nginx reload。

Prior: 2026-06-09 15:39 CST — **filler-single-pool deployed**（common + engine + api + web 全栈）。垫词去掉 `filler_set` 分组层：`filler_phrase` 直挂 `campaign`（`filler_phrase.campaign_id`），一个 campaign = 一个扁平垫词池，engine 单池 random-no-repeat（删跨组轮询）；api `/filler-sets` → `/filler-phrases`（按 campaign_id）；web `FillerEditor` 改单一扁平列表 + 删死代码 `FillerSetDialog.vue` / `FillerTab.vue`。**alembic `c9d0e1f2a3b4 → f1a2b3c4d5e6`**（filler_phrase 加 campaign_id 回填 FROM filler_set → drop filler_set 表；3 句 dev 数据全保留 + campaign_id 回填）。**部署**：pg_dump 兜底（`/opt/isales/backups/filler-single-pool-20260609-153716.sql`）→ scp common(3)+engine(4)+api(4，删 filler_sets.py) editable 源码 → chown isales:isales → `alembic upgrade head` → 重启 engine+api+scheduler+worker 全队列。web build（stash 掉未提交 WIP，只出 committed HEAD）→ rsync `--delete` dist → nginx reload，备份 `/opt/isales/backups/web-filler-single-pool-20260609-153913.tgz`，entry `index-BHmvtfBZ.js`。**smoke**：`alembic current`=f1a2b3c4d5e6；filler_set 表已 drop；filler_phrase.campaign_id 存在 + 3 行全有值；`/filler-phrases`→401（路由在）、`/filler-sets`→404、`/health`→200、公网 SPA 200。commit common `17adb31` / engine `e91834b` / api `47b193e` / web `7280b03`（web HEAD 顺带 ship 已提交未部署的 `27be846` 门控监管改名）。测试：common 185 / engine 399（1 pre-existing gate 失败无关）/ api filler+campaign 全绿（2 pre-existing redis-steal 环境失败无关）/ web 16 文件 65 tests + build。**openspec `filler-single-pool` archived**。**回滚**：alembic downgrade `f1a2b3c4d5e6 → c9d0e1f2a3b4`（重建默认 set + 回填 filler_set_id，有损，原多组不可复原；或 restore `filler-single-pool-20260609-153716.sql`）+ scp 旧源码 + 全队列重启 + web rsync 回 `web-filler-single-pool-20260609-153913.tgz` + nginx reload。

Prior: 2026-06-09 14:44 CST — **基本信息 hint/试听 回落到字段下方 deployed**（web only，CSS-only）。
根因:早前为 hint 单行去掉表单 `max-width` 后内容区变宽,`el-form-item__content` 的 `flex-wrap` 把 `.cd__hint` /
`.cd__preview-row`（试听按钮）挤到了 360/520px 输入框**右侧**而非下方。修法:给 `.cd__hint` + `.cd__preview-row` 加
`flex-basis:100%` 强制独占整行 → 音色 ID 说明回到音色输入下方、试听按钮+开场白说明回到 textarea 下方。**无 api/后端/DB
改动**。**部署**:web build → rsync `--delete` dist → nginx reload,公网+本地 SPA 200,entry `index-BQX78MS4.js`→
`index-Dfk838-1.js`。备份 `/opt/isales/backups/web-hint-layout-20260609-144418`。commit web `80f425a`。测试:
typecheck+eslint+vitest+build 绿。**非 openspec 行为变更**。**回滚**:rsync 回 `web-hint-layout-20260609-144418` + nginx reload。

Prior: 2026-06-09 14:33 CST — **配置 Tab 说明 intro 降噪 deployed**（web only，纯表现层）。
门控路由/工具触发 顶部 intro el-alert 的 `title` 与外层 card_title 完全重复 → 删 title;并把整条说明从蓝色 info 框
降级为低调轻提示:新自定义 `.tab-intro`（无背景、12px 灰字、13px 蓝色 lucide `Info` 图标、`align-items:flex-start`）。
`RoutingRulesTab`/`ToolsTab` el-alert(intro)→`<p class="tab-intro">`（描述原文保留;ToolsTab 留 `.intro` 给「尚无旁路监管」
warning 空状态间距,warning 本身不动）;`CallbacksTab` 同类无 title info 说明顺带统一成 `.tab-intro`。三 tab 各加 `Info`
import。**无 api/后端/DB 改动**。**部署**:web build → rsync `--delete` dist → nginx reload,公网+本地 SPA 200,entry
`index-CkpK87dS.js`→`index-BQX78MS4.js`。备份 `/opt/isales/backups/web-tab-intros-20260609-143316`。commit web `d3a502d`。
测试:typecheck+eslint+vitest 17 文件/67 tests 绿+prod build。**非 openspec 行为变更**。**回滚**:rsync 回
`web-tab-intros-20260609-143316` + nginx reload。

Prior: 2026-06-09 13:54 CST — **场景详情 extractor 单条 + 统一裸齿轮图标 + 每卡彩色左色条 deployed**（web only）。
**把上条 AD3aWvdo「部署了但没提交」的 in-flight 编辑器精修正式实现并 commit（解决第 12 行 ⚠️ 工作树漂移）。**
①`PromptTierEditor` 加 `singleton` prop（extractor 启用）:隐藏 新增/「X条」/配置名称/删除,load 后无配置自动补一条空白可编辑行（首存即建）。②`PromptTierEditor` 加 `plainIcon` prop（裸 lucide 图标无彩色底框,对齐 form 卡 `<Settings>`）:旁路监管(referee)/话后信息提取(extractor) `Target`/`Sparkles`→`Settings`+plain-icon;`FillerEditor`(垫词) `Music` 彩框→裸 `Settings`(留黄左条);主对话(main) 保留彩色图标框（唯一 hero）。③彩色左色条扩散到全部 panel:`.card` 加 `border-left-width:4px`+6 个 `.card--<color>` modifier,13 张 form 卡各取不同色（相邻不撞）;tier/filler 卡本就有（main 蓝/referee 紫/extractor 绿/垫词 黄）。同时上条提到的 基本信息 voice_id 退回纯输入 + hint 单行 nowrap 也已随 `9d2e5a7` 落地。删 unused `Target`/`Sparkles`/`Music` import。**无 api/后端/DB 改动**。**部署**:web build → rsync `--delete` dist → nginx reload,公网+本地 SPA 200,entry `index-AD3aWvdo.js`→`index-CkpK87dS.js`。备份 `/opt/isales/backups/web-card-accents-20260609-135404`。commit web `15f7f0f`。测试:typecheck+eslint+vitest 17 文件/67 tests 绿+prod build。**非 openspec 行为变更**(纯 UI/表现层)。**回滚**:rsync 回 `web-card-accents-20260609-135404` + nginx reload。

Prior: 2026-06-09 13:50 CST — **场景配置编辑器 polish deployed**（web only，5 项纯前端微调）。
① 垫词开关+触发延迟从「基本信息」挪进「垫词」卡（`FillerEditor` 改 v-model 收 form，开关/延迟走保存条、垫词组仍即时存）;
② `asr_eos_silence_ms` 从「打断保护」抽出独立成「用户断句判定」面板（新 `EndpointingTab.vue`）+ 改名 ASR 端点静默→静默时长;
③ 新复用组件 `ExpandingTextarea.vue`（折叠 3 行→聚焦展开贴合内容·封顶 800px·失焦收回；直接管原生 `textarea.style.height`,
因 el-input `autosize=false` 收不回它算出的 inline 高）铺满全编辑器 8 处 textarea; ④ `silence_threshold_ms` web 默认 3000→4000;
⑤ 加 hint（短回复/仅倾听、转人工轮次触发、挂断兜底语触发条件）。**无 api/后端/DB 改动**。**部署**:web build → rsync
`--delete` dist → `/var/www/isales-web/` + nginx reload,公网+本地 SPA 200,title「iSales 智能外呼」,entry
`index-DXSa3uOn.js`→`index-AD3aWvdo.js`。备份 `/opt/isales/backups/web-config-polish-20260609-134928.tgz`。commit web
`9d2e5a7`。测试:typecheck + eslint + vitest 67 tests + prod build 全绿。**非 openspec 行为变更**(表现层/默认值/文案;
字段级面板内部 web-admin-ui spec 不 pin,无 drift)。**⚠️ 构建自工作树**:AD3aWvdo 还含若干**未提交**的 in-flight 编辑器精修
(卡片强调色 `card--green/yellow/red`、基本信息 voice_id 退回纯输入、referee/extractor tier 裸 `Settings` 图标 `plain-icon`、
extractor `singleton` 单条),故 checkout web `9d2e5a7` 重 build **不会复现** AD3aWvdo(差这些未提交项)。**⑥「打断字数限制」
仍未做**(跨 3 仓建列+alembic,留后；详见 [[project_session_2026_06_09_interruption_rule_tree]])。**回滚**:解
`web-config-polish-20260609-134928.tgz` 覆盖 `/var/www/isales-web/` + nginx reload。

Prior: 2026-06-09 13:24 CST — **多流路由→门控路由 改名 deployed**（web only，纯显示串）。
该卡是**两个对等半区**:开口前门控(gating: persona_fanout_cap/referee_timeout_ms/referee_fail_open_route/
max_continuous_restructure)+ 路由规则引擎(decider: 旁路监管类别→动作,动作 4 类 route/tool/transition/restructure)。
旧名「多流路由」只点了路由一半、「多流」偏黑话;「门控」是被藏掉的另一半。**故意不叫「门控工具路由」**:tool 只是 4 种
动作之一,且隔壁「工具触发」卡本就是本卡 tool 动作规则的简化子集视图(`ToolsTab` 直接 splice 进 routing_rules),加"工具"
会撞概念。改 live 串:`CampaignDetail.vue` 卡头+旁路监管描述引用、`RoutingRulesTab.vue` intro 标题;`campaignDetail.test.ts`
断言同步;两处 live 代码注释顺带改。**死代码** `RoleConfigTab` 仍引用「多流路由」(含一条报错串),不动。**无 api/后端/DB
改动**。**部署**:web build → rsync `--delete` dist → nginx reload,公网+本地 SPA 200,entry `index-B0Gx2K52.js`→
`index-DXSa3uOn.js`。备份 `/opt/isales/backups/web-routing-rename-20260609-132409`。commit web `dc99c73`。测试:
typecheck+eslint+vitest 16 tests 绿。**非 openspec 行为变更**(纯术语)。**回滚**:rsync 回 `web-routing-rename-20260609-132409`
+ nginx reload。

Prior: 2026-06-09 11:37 CST — **referee/extractor 角色改名 deployed**（web only，纯显示串）。
referee→**旁路监管**、extractor→**话后信息提取**,后端 `kind="referee"/"extractor"` 枚举契约**不动**。动因:multi-referee+
routing-restructure 迁移后 referee 只在旁路打类别标签,真正决策动作的是「多流路由」,旧名「决策」越范围且 live UI 本就割裂
(tier 卡叫决策、路由/工具卡叫裁判)。全 live 面统一成「旁路监管」(贴合引擎"旁路小模型"措辞):`CampaignDetail.vue` 两张
tier 卡标题+描述、`RoutingRulesTab.vue` 7 处(顺带修 `kind=裁判`→`kind=referee` 旧 bug)、`ToolsTab.vue` 6 处、
`PipelineTracePanel.vue` 标题;`routingRulesTab.test.ts` 1 断言同步。**死代码** `RoleConfigDialog/RoleConfigTab`（无 prod
import）仍「裁判/抽取」,故意不动。**无 api/后端/DB 改动**。**部署**:web build → rsync `--delete` dist →
`/var/www/isales-web/` + nginx reload,公网+本地 SPA 200,entry `index-BDkoJjWd.js`→`index-B0Gx2K52.js`。备份
`/opt/isales/backups/web-referee-rename-20260609-113725`。commit web `9f23c93`。测试:typecheck+eslint+vitest 5 套
23 tests 绿。**非 openspec 行为变更**(纯术语/表现层)。**已知遗留(未顺手改,超范围)**:①路由/工具空状态文案仍指已删的
「AI 配置」tab;②`PipelineTracePanel` 仍绑 multi-referee 迁移删掉的 `referee_*` 标量字段(deferred trace 重做)。
**回滚**:rsync 回 `web-referee-rename-20260609-113725` + nginx reload。

Prior: 2026-06-09 10:19 CST — **场景详情模块布局重排 deployed**（web only，纯 UI/IA）。
`CampaignDetail.vue` 按外呼运行链路重排 16 个配置小节:外呼进度→基本信息→可拨时段→主对话(main)→多流路由→
工具触发→决策(referee)→信息抽取(extractor)→垫词→打断保护→沉默激活→转人工→收尾→重试/跟进→勿打→回调。
拆掉 `.cd__tiers` 分组容器(其 flex-column+gap 与父 `.cd` 一致,三角色卡+垫词改为直接散在主流里,referee/extractor
紧跟工具触发,垫词随后)+删无用 `.cd__tiers` CSS;沉默/打断顺序调正(打断保护在沉默激活之前)。即时保存(AI 角色/垫词)
vs 保存条(form 小节)行为不变,小节独立故交错无功能影响。**无 api/后端/DB 改动**。**部署**:web build → rsync
`--delete` dist → `/var/www/isales-web/` + nginx reload,公网+本地 SPA 200,title「iSales 智能外呼」,entry
`index-2N9a3n2p.js`→`index-BDkoJjWd.js`,CampaignDetail chunk `CampaignDetail-DGerN_EW.js`。备份
`/opt/isales/backups/web-module-reorder-20260609-101918`。commit web `d70c586`。测试:web typecheck + eslint +
`campaignDetail.test.ts` 3 tests 绿。**非 openspec 行为变更**(纯表现层排序)。**回滚**:rsync 回
`web-module-reorder-20260609-101918` + nginx reload。

Prior: 2026-06-09 10:10 CST — **web-admin-interruption-rule-editor deployed**（web only）。补上
`engine-interruption-rule-tree` 里 deferred 的可组合打断规则编辑器:场景「打断保护」tab 新增「高级:可组合打断规则」区
—— 递归 `InterruptionRuleEditor.vue`（且/或/非 + 关键词/长度/时长/正则/分隔符/无,可任意嵌套,类型切换重建·不可变更新）;
`interruption_rules==NULL` 显示「使用默认规则」+「基于默认规则开始编辑」(用当前白名单+最小时长按引擎 default_rule 公式 seed),
已配可「恢复为默认」(清回 NULL)。保存随既有 campaign PATCH(`interruption_rules` 进 CAMPAIGN_DEFAULTS),422
`interruption_rule_invalid` 就地提示。**纯 web,无后端/DB 改动**(api 校验 + 字段 engine-interruption-rule-tree §7 已上)。
**部署**:web build + tar dist → `/var/www/isales-web/` + nginx reload,SPA 200,entry `index-2N9a3n2p.js`,
备份 `/opt/isales/backups/web-rule-editor-20260609-100936`。commit web `3fda155` / meta（propose `04a19cc` +
apply 本次）。测试:web typecheck + vitest 17 files/66 tests(+10 新)绿。**待办**:§6.2 浏览器人工点验(建树/嵌套/422)
→ 然后 `/opsx:archive web-admin-interruption-rule-editor`。**回滚**:rsync 回 `web-rule-editor-20260609-100936` + nginx reload。

Prior: 2026-06-09 09:32 CST — **engine-interruption-rule-tree deployed**（common + engine + api
全队列 + web）。barge-in 决策从写死的 whitelist→length→duration 序列升级为 **voxen 式可组合规则树**
（叶子 keyword[contains/exact]/length/duration/regex/split_by_delimiter/none + and/or/not，存 `campaign.
interruption_rules` JSONB；NULL → engine 从 legacy whitelist+min_duration 合成**等价默认树**，存量零行为变化）。
同时**吸收** `interruption-detection-text-length-gate`（prototype `min_text_length` 成为 `length` 叶子；
`_vad_monitor` 的 VAD-source cancel 删除、仅留 voice_active_ms corroboration mirror）并**移除 low_confidence
死分支** + 全队列拔 `primary_referee_label`（其唯一消费者就是该死分支）。**→ 解决 06-08 17:31 entry 的遗留
follow-up（打断主门控硬编码 prototype / 未可配）**。**alembic `b8c9d0e1f2a3 → c9d0e1f2a3b4`**（加
`campaign.interruption_rules` + drop `campaign.primary_referee_label`）。**部署**：scp editable 源码 common(7
文件)+engine(7 文件)+api(4 文件)→ `/opt/isales/current/{isales-common,isales-engine,isales-api}/` +
chown isales:isales；alembic upgrade head；**重启 engine+api+scheduler+worker 全队列**（drop_column 会让持旧
Campaign model 的服务查库报错，故全队列同步重启）。**验证**：四服务 active + 0 error；engine
`isales_engine_started`+`cloud_edge_grpc_server_started`；api `Application startup complete`；
`campaign.interruption_rules` 在 / `primary_referee_label` 已 drop；campaign 1/2 `interruption_rules=NULL`
（走默认树）；openapi 含 `interruption_rules`、无 `primary_referee_label`。commits：common `d9df098` /
engine `c6e5d1e` / api `9e1dfe7` / web `45e6a4c` / meta `ef3bff4`+。**web 也已上线**（build + rsync dist →
`/var/www/isales-web/` + nginx reload，SPA 200，entry `index-dyfJbVdT.js`；备份 `/opt/isales/backups/
web-interruption-rule-tree-20260609-093217`）——必须随后端一起上，否则旧 web 存场景/路由规则会把已删的
`primary_referee_label` 发进 PATCH/PUT body 触发新 api `extra=forbid` 422。本次 web 仅拔 primary_referee_label
UI，**未含**可组合规则编辑器（§10.1-2 phased follow-on）。**回滚**：alembic downgrade `c9d0e1f2a3b4 →
b8c9d0e1f2a3`（重建空 primary_referee_label 列 + 删 interruption_rules）+ scp 旧源码 + 全队列重启 + web 回
backup dir。**待办**：§9 真机 smoke（默认树等价 + 显式规则树）/ §10.1-2 web 可组合规则编辑器（phased）/ §11.3 archive。

Prior: 2026-06-08 17:31 CST — **场景保存 422 + 分号输入 修复 deployed**（web `8394429` +
**isales-api 重启**）。场景单页保存报 422 两个真因:① `id/created_at/updated_at: Extra inputs` —
`onRefresh` 的 `Object.assign(form, detail)` 把只读字段灌进 form、`buildPayload {...form}` 发出去被后端
`extra=forbid` 拒;修法 buildPayload **只发 CampaignBase 白名单**(`Object.keys(CAMPAIGN_DEFAULTS)`)。
② `routing_rules.0.action.tool.closing_phrase: Extra inputs` — **§11 部署时只重启 engine、漏重启 api**,
api 内存里还是旧 common(不认 `RouteToolAction.closing_phrase`);本次 `systemctl restart isales-api` 拾起磁盘
editable common（routing_rule.py 含 closing_phrase;pyproject 版本标签 cosmetic,共享 venv）。另修分号输入:
转人工关键词/打断白名单/沉默激活兜底语 textarea 改为**失焦(@change)才解析**（原每键 split+filter+rejoin 把刚
敲的分号吃掉）。部署:web build → rsync dist → nginx reload(index 200) + api restart(Application startup
complete)。备份 `/opt/isales/backups/web-422fix-20260608-173101/`。**遗留 follow-up（已答用户）**:打断主门控
现为 ASR 文字长度 ≥2（硬编码 prototype,未做成 `min_text_length` 可配/未暴露 UI）;silence section 的「无进展
超时(s)」=独立 `max_no_progress_seconds`（与沉默挂断不同），UI 待理清（用户确认中）。

Prior: 2026-06-08 16:03 CST — **web 场景配置「一页到底」deployed**（web only，change
`web-admin-scene-single-page-config` §1-6 + 部署）。兑现 one-role-ia 的 D6 deferred:把场景的 13-tab
高级编辑器 `CampaignEdit` 折进 `CampaignDetail`，全部 per-campaign 设置能力**纵向全展开、单页到底**（用户决定
不折叠）——进度 / 基本信息(含 TTS 试听) / 可拨时段 / 3 个 AI 角色卡(main·referee·extractor,自存) / 多流路由 /
工具触发 / 沉默激活 / 打断保护 / 转人工 / 收尾 / 重试·跟进 / 勿打 / 回调 / 统一保存条。**两套存储模式并存**:
AI 角色 3 卡 + 垫词按 campaign-id 自存;其余 9 小节走统一 `buildPayload`（**omit role_configs/filler_sets/
callback_configs** 防 children-replace 清空 + greeting 归一 + 422 标红）。**删** `CampaignEdit.vue` +
`operations-campaign-edit` 路由 + 「高级配置」跳转（旧 `/operations/campaigns/:id/edit` 走 not-found）。
**保留** 3 PromptTier 卡（弃 RoleConfigTab → persona/restructure 暂无配置入口,默认 N=1 用不到,后续补卡）。
**清过期文案**:4-tier·原运营区 注释、`main_judge`→`main_referee`（placeholder+fixture）。**纯前端,无
api/engine/schema 改动**。**部署**:`npm run build`（58 assets,删 CampaignEdit 后 chunk 减少）→
`rsync -az --delete dist/` → `/var/www/isales-web/`（清旧 el-tabs chunk）→ `nginx -t` ok + reload。
**验证**:`index HTTP 200` + `<title>iSales 智能外呼</title>`;web 全套 **56 tests passed** + vue-tsc + build +
lint clean。**备份** `/opt/isales/backups/scene-onepage-20260608-160331/pre-web.tgz`。**回滚**:解 backup
tgz 覆盖 + nginx reload（秒级）。commits:web `96e5a39` / meta tasks `84856a4`。**非 openspec 行为变更**（纯 UI/IA）。
**待用户真人点测**（§7.4:开场景→改多项→保存→确认角色未被清；TTS 试听）。

Prior: 2026-06-08 16:03 CST — **openspec 文档清账：active change 22 → 5（归档 17 个，非部署变化）**。
对全部 22 个 active change 逐个 ground-truth（git log / 本 STATE.md / spec 交叉验证，不信 tasks.md 勾选）后归档 17 个：
**5 个被取代**（`archive --skip-specs`，废弃设计不并入 specs/）：`asr-speaking-ear-close-timeout` / `macos-local-audio-dev` /
`referee-hangup-action`（→ tools-gating 吸收为 `tool:hangup`）/ `windows-artc-pybind11` ×2（→ dingrtc-migration §7）；
**12 个已完成/已部署**（spec 正常合并）：`cloud-edge-grpc-keepalive` `edge-recording-dev-no-modem`
`web-admin-one-role-ia-consolidation` `asr-vendor-packet-cadence` `campaign-fixed-greeting` `engine-spec-terminology-purge`
`filler-realtime-unblock-and-detail-toggle` `pipeline-latency-tail` `tts-cache-and-gated-filler` `arch-cloud-edge-split`
`engine-send-timeout-multi-edge` `engine-tools-multidialogue-gating`（各自部署细节见下方对应 Prior 条目）。**踩坑**：
`openspec archive` 失败时 abort 但**返回 exit 0**（silent failure）→ 批量归档必须用「目录是否从 changes/ 移到 archive/」
验证，不能信退出码；3 个 change 因 delta 标签错配 silent-abort，已修（web 四→五入口加 `## RENAMED`、tts-cache filler
门控从 ai-pipeline 移到 filler capability、arch 全局并发控制/监控暴露契约 `ADDED→MODIFIED`）。**specs 全量校验
22 passed / 0 failed，无 Requirement 丢失**。**剩 5 个 active 为真在途**（代码未完或卡硬件/真机验收）：
`engine-rtc-dingrtc-migration` / `edge-modem-audio-out-recovery` / `interruption-detection-text-length-gate` /
`joint-mvp-gate-13301035545` / `pipeline-stream-realmachine-acceptance`（详见下方 §"Active OpenSpec changes" 表）；
`web-admin-scene-single-page-config` 当日新建并已 §1-6 部署（见上条 16:03 web 场景配置）。**非部署变化**：纯 meta-repo
openspec 目录清理，**ECS / alembic / 服务 / 端口均未动**。commit meta `f5a060b`；gotcha 记入 memory
`feedback_openspec_archive_silent_failure`。

Prior: 2026-06-08 15:16 CST — **web「工具触发」客户向扁平编辑器 + §11.4 per-rule 结束语
deployed**（web only）。配合已上线的 engine §11:**§11.4**（commit web `314b62b`）— `RoutingRulesTab`
工具动作加 per-rule「结束语」输入框（`isHangupTool` 门控仅 hangup 显示，留空=直接挂断）+ `RouteToolAction.closing_phrase`
类型。**Option 2 客户向扁平表**（commit web `9ddb155`）— 把 dev 向 2 层「工具」tab 重构成客户向「工具触发」
扁平表:一行 `{关键词(裁判输出) → 挂断 → 结束语}`，底层**自动托管**共享 `hangup` 工具 + 写 tool:hangup `routing_rules`
（then_state=END + per-rule closing_phrase），顶部「判定裁判」选择器（≤1 裁判时自动选中隐藏）；**非挂断规则
（persona/transition）原样保留**、dev 仍在「多流路由」编辑;`CampaignEdit` tab「工具」→「工具触发」。**纯前端翻译，
api/engine/schema 不动**。**部署**:`npm run build`（61 assets）→ `rsync -az --delete dist/` → `/var/www/isales-web/`
→ `nginx -t` ok + `nginx -s reload`。**验证**:`index HTTP 200` + `<title>iSales 智能外呼</title>`;web 全套
53 tests passed、vue-tsc+build+lint clean。**备份** `/opt/isales/backups/web-tooltrigger-20260608-151628/pre-web.tgz`。
**回滚**:解 backup tgz 覆盖 `/var/www/isales-web/` + `nginx -s reload`。**非 openspec**(纯 UI 表现层，未改 spec 行为;
如需正式化可补 web-admin-ui spec)。auto-gen `components.d.ts` 的 stale `CampaignEditDialog`/`ElPopconfirm` churn 已 revert
（不入 commit，下次 web 团队有意 regen 时自纠）。

Prior: 2026-06-08 14:46 CST — **engine §11（per-keyword 挂断结束语 + 静音空话术直挂）
实装 + voxen-flat stack 并回 main + 部署**（common + engine）。**§11**：① `RouteToolAction` 加 per-rule
`closing_phrase`（覆盖 `HangupToolConfig.closing_phrase`，使一个 hangup 工具被 OFFENSIVE/HANGUP 等不同
关键字复用各带话术；皆空→直挂；common 5d72bc9，0.8.0→0.8.1 纯加性）；② engine decider 携带 +
run_loop `tool:hangup` 按 per-keyword 优先解析（命中规则→工具配置→直挂）；③ 静音超限挂断空话术直挂
（删 run_loop `outcome.text or "再见。"` + runtime_config `or "稍后联系，再见。"` 两处兜底）。**§11.4 web
DEFERRED**（web 大改版中，等其改完基于新版实装）。**并回 main**：`engine-flat-change-0-golden-net` FF
merge 进 engine main（`ed87183→b3f79b1`，13 commit，整套 voxen-flat stack：two-lane EventBus / SelectRouter
/ gate-first / 4 态 / tool routes 现在都在 main），381 测试全绿、ruff clean。**部署（rsync 整树覆盖 →
`/opt/isales/current/{isales-common,isales-engine}/` + chown isales:isales + `systemctl restart isales-engine`）
同时上线了 flat 分支在 deployed `67af3b6` 之后的另 2 个 workstream**：`cf59640`（engine-send-timeout-multi-edge：
多 Edge gRPC 路由 + 发送超时）+ `8b01f38`（referee 改裸 token 输出，no JSON/confidence，核心门控行为变更）——
rsync 按文件覆盖无法只挑 §11，用户确认整 HEAD 一起上。**无 alembic**（§11 是 JSONB 加性字段，那 2 个
workstream engine-only）。**验证**：deployed run_loop 旧"再见"兜底=0 / 新守卫=1，decider+routing_rule
closing_phrase 在，裸 token referee 在；重启 boot `cloud_edge_grpc_server_started` + `isales_engine_started`、
无 error/traceback。**备份** `/opt/isales/backups/engine-hangup-s11-20260608-144500/{pre-engine,pre-common}.tgz`。
**回滚**：解 backup tgz 覆盖 + restart（秒级），或 git revert。commits：common `5d72bc9` / engine `b3f79b1`(main)
/ meta tasks `249c843`。**真机 §11 referee-hangup 拨号验收仍待**（gate-first §9.4 SIM7600 那批一起）。

Prior: 2026-06-08 11:55 CST — **web-admin-one-role-ia-consolidation §1–4
deployed** (web only). 单角色 IA 收口：运营/客户二分解散，统一成单一 TopNav（场景/线索/
外呼/预约/数据看板 + 模型厂商圆钮 + 用户菜单「更多/设置」折叠区）。**§1**（纯加）场景卡删除入口 +
数据看板升客户顶层 `/dashboard` + voice_id 升音色选择器；**§2**（折叠）「更多/设置」收转人工/节假日/
设备/音色 + 场景详情就近「实时监控」+ 修回调断路由（`callback-config-edit` 原 router 无此 name）；
**§3**（破坏）删 5 view（运营版 CampaignList / OperationsIndex / SimCardList / CallbackLogList /
CallbackConfigList，净 ~600 行）+ 删 6 死路由 + 6 保留 view 重命名到干净路径 + 移除整套
OPERATIONS_REDIRECTS（旧 `/operations/*` 链接走 not-found，不留兜底 shim）；**§4** 删死组件
CampaignEditDialog + destale「4-tier」注释。**路由 23→17**，唯一 operations- 残留是 D6 deferred
`operations-campaign-edit`（CampaignEdit 高级编辑器，从场景详情「高级配置」进，引擎定型后另起 change
按客户理念折叠重做）。**部署**：`npm run build`（60 assets，删页后 chunk 减少）→ `rsync -az --delete
dist/` → `/var/www/isales-web/` → `nginx -s reload`，SPA 200。**无 api/后端改动**（迁移/折叠的 view
后端 analytics/ws/handoff_tasks/holidays/voice_models/edge_devices 契约不变；删的 sim/callback-logs/
独立 callback admin 本就无后端）。commits: web `7c60a00`(§1)/`988d3d0`(§2)/`f1d15d2`(§3)/`0301e80`(§4)
+ meta proposal `a15edf9`。**DEFERRED**（引擎重设计中）：campaign 配置内部 referee/routing/label 客户化
+ §4.3 PipelineTrace 多 referee 渲染 + §4.4 PromptTier 改名 + callback 后端 admin CRUD。验收 §5 见
change tasks。openspec validate --strict ok。

Prior: 2026-06-08 10:25 CST — **engine-tools-multidialogue-gating
webui scenario-config gap-fill deployed** (api + web). Weekend 改动的 web 任务 §5.x
全标 [x] 但 webui 没真跟完（tasks.md 跑在实物前）。跨 common/api/web 审计修三摊：① **api
§3.4 偏离**：handler `campaigns.py:356` 读 `payload.tools` 但 `CampaignNestedUpdate` 漏声明
4 个 weekend 字段 → **每个 PATCH /campaigns/{id} 都 AttributeError→500**（box 上 6月7 版正在崩）；
补 `tools`/`persona_fanout_cap`/`referee_timeout_ms`/`referee_fail_open_route`（4 红→10 绿）。
② **web §5.7 新增**：RoutingRulesTab 加 3 个孤儿 gating 标量控件（原只在 campaign.ts 有类型无控件）。
③ **web §5.4 升级**：persona 超额 hint→硬阻断。④ **web §5.8**：修 CampaignList 坏路由名
`campaign-edit`→`operations-campaign-edit` + CampaignDetail 客户面加「高级配置」入口。
**部署**：api scp 单文件 `schemas.py`→`/opt/isales/current/isales-api/isales_api/` + chown
isales:isales + `systemctl restart isales-api`（`Application startup complete`，openapi 含 3 字段）；
web `npm run build`→`rsync -az --delete dist/`→`/var/www/isales-web/`（71 assets）+ `nginx -s reload`
（SPA 200）。**无 alembic**（schema 纯 additive，无新列）。**无秒级回滚但 trivial**（scp 回旧 schemas.py +
git checkout web dist）。commits: api `81173da` / web `a9c0af7` / meta tasks `bda9d61`. 2 个既有
`test_campaign_start_pause` 红测与本次无关（gate-first HEAD `6147403` 遗留，待单独修）。

Prior: 2026-06-07 19:33 CST — **engine-tools-multidialogue-gating
(gate-first) deployed** (common + worker + api + scheduler + engine + web). 引擎从
「先说后判 / 11 态 FSM-as-controller」改为 **gate-first 先判后说 + CallStatus 11→4
(init/in_call/transferring/end) + eager 多 persona 投机 + lazy hangup/transfer tool +
StatusProjector(=StateMachine 同步唯一写者) + Phase-4 删 legacy/ENGINE_USE_ROUTER**。
**部署机制改用 rsync**（首次；`git archive` 干净导出 → `rsync -az --delete` over SSH，
排除工作树 WIP + build/`*.so`/vendor/logs；MSYS2 rsync+openssh，见
[[reference-ecs-github-egress]] memory）。**scoping**：engine 上 `67af3b6`（gate-first，
**不含** multi-edge `cf59640`——`engine-send-timeout-multi-edge` 自己另验另上）；scheduler
上 `82906e3`（persona packing，**不含** wake_event `04b5660`）；common/worker/api/web 上
各自 HEAD（common `9be81f6` / worker `633977c` / api `6147403` / web `46e5c79`）。
**alembic `a7b8c9d0e1f2 → b8c9d0e1f2a3`**（tools + personas + pre-reply gating 列：
pipeline_trace.selected_route_id/selected_route_kind/persona_candidates +
role_config tool/persona 行 + campaign tools/persona_fanout_cap/referee_timeout_ms 等）。
**数据安全**：部署前查 `call_record.status` distinct = 仅 `end`(152)/`init`(5)，均在 4 态枚举内，
无需迁移旧行。备份 `/opt/isales/backups/change3-20260607-192409/pre.sql.gz`。**验证**：6 服务
active；50051+8000 listen；ECS `CallStatus=['init','in_call','transferring','end']`；门控 3 列
已建；engine 启动 `cloud_edge_grpc_server_started`+`credentials_loaded count=5`+
`isales_engine_started` clean，无 live ENGINE_USE_ROUTER reader（run_loop:691 仅注释、
settings:120 死字段——随 multi-edge commit 删）；web SPA 200（4 态监控）。**⚠️ 无开关无秒级
回滚**（git revert `67af3b6`→上一态 + 重 rsync + alembic downgrade）。**§9 真机 SIM7600 验收
（2026-06-07 深夜重跑）：✅ gate-first 双向对话通（call #166，ASR 转写+AI 逐轮回复）、延迟健康
~1.0-1.5s（ASR-EOS 400ms + LLM 首 token + TTS 首字节 0.25-0.38s，无单一瓶颈）；🔴 **发现 bug2 远端
挂断不 finalize**——用户挂断后 edge 干净拆线但**无显式 gRPC 挂断给引擎**、引擎也不在 RTC 对端离开时
finalize → `call_record` 卡 `init`/`pipeline_trace` 空/session held open（对比引擎主动静音挂断
#165 finalize 正常 persisted=True）。修区=引擎 finalize-on-remote-hangup + edge 发显式 hangup
CallEvent，关联 change `device-status-reset-on-call-end`。**待办**：修 bug2 → 拿干净 pipeline_trace
测裁判放音延迟 + 验裁判 category；测裁判挂断/转人工需先配回 routing_rules（现 `[]`）。另：边缘 modem
偶进采集坏态（引擎收静音），USB 物理重插复位（详见 isales-telephony Windows STATE.md 2026-06-07 块）。

Prior: 2026-06-05 20:40 CST — **engine-multi-referee-and-restructure
deployed** (common + engine + api + scheduler + web). 单 referee dual-LLM 升级为
「N 裁判并行 + 有序路由规则 decider + 重组流（口语化重说上一句/补打断残留/低置信拖一轮）」。
部署（scp editable 源码）：common 13 文件（enums/models{campaign,role_config,
pipeline_trace}/schemas{call,campaign,role_config,pipeline,jsonb/routing_rule,
messages/dial}）+ engine 10 文件（run_loop/runtime_config/referee/streaming/types/
pipeline{decider(new),orchestrator,prompt_builder}/providers/llm_mock/
transcript_recorder/call_session）+ api 4 文件（routers{campaigns,role_configs}/
routing_validation(new)/schemas）+ scheduler 1 文件（prompt.py：pack_prompt_versions
referee_llm→referee_llms[]+restructure，proposal 误判"完全不动"）。**alembic
`f6a7b8c9d0e1 → a7b8c9d0e1f2`**（role_config.label 列 + partial unique index /
campaign.routing_rules JSONB+max_continuous_restructure+primary_referee_label /
pipeline_trace 单 referee_* 字段换 referee_results 数组+matched_rule+restructure_* /
data-migration 自动 seed）。**seed 验证**：campaign 1（含 referee id 5）→
label=main_judge + primary_referee_label=main_judge + 3 条等价默认规则
（goal_achieved/transfer/customer_decline）；campaign 2（无 referee）→ 未动（0 规则）。
4 python 服务 restart clean（engine `credentials_loaded count=5` + `isales_engine_started`；
api `Application startup complete` + openapi 含 `/campaigns/{id}/routing-rules` + 该端点 401）；
web rebuild→`/var/www/isales-web/`（71 assets，SPA 200，新「多流路由」tab）。备份：
`/opt/isales/backups/multi-referee-20260605-203424/pre.sql`（campaign+role_config+
pipeline_trace dump）。提交：common `46b6d49`(0.7.0) / engine `dd739c4`(main，工作分支
已 merge 回 main，4 文件冲突取分支版、丢弃被取代的 91f7005 旧降延迟补丁) / api `9a4ea3c` /
scheduler `7b6a77f` / web `eccabc0` / meta `20a1c41`。**踩坑**：新 migration 初版 id
撞了 2026-05-20 appointment 的 `a1b2c3d4e5f6` → alembic CycleDetected，部署前改名
`a7b8c9d0e1f2`（commit 46b6d49）。**真机 e2e（2 裁判+重组流验三场景）待跑**。

Prior: 2026-06-05 16:27 CST — **filler-realtime-unblock-and-detail-toggle
deployed** (engine + web). 真因：`filler_manager._pick_phrase` 选取门槛
`generation_status==READY and audio_url` 是 stage-6 OSS 预录路径字段，v1.0 无 OSS /
`generation_status==READY and audio_url` 是 stage-6 OSS 预录路径字段，v1.0 无 OSS /
无 `regenerate_filler_audio` worker → `audio_url` 恒 NULL、`generation_status` 恒
`pending` → 即使 `filler_enabled=true` 也每轮 `filler_skip_no_ready_phrase` 永不播。
修法：选取改 `p.text.strip()`（仅要求文本非空），垫词走运行时实时 TTS + 进程缓存
（`CachingTTSProvider` 已在，不依赖 OSS）；`audio_url`/`generation_status` 保留给
stage-6。web：`CampaignDetail.vue` 基本信息卡加 filler 开关 + 触发延迟（原先只在运营
编辑页 BasicTab）。部署：scp `filler_manager.py` 单文件覆盖（远端 == pre-change
baseline，diff 干净）+ `systemctl restart isales-engine`（`cloud_edge_grpc_server_started`
+ `credentials_loaded count=5` + `isales_engine_started` clean）；web `npm run build` +
scp dist + nginx reload（SPA 200）。提交：engine 4d4a632(branch
fix/inbound-stereo-downmix-20260601) / web 5ad886b(main) / meta fcd9e7d(main)。
**filler 真机 e2e（开 dev campaign filler_enabled + 真拨，确认日志出 `filler` event）
待跑。**

Prior: 2026-06-04 14:48 CST — **asr-speaking-ear-close-timeout +
tts-cache-and-gated-filler deployed** (pipeline-latency-tail 的两个 followup).
scp 源码 + `alembic d4e5f6a7b8c9 → e5f6a7b8c9d0`（additive `campaign.
filler_delay_ms INT NULL`）。engine 改动：(1) `asr_volcengine` websocket
`close_timeout=0.2`（旧库默认 10s）—— EOS-promote 后 ASR 重连不再阻塞 ~10s，
SPEAKING 期间 ASR 保持在听，修 barge-in 失聪（call 138 实证根因；**非**早先被
推翻的混音/AEC 理论）；(2) 新 `providers/tts_cache.py` `CachingTTSProvider` +
进程级 `TtsCacheStore`（main.py 包装 per-call TTS）—— 固定话术 greeting/filler
等命中零合成；(3) `run_loop._play_streaming` 时间门控垫词（首音频超
`campaign.filler_delay_ms` NULL→600 才播缓存垫词）。4 python 服务 restart：
engine `credentials_loaded count=5` + `isales_engine_started` clean；api openapi
含 `filler_delay_ms`；SPA 200。提交：common 88335ee(0.5.2) / engine c520d81
(branch fix/inbound-stereo-downmix-20260601) / api 4ea63e4 / web 8797db5。
**barge-in + 缓存/垫词体感真机验收待跑**。**同时清理：DingRTC 混音/self-loopback/
AEC barge-in 理论已从 engine 代码注释 + memory + docs 全删（call 138 实证证伪）。**

Prior: 2026-06-04 11:50 CST — **pipeline-latency-tail deployed**
(感知延迟尾巴 A/B/C/D). 部署: scp 源码(editable install)→ ECS — common
(`models/schemas/campaign.py` + 新 migration `d4e5f6a7b8c9`) / engine
(`run_loop.py` producer-consumer + TTS 预合成, `tts_volcengine.py` 持久
httpx client 连接复用, `asr_volcengine.py` partial_stable_s 0.7→0.4 可配,
`runtime_config.py`+`factory.py`+`main.py` 透传 campaign.asr_eos_silence_ms,
`transfer/manager.py` cheap/llm 拆分) / api (`schemas.py`
CampaignNestedUpdate + asr_eos_silence_ms) / web (rebuild→`/var/www/isales-web/`).
`alembic upgrade c3d4e5f6a7b8 → d4e5f6a7b8c9` (additive 一列 campaign.
asr_eos_silence_ms INT NULL, 无破坏). 4 python 服务 restart: engine
`credentials_loaded count=5 providers=['dashscope','volcengine']` +
`isales_engine_started` clean ✓; api `Application startup complete` +
`/campaigns` 401 + openapi 含 asr_eos_silence_ms ✓; SPA 200 ✓. **smoke-level
绿; mac dev 真拨号体感验收 (句间空档 / EOS→首音频 / barge-in 不回归) 待跑
(change tasks §9)**. 提交: common 063892c(0.5.1) / engine 0e8762e
(branch fix/inbound-stereo-downmix-20260601) / api 76b1709 / web c0ac69b.

Prior: 2026-06-04 10:10 CST — **pipeline-stream-and-referee
deployed** (双 LLM 架构). 砍掉三层 PK/judge/polish 管线，改 main 流式 + referee
旁路决策 + post-call extractor。部署: rsync 5 仓源码(editable install)→ ECS
`/opt/isales/current/<repo>/`，`alembic upgrade a908d5971908 → c3d4e5f6a7b8`
(破坏性: 删 role/judge/polish 行 + pipeline_trace 字段集换 main_*/referee_*/
first_audio_ms)，seed 脚本重建 campaign 1 的 main(doubao-pro-32k)/referee
(qwen-turbo)/extractor(qwen-turbo) 三 role_config + prompt_version，4 服务
restart + web rebuild→`/var/www/isales-web/`。engine 启动
`credentials_loaded count=5 providers=['dashscope','volcengine']` ✓; worker
extract_loop ✓; nginx SPA 200 ✓。**§13.4 全仓 pytest 抓到漏改: scheduler
`pack_prompt_versions` 仍引用 `RoleKind.ROLE`(已删)会 dispatch 崩 + common
`PromptVersionsSnapshot` schema 漏改 → 补 `main_llm/referee_llm/extractor_llm`
(commit common 1065c4f / scheduler abe6688), rsync 重部 common dial.py +
scheduler + restart engine/scheduler clean。** **mac dev 真通话验收 (§13.1,
call_record 137) 核心机制全绿: first_audio_ms 678-1106ms (<1.5s; 旧 6.5-9.5s,
5-8x); referee 决策驱动 state (SPEAKING→ACTIVATING customer_decline_recovery
log 实证); main 纯文本真销售话术; extract_status pending→done + extracted 写库
(worker extract_loop e2e); main_fallback_used=false。剩真人话术质量+barge-in
(§13.2) + Windows 真拨 (§15)**。备份:
`/opt/isales/backups/pipeline-stream-20260604-100314/{role_config,prompt_version,
pipeline_trace}.sql`(+ mac `deploy/cloud/backups/` 副本)。

Prior: 2026-05-24 09:32 CST — **impl-provider-credential-db-ssot
deployed**; provider 凭据从 env 切到 DB SSOT (provider_credential 表 Fernet
加密)；engine startup 装载 `credentials_loaded count=2 providers=['volcengine']`
✓；env 4 个文件加 `ISALES_FERNET_KEY` 同值 + engine.env 删 VOLCENGINE 真值；
alembic head a1b2c3d4e5f6 → b2c3d4e5f6a7 (后又 → a908d5971908 campaign greeting,
本次 → c3d4e5f6a7b8)。

Prior: 2026-05-23 18:50 — **web-admin-campaign-workflow deployed**;
campaign 进入客户面 4-entry top-nav，per-campaign 配置端点 (`/api/role-configs`
/ `/api/prompt-versions` / `/api/filler-sets` + `/api/campaigns/{id}/progress`)
mount 完成 + JWT 鉴权返回 401 ✓；scheduler 取数补 `next_call_at IS NULL`。
**无 alembic 迁移** (4 张配置表已存在)。SPA 重 build 至 75 files / 2.9 MB
含 `CampaignWorkspace` / `CampaignDetail` / `ModelProviderConfig` 新 chunk。
浏览器 UI 烟测仍欠 (从 curl 层确认 200 / 401 行为)。

Prior: 2026-05-20 web-admin-ui-redesign 落地。

This file is a **point-in-time snapshot** of what's actually deployed to the
iSales cloud, distinct from `deploy/RUNBOOK-cloud.md` which describes *how*
to deploy from scratch. Update this file whenever cloud topology changes.

> **Fresh Claude Code session resuming work — READ THIS FIRST**. The OpenSpec
> tasks.md checkboxes for A2 `arch-cloud-edge-split` lag the actual deploy
> state. This file is canonical; CLAUDE.md (root) makes it the arbiter when
> RUNBOOK / OpenSpec disagree. See § "Bootstrap a new dev session" at the
> bottom for the 4-command grep recipe to verify each layer before asserting
> any state.

## v1.0 deployment posture (project decision)

| Decision | v1.0 | Future (v1.x+) |
|---|---|---|
| Public endpoint | **IP-direct** `121.89.85.150` — edge connects straight to the ECS public IP | optional domain + ICP 备案 + Let's Encrypt (deferred until commercial scale or compliance pressure) |
| TLS posture | **TBD when first edge ships** — plain gRPC over IP is the cheapest option for a customer-VPN / pilot deploy; nip.io-style sslip plus Let's Encrypt is the lowest-friction TLS path that does not require a registered domain; self-signed pinned at edge is also viable. Pick when first edge actually deploys. | full PKI tied to domain |
| ICP 备案 | **not required** — no public domain in v1.0 | required if/when domain is registered |
| nginx | **active (2026-05-19, `web-admin-deploy`)** — nginx 1.20.1 listening `:80` serving `isales-web` SPA from `/var/www/isales-web/` + reverse-proxying `/api/` → `127.0.0.1:8000` + `/ws/` → `127.0.0.1:8000/ws/`. engine gRPC still binds `0.0.0.0:50051` directly (un-fronted); isales-api still binds `0.0.0.0:8000` directly (retained as Swagger fallback). | nginx terminates TLS + serves all SPA + reverse-proxies the four cloud services (full domain + 备案 path) |

`deploy/RUNBOOK-cloud.md` §2.2 ("域名与 TLS") describes the **future** path,
not the v1.0 default. §2.1 ("v1.0 IP 直连") is the current canonical recipe.

Decision rationale: v1.0 ship target is single-customer pilot installs where
the edge runs on the customer's own Windows PC and dials the ECS over the
public internet (or a customer-provided VPN). Domain registration + ICP 备案
alone takes 2-4 weeks in China and is not on the critical path for proving
the AI sales-call flow works. Re-add the domain step when (a) multiple
customer deployments need a stable endpoint label or (b) compliance / brand
requirements come in.

## ECS

| Field | Value |
|---|---|
| Public IP | `121.89.85.150` |
| Hostname | `iZ0jlev0nr9m65tj6546zyZ` |
| Region | Aliyun (region inferred from console; verify before any region-specific work) |
| OS | **Alibaba Cloud Linux 3.2104 U13 (OpenAnolis Edition)** — RHEL 8-compatible, `dnf`/`yum`-based |
| Arch | x86_64 |
| CPU / RAM | 8C 8G (provisioned; A2 spec called for 4C16G — fine for PoC) |
| Disk | 40 GiB system disk, ~33 GiB free pre-deploy → ~32 GiB free post-deploy (deploy added < 1 GiB) |
| Swap | none (default) |
| SSH | port 22, public key auth only (key bound via Aliyun console "SSH 密钥对") |
| Login user | `root` |

### SSH access from a dev machine

The `.pem` private key must be on your machine. The SSH command shape:

```
ssh -i <path-to>/isales-4.pem root@121.89.85.150
```

**2026-05-24 rotation note**: ECS bound keypair was rotated again on
2026-05-24 via Aliyun console "ECS → 实例 → 更多 > 密钥对". Old keys
(`isales.pem` install-time + `isales-3.pem` 2026-05-19 mac rotation) WILL
fail with `Permission denied (publickey)`. Only `isales-4.pem` works as
of 2026-05-24.

| dev rig | path | notes |
|---|---|---|
| Windows (primary) | `C:\Users\tianx\codes\isales-4.pem` | **2026-05-24 rotation** — current bound on ECS |
| Windows (legacy) | `C:\Users\tianx\codes\isales.pem` | 2026-05-17 install-time, **rotated out** |
| macOS (dev) | `~/codes/isales-4.pem` | **2026-05-25 mac refetch** — current bound (chmod 600); old `~/codes/isales-3.pem` purged from disk |

On a new machine: copy the **current** `.pem` from a secure location
(password manager attachment, USB drive, another dev machine's
`~/.ssh/`), `chmod 600` it on macOS/Linux, then test:

```
ssh -i C:/Users/tianx/codes/isales-4.pem root@121.89.85.150 'hostname'
# expect: iZ0jlev0nr9m65tj6546zyZ
```

Current bound keypair fingerprint (verify with `ssh-keygen -lf
isales-4.pem`):

```
# 2026-05-24 rotation: SHA256:5hmxKK6RcQQfukDedJ/s95A0KEUbKj/dzl2X3Uk264s (isales-4.pem, current)
# 历史 fingerprints (已失效)：
#   2026-05-17  SHA256:ESKEddFU95g0ytlCZyTYEg3T4SHYNe7oBVPHpWQI5k0 (isales.pem)
#   2026-05-19  SHA256:Xz3C4DtqUBvdENUZk5Biw+GYKw3gGmjt1UwEzL9yOHQ (isales-3.pem)
```

> **2026-05-24 rotation note.** Prior fingerprint
> `SHA256:Xz3C4DtqUBvdENUZk5Biw+GYKw3gGmjt1UwEzL9yOHQ` (and the earlier
> install-time `SHA256:ESKEdd...VPHpWQI5k0`) WILL fail with
> `Permission denied (publickey)` — `ssh-keygen -lf <path>` to verify
> before troubleshooting host bindings.

ECS host key fingerprints (for first-time `Are you sure you want to
continue connecting (yes/no/[fingerprint])?` accept):

```
ED25519 SHA256:3aQzOCsr17BHqpH9o/4cQI0oJ2g9e6MO8A+j2dFBVmo
ED25519 MD5:20:b5:69:4f:15:1e:c8:3c:c7:5e:1b:29:e3:e3:0e:0a
```

If `Permission denied (publickey)`: the key is either wrong (stale
rotation — see above), not bound to this ECS in the Aliyun console, or
has wrong file permissions on a Unix host. Aliyun console → ECS
instance → "更多 > 密钥对 > 绑定/解绑密钥对".

Claude Code permission rule (`.claude/settings.local.json` at repo root)
allows `Bash(ssh -i C:/Users/tianx/codes/isales-4.pem*)` +
`Bash(scp -i C:/Users/tianx/codes/isales-4.pem*)` (2026-05-24 rotation)
plus the legacy `isales.pem` patterns kept around for backward compat
(those keys are stale; rule survives as 防呆 backstop only).

## Installed components on the ECS

All on the same single instance — no managed RDS / Redis, no separate
nodes. Single-host posture acceptable for v1.0 PoC (no HA).

### Data plane (persistent, provisioned earlier)

| Service | Version | systemd unit | Listen | Auth |
|---|---|---|---|---|
| PostgreSQL | 13.23 | `postgresql.service` | `127.0.0.1:5432`, `[::1]:5432` | scram-sha-256, user `isales` |
| Redis | 6.2.20 | `redis.service` | `127.0.0.1:6379`, `[::1]:6379` | `requirepass` |
| sshd | (system) | `sshd.service` | `0.0.0.0:22` | pubkey-only |

PostgreSQL data dir: `/var/lib/pgsql/data/`. Redis config: `/etc/redis.conf`.

PG `isales` role + `isales` database exist; password matches the
`ISALES_DATABASE_URL` in `deploy/cloud/env/*.env`. pg_hba grants
`host isales isales 127.0.0.1/32 scram-sha-256` (only local TCP, no remote
PG access).

### Language runtime + git (added 2026-05-17 via dnf)

| Package | Version | Source |
|---|---|---|
| python3.11 | 3.11.13-7.0.1.al8 | `alinux3-updates` repo |
| python3.11-devel | 3.11.13-7.0.1.al8 | `alinux3-updates` repo |
| git | 2.43.7 | base |
| gcc / make | (already present) | base |

Python 3.6.8 is also on the box as `/usr/bin/python3` (RHEL 8 system Python).
**Cloud services require Python 3.11+** — every iSales repo's
`pyproject.toml::requires-python = ">=3.11"` and isales-engine uses 3.11-only
features (`asyncio.TaskGroup` / `except*` / `asyncio.timeout`) in 7 core
modules; pip would hard-refuse to install on 3.6. Do **NOT** try to run any
iSales service from the system Python.

### Application services (deployed 2026-05-17 22:30-23:25 CST, in-place upgraded 2026-05-27 PM)

Pulled from `https://github.com/tommax-bai/isales-{common,api,engine,
scheduler,worker}.git` at `main` HEAD into
`/opt/isales/releases/20260517-222944/` (current release).
`/opt/isales/current → /opt/isales/releases/20260517-222944/` symlink.
Single shared venv at `/opt/isales/current/venv/` runs Python 3.11.13;
all 5 isales packages installed editable (`pip install -e`).

**Branches checked out in the release dir (2026-05-28)**:

| Repo | Branch | HEAD |
|---|---|---|
| `isales-engine` | `dingrtc-migration-cloud` (not main) | `550902d` "barge-in: pragmatic rollback for DingRTC self-loopback + VAD corroboration" |
| `isales-common` | `main` | `2418981` "cred_migrate: add ISALES_VOLCENGINE_ASR_RESOURCE_ID env mapping" |
| `isales-api` / `scheduler` / `worker` | `main` (untouched) | (pre-2026-05-24 sync) |

> **Note (2026-05-28)**: 6 additional engine commits landed in this session
> via scp + `sudo install` (ECS → GitHub fetch was failing intermittently
> during the session, so all deploys went `git push origin → scp from mac →
> install -o isales -g isales` ; the git working tree shows the older HEAD
> `ff776a8` from `2026-05-27` because the local PUSH succeeded but the box's
> outbound pull didn't). When `dingrtc-migration-cloud` archive completes,
> rebuild the release dir per `install.sh` to re-sync git state with the
> deployed files.

The engine on `dingrtc-migration-cloud` branch carries 16 PM commits incl. **TTS V3
SSE protocol rewrite** (SeedTTS 2.0), **ASR V3 SAUC WebSocket binary protocol
rewrite**, **push_audio 10ms chunking + 8ms pacing** (DingRTC buffer
overflow fix), **48 kHz → 16 kHz audioop resample** for mixed-playback inbound,
**`sender_uid=""` filter accept** for mixed-playback frames. Complete chain +
ground truth: `memory/project_session_2026_05_27_b_handoff.md` and the 5 SDK
gotcha increment in `memory/reference_artc_sdk.md`. Editable installs picked up
all changes after `systemctl restart isales-engine` (4 restarts during the
session, last at 17:17 CST with cleanup commit `ff776a8`).

When `dingrtc-migration-cloud` archive completes, this release dir should be
rebuilt to land on `main` HEAD per the standard `install.sh` flow, **not**
just `git checkout main` (editable install bookkeeping + venv layout depend on
the release dir creation script). Until then this is an in-flight branch
deployment, acknowledged risk.

| Service | systemd unit | Listen | Notes |
|---|---|---|---|
| isales-engine | `isales-engine.service` enabled+active | `0.0.0.0:50051` (cloud-edge gRPC, plaintext per v1.0 IP-direct) | HS256 JWT bearer in initial metadata; secret in `engine.env::ISALES_JWT_SECRET`. Log line `cloud_edge_grpc_server_started` confirms boot. |
| isales-api | `isales-api.service` enabled+active | `0.0.0.0:8000` (FastAPI + Uvicorn + WebSocket) | Web admin / boss console backend; see `api.env`. Both public direct (Swagger fallback) AND fronted by nginx `/api/` reverse proxy. |
| isales-scheduler | `isales-scheduler.service` enabled+active | (no socket — pure background) | Lead dispatcher; idle until campaign + leads inserted. |
| isales-worker | `isales-worker.service` enabled+active | (no socket — pure background) | Post-call summary / webhook fan-out. |
| nginx | `nginx.service` enabled+active (2026-05-19, `web-admin-deploy`) | `0.0.0.0:80` (HTTP only, v1.0 IP-direct, no TLS) | Serves `isales-web` SPA from `/var/www/isales-web/` + reverse-proxies `/api/` → `127.0.0.1:8000/` + `/ws/` → `127.0.0.1:8000/ws/`. Config drop-in: `/etc/nginx/conf.d/isales.conf` (from `isales-web/deploy/nginx.conf`, `server_name` stripped). |
| isales-web (SPA) | static files under nginx | served at `http://121.89.85.150/` | Vue 3 + Element Plus admin / boss console. Built artifact path `/var/www/isales-web/{index.html,assets/}` (47 files, 2.5 MB). Re-deploy: `pnpm run build` on dev mac → `scp dist/ → ECS:/var/www/isales-web/` → `nginx -s reload`. |

Service env files at `/etc/isales/env/{api,engine,scheduler,worker}.env`
(root:isales 0640), mirrored from this repo's `deploy/cloud/env/*.env`. Each
systemd unit has a `*.service.d/env.conf` drop-in pointing at its env file.

Database schema: alembic head `c3d4e5f6a7b8` (advanced from `b2c3d4e5f6a7` →
`a908d5971908` campaign greeting → `c3d4e5f6a7b8` pipeline-stream-and-referee
on 2026-06-04). Prior `b2c3d4e5f6a7` (advanced from `a1b2c3d4e5f6`
on 2026-05-24 by `impl-provider-credential-db-ssot §1.6` — 新建
`provider_credential` 表，存 Fernet urlsafe-base64 cipher，UNIQUE
`(provider_id, field_name)` + idx `provider_id`)。21 tables in `public`
(19 initial + 2026-05-20 `appointment` + 2026-05-24 `provider_credential`)。
Verify with:

```bash
ssh ... 'cd /opt/isales/current/isales-common && set -a && source /etc/isales/env/api.env && set +a && \
    sudo -u isales -H -E env ISALES_DATABASE_URL="$ISALES_DATABASE_URL" \
    /opt/isales/current/venv/bin/alembic current'
```

**Not deployed in v1.0**: Prometheus / Grafana monitoring stack —
per the "v1.0 deployment posture" decision. Re-add when production
observability scope opens.

> **2026-05-19 (`web-admin-deploy`)**: nginx + isales-web were
> previously listed here as "not deployed in v1.0"; that decision is
> now reversed. Both are active under v1.0 IP-direct + HTTP-only
> posture (no TLS, no domain). v1.x adds TLS termination + 备案
> domain on the same nginx instance.

> **2026-05-20 (`web-admin-ui-redesign`)**: SPA redesigned — sticky
> top-nav (`[线索 ｜ 外呼 ｜ 预约]` + 3 config circles) replaces
> sidebar; 10 operational views demoted under `/operations/*` with
> client-side 301 from old top-level paths (preserves bookmarks).
> Backend gained `/api/appointments` (6 endpoints + state-machine).
> Deploy steps actually executed:
>
> 1. backup `/var/www/isales-web/` → `/var/www/isales-web.bak-20260520-112349/`
> 2. `git pull` on isales-common / isales-api / isales-engine /
>    isales-scheduler / isales-worker (engine stashed a stale
>    cloud-edge-grpc-keepalive hotfix under
>    `stash@{0}: On main: pre-deploy-202605-keepalive-hotfix` — main
>    branch already contains the equivalent code, drop the stash next
>    cleanup pass)
> 3. `pip install -e` rerun for all 5 packages; `pip check` clean
> 4. `alembic upgrade head` advanced `580b817550c8 → a1b2c3d4e5f6`;
>    `\d appointment` shows 10 cols / 4 indexes / 2 FKs as expected
> 5. `systemctl restart isales-api`; startup log shows
>    `Application startup complete` + `Uvicorn running on http://0.0.0.0:8000`
> 6. `rsync -avz --delete dist/ → /var/www/isales-web/` (had to
>    `dnf install -y rsync` first — not pre-installed on AL3); 71
>    asset files; `chown -R nginx:nginx` + `755/644` perms
> 7. Public smoke from dev mac:
>    - `GET http://121.89.85.150/` 200 (SPA index)
>    - `GET http://121.89.85.150/api/docs` 200
>    - `GET http://121.89.85.150/api/appointments` 401 (JWT enforced)
>    - `GET http://121.89.85.150/dashboard` 200 (SPA fallback; client
>      router redirects to `/operations/dashboard`)
>    - `GET http://121.89.85.150/operations` 200
>
> Known follow-up: full in-browser smoke (login → 6 entries → leads →
> call → create-appointment → appointments flow → 3 config views) still
> owed; cite when `web-admin-ui-redesign §6.7` ticks. Until then, the
> infrastructure and HTTP layers are confirmed but UX validation is
> from curl only.

> **2026-05-23 (`web-admin-campaign-workflow`)**: campaign 进入客户面 4-entry
> top-nav (`[场景 ｜ 线索 ｜ 外呼 ｜ 预约]` + 1 模型厂商 config 圆按钮)，
> per-campaign 外呼策略 (4-tier prompt / 垫词 / 时段 / 选用音色) 真持久化到
> 后端。Deploy 步骤实际执行：
>
> 1. backup `/var/www/isales-web/` → `/var/www/isales-web.bak-20260523-pre-campaign-workflow/`
> 2. **Workaround**: ECS → github.com:443 持续 TCP 超时（Aliyun CN egress
>    阻断），git pull 全部失败 → 改用本地 `git bundle create` + `scp` →
>    ECS `git fetch /tmp/<repo>.bundle main:bundle/main` + `merge --ff-only`。
>    Applied: common `99c47b2`, api `9416669`, scheduler `241481e`。
>    [架构建议] install.sh / 部署文档应加 fallback 路径（bundle 或 China
>    git mirror），以及一段 egress 连通性 diagnostic。
> 3. `pip install -e isales-common` 刷新版本（0.3.0 → 0.3.2）；consumer
>    pin 范围 `>=0.3.0,<0.4` 未变，editable 安装无需再装。
> 4. **No alembic migration** — `role_config` / `prompt_version` /
>    `filler_set` / `filler_phrase` 已存在于初始 schema，仅 HTTP 端点新增。
> 5. `systemctl restart isales-api isales-scheduler`; 两者 active；
>    `journalctl --since "30 seconds ago"` grep error/fail/traceback → 0 命中。
> 6. local `npm install` 补 `lucide-vue-next`（node_modules 漏装）→
>    `npm run build` clean (13.5s，含 CampaignWorkspace 4kB / CampaignDetail
>    19.5kB / ModelProviderConfig 6.2kB)；75 asset files / 2.9 MB；
>    `scp dist/*` + `chown -R nginx:nginx` + `nginx -s reload`。
> 7. HTTP smoke（curl from ECS 127.0.0.1）：
>    - `GET /` 200 (SPA index)
>    - `GET /campaigns` 200 (SPA fallback; client router → CampaignWorkspace)
>    - `GET /operations/campaigns` 200 (运营面 view 保留)
>    - `GET /api/role-configs` 401 (新 router 已 mount + JWT 强制)
>    - `GET /api/prompt-versions` 401 (同)
>    - `GET /api/filler-sets` 401 (同)
>    - `GET /api/campaigns` 401 / `GET /api/docs` 200
>
> Known follow-up: full in-browser smoke (建场景 → 配 prompt/时段/音色 →
> 保存刷新仍在 → 添加线索下拉 → 启动场景 → 验证 `next_call_at` 初始化 →
> 停止 → 旧 `/operations/*` 重定向仍工作) 仍欠；HTTP layer / 后端日志确认
> 后端 + 鉴权层 OK，UX 验证需浏览器。复用 `web-admin-ui-redesign` 同期
> deferred UX smoke。

> **2026-05-24 (`impl-provider-credential-db-ssot`)**: provider 凭据从
> env 切到 DB SSOT (`provider_credential` 表 + Fernet 加密 + admin CRUD)。
> Deploy 步骤实际执行：
>
> 1. 本地 `git bundle create` 5 仓 (common/api/engine/worker/scheduler)
>    → scp → ECS git fetch + merge --ff-only。HEAD: common 6edbd8c /
>    api b14d834 / engine 0f6023b / worker 134c371 / scheduler 78c4c54。
> 2. `pip install -e isales-common` (0.3.2 → 0.4.0) + 4 service 重装
>    pyproject metadata (>=0.4.0,<0.5 pin)；`pip check` clean。
> 3. backup `/etc/isales/env/engine.env` → `/tmp/engine.env.pre-cred-migrate`
>    (chmod 644 给 isales 用户读)。
> 4. **alembic upgrade head** advanced `a1b2c3d4e5f6 → b2c3d4e5f6a7`；
>    `\d provider_credential` 显示 5 cols (id/provider_id/field_name/
>    cipher_text/updated_by/timestamps) + UNIQUE(provider_id, field_name)
>    + idx ix_provider_credential_provider_id。
> 5. `isales-cred-migrate import-env --env-file /tmp/engine.env.pre-cred-migrate
>    --apply` 灌入 2 行 (volcengine.app_key + volcengine.app_token)，
>    masked plan 显 `api-********5338` / `8298********2c49` 与原值前后
>    4 字对齐 ✓。
> 6. scp 4 个新 env (含 ISALES_FERNET_KEY=Yt-e_Tg... 同值，engine.env
>    无 VOLCENGINE_APP_KEY/APP_TOKEN，加 ISALES_CREDENTIALS_REQUIRED=true)
>    → `install -m 0640 -o root -g isales` 覆盖 `/etc/isales/env/`。
> 7. `systemctl restart isales-api isales-engine isales-scheduler
>    isales-worker`；4 服务 active；`journalctl -u isales-engine` 显
>    `credentials_loaded count=2 providers=['volcengine']` ✓；60s 日志
>    grep error/fail/traceback 0 命中。
> 8. HTTP smoke：`/api/provider-credentials = 401` (新 router 鉴权 OK) /
>    `/api/campaigns = 401` / `/api/docs = 200`。
> 9. `cd isales-web && node scripts/check_api_reachability.mjs`：
>    全量 47 endpoints OK，0 DEAD。新 endpoint `POST /provider-credentials`,
>    `GET /provider-credentials/{id}`, `DELETE`, `reload-hint` 全 401 ✓。
> 10. Cleanup `/tmp/engine.env.pre-cred-migrate`。
>
> Known follow-up: full in-browser smoke (UI「模型厂商」改 key + 保存 +
> mask preview 验证) 仍欠；HTTP layer / engine startup 装载日志确认
> 后端链路 OK。

> **2026-06-05 — campaign-greeting-tts-preview deploy (scp, editable):**
> 1. scp `isales-common/isales_common/providers/{tts_volcengine.py(new),
>    _errors.py}` → VolcengineTTSProvider + HTTP error mapping 下沉 common
>    (engine + api 共用)；httpx 0.28.1 已在共享 venv，新依赖满足。
> 2. scp engine `{providers/_errors.py(shim), providers/factory.py,
>    runtime_config.py}`；`rm` 旧 engine `providers/tts_volcengine.py`；
>    runtime_config 现解析 `campaign.voice_id → VoiceModel.voice_id`
>    (此前硬编码 "default")。
> 3. scp api `{routers/campaigns.py, schemas.py, common/wav.py(new)}` —
>    新 `POST /campaigns/tts-preview`（开场白试听，无状态，返回 audio/wav）。
> 4. scp `isales-web/dist/*` → `/var/www/isales-web/`（BasicTab 试听按钮，
>    bundle `CampaignEdit-BaXYFyyZ.js`）。
> 5. `systemctl restart isales-api isales-engine`；两服务 active，engine
>    `credentials_loaded count=5` + `isales_engine_started` 无 import error。
> 6. E2E smoke（铸 admin JWT 真调）：`POST /campaigns/tts-preview`
>    {"您好，我是智联招聘的小雨", zh_female_xiaohe_uranus_bigtts} → **200 +
>    audio/wav + 76412 bytes + RIFF**（真 vendor 合成走共享 common provider）。
> commits: common 2a127c5 / engine c109c61+1eb78b6 / api 7cf71a1 /
> web 8b5b1ff / meta c5375c2.

> **2026-06-05 (后续) — § 4C 音色改直填 speaker 串 (redeploy + migration):**
> 用户决策放弃 ListSpeakers/AK-SK 路线，音色控件改文本框直填 vendor speaker；
> `campaign.voice_id` 由 `BigInteger` FK(voice_model) 改为 `String(128)` 直存
> speaker 串。
> 1. scp common `{models/campaign.py, schemas/campaign.py, alembic/versions/
>    f6a7b8c9d0e1_*}` + engine `runtime_config.py` + api `schemas.py` + web
>    `dist/*`(bundle `CampaignEdit-BWLpTz9D.js`)。
> 2. `alembic upgrade head`: **e5f6a7b8c9d0 → f6a7b8c9d0e1**(drop FK
>    fk_campaign_voice_id_voice_model + alter voice_id → VARCHAR(128) USING
>    NULL)。`information_schema` 确认 voice_id = character varying(128)。
> 3. `systemctl restart isales-api isales-engine`；active，无 import error，
>    engine `credentials_loaded count=5` + started。
> engine runtime_config 现 `voice_speaker = campaign.voice_id or "default"`
> (直用串，删 VoiceModel 查询)。commits: common f57e732 / engine 71e6011 /
> api 922db8e / web d058b93 / meta d54f377.
> Known follow-up: 浏览器内填音色 ID + 开场白 → 点「试听」播放；真拨号验证音色生效。

### Why PG 13 not PG 16

`alinux3-updates` repo only carries `postgresql-13.23-2.0.1.al8`.
Installing PG 16 would require adding the PostgreSQL Global Development
Group (PGDG) repo against RHEL 8, which works but introduces one more
maintained dependency. v1.0 schema is plain SQLAlchemy migrations
compatible across PG 13–16, so PG 13 was chosen as the simplest stable
path. To upgrade later: `pg_dumpall` → install PG 16 from PGDG → `psql
< dump.sql` → cutover.

### Why AL3 not Ubuntu 22.04

The ECS was already provisioned with AL3 by the user before the iSales
deployment work began. Reprovisioning to Ubuntu was deemed not worth
the cost (PG/Redis on AL3 are first-class supported). Implication:
`deploy/cloud/scripts/install.sh` (originally written for Ubuntu apt)
was **not** run end-to-end here; instead a manual port of its phases
ran from a Claude Code SSH session 2026-05-17. The script needs an
`apt → dnf` adaptation pass before it's runnable here. Package mappings:

| Ubuntu apt | AL3 dnf |
|---|---|
| `postgresql postgresql-contrib` | `postgresql-server postgresql-contrib` (already installed) |
| `redis-server` | `redis` (already installed) |
| `python3.12 python3.12-venv` | `python3.11 python3.11-devel` from `alinux3-updates` (Python 3.12 not in repo; build-from-source possible but not warranted) |
| `nginx` | `nginx` (in `epel`) — not used in v1.0 |

## End-to-end AI dialog smoke — mac --dev-no-modem (verified 2026-05-27 17:12 CST)

Full bidirectional wire (cloud DingRTC + mac mic ASR + LLM + TTS + interruption)
runs end-to-end. call_record id=23 evidence (PG `transcript` JSONB):

```
ts=2514   greeting          "您好，我是智联招聘的招聘顾问小雨呀～..."  (LLM dashscope JSON mode, 真个性化)
ts=10560  silence_activation 0
ts=14293  silence_activation 1
ts=15319  user_speech       "你好。"                                   (V3 SAUC ASR 识别)
ts=15911  default_reply     "测试测试" (turn 2 LLM JSON 待修, fallback)
ts=17360  ai_reply turn_id=1 "测试测试"                                (state machine 正确 advance)
ts=21557  interruption       "时间不方便听"                            (V3 SAUC ASR + interruption detector)
ts=21557  hangup silence_max_reached
```

Reproduce from a fresh mac dev mac:

```bash
cd ~/codes/isales-telephony
.venv/bin/python scripts/mac_dev_no_modem_smoke.py --timeout 60
```

The smoke does (commit `2919400` in isales-telephony):
1. ssh ECS check systemctl 4 services active + PG lead 2 + provider_credential
2. ssh ECS `isales-edge-token-mint --device-id edge-01 --ttl 1h` → JWT
3. spawn `isales-telephony-edge --dev-no-modem` subprocess; tail log for
   `edge_daemon_started_dev_no_modem` + `cloud_edge_stream_opened`
4. scp + run `_remote_inject_dial.py` on ECS to LPUSH `engine:dial` directly
   (bypasses scheduler + device-chain seed — `DialRequest` validated end-to-end)
5. ssh ECS poll `call_record WHERE lead_id=2` until terminal status (end)
6. interactive `y/n` listen check (user confirms speaker played AI's voice)

provider_credential SSOT 5 fields used by the engine:

| provider_id | field_name | usage |
|---|---|---|
| volcengine | api_key | `X-Api-Key` (新版控制台 UUID, 跨 ASR/TTS 通用) |
| volcengine | app_key | `X-Api-App-Id` / `X-Api-App-Key` (legacy fallback, ASR 用 App-Key 命名) |
| volcengine | app_token | `X-Api-Access-Key` (legacy fallback Access Token) |
| volcengine | tts_resource_id | `seed-tts-2.0` (V3 SSE TTS) |
| volcengine | asr_resource_id | `volc.bigasr.sauc.duration` (V3 SAUC ASR 1.0 小时版) |
| dashscope | api_key | `Authorization: Bearer <api_key>` for Qwen LLM (OpenAI compatible) |

Cross-link:
- `memory/project_session_2026_05_27_b_handoff.md` — 完整 22-commit chain + 5 SDK gotcha
- `memory/project_session_2026_05_28_handoff.md` — 6 commits + 2 PG UPDATE; JSON schema ROOT CAUSE + barge-in wall-clock + VAD bypass + SDK self-loopback 实证; **未解: judge prompt 概念错位 (留 `prompt-template-vars` openspec change) + greeting 不可打断 (留 `engine-greeting-aec`)**
- `memory/reference_artc_sdk.md` § "5 个 SDK 集成 gotcha" — DingRTC behavioural quirks
- `isales-engine/isales_engine/providers/{tts_volcengine,asr_volcengine}.py` — V3 protocol impl
- `isales-engine/isales_engine/run_loop.py` — `_partial_monitor` wall-clock elapsed + `_vad_monitor` ASR-bypass barge-in + VAD-corroboration (2026-05-28)
- ~~`prompt_builder.py` — ROLE/JUDGE/POLISH_OUTPUT_SCHEMA_SUFFIX 强制 JSON schema (2026-05-28)~~ **REMOVED 2026-06-04 by pipeline-stream-and-referee**: main LLM 改纯文本流式，无 output-format suffix；referee 旁路 JSON 决策在 `isales_engine/referee.py`
- `isales-telephony/scripts/mac_dev_no_modem_smoke.py` — reproducer

### PG-side runtime config (mutated 2026-05-28, NO commit — data-only)

| Table | Row | Field | Value | Reason |
|---|---|---|---|---|
| `prompt_version` | id=3 (campaign 1 active judge) | `content` | 去除遗留 `${roleUser}/${roleAssistant}` 字面 (用户版重写) | LLM 把字面变量字符当 token 解读, 干扰判断逻辑 |
| `campaign` | id=1 ("测试任务") | `interruption_min_duration_ms` | 200 (was 400) | 收窄 barge-in 阈值, 配合本 session VAD bypass + wall-clock 修法 |

> 这两个 UPDATE 仅在 ECS PG 上, 无对应 alembic migration 或 git commit. 若 PG 重置 / 切到新 ECS, 需要重做. 详见 `memory/project_session_2026_05_28_handoff.md`.

## Cloud-edge gRPC end-to-end smoke (verified 2026-05-17 23:25 CST)

Reproducible verification, run from Windows dev box → ECS:

```powershell
# 1. Mint a one-hour test JWT on ECS (uses ISALES_JWT_SECRET from api.env):
ssh -i C:/Users/tianx/codes/isales-4.pem root@121.89.85.150 `
    'set -a; source /etc/isales/env/api.env; set +a; \
     /opt/isales/current/venv/bin/isales-edge-token-mint \
        --device-id edge-test --ttl 1h' > $env:TEMP\smoke.jwt

# 2. Run the smoke from local dev .venv (3.14 works fine; grpcio is the only need):
.venv\Scripts\python.exe scripts\cloud_edge_smoke.py `
    --endpoint 121.89.85.150:50051 --token-file $env:TEMP\smoke.jwt --timeout 15
```

Expected output (under 5 s):

```
==> connecting to 121.89.85.150:50051 ...
==> CONNECTED
==> sending Heartbeat (critical=True) ...
==> Heartbeat sent OK
==> idle 3s to observe any inbound frames ...
==> total inbound frames: 0
==> stopping client ...
==> done
```

The `cloud_edge_stream_error` WARN line on teardown is a normal close-
sequence artifact (engine sends EOS, grpc.aio raises on the client side as
the iterator empties) — not a bug. 0 inbound frames is also normal: engine
doesn't push proactive frames in idle state.

This proves:
- TCP reach across Aliyun security group (50051/tcp + 8000/tcp open from
  external — verified in earlier provisioning; no security group changes
  needed for v1.0 IP-direct)
- gRPC bidi stream up
- engine token verify (alg HS256, sub=edge-01, aud=cloud-edge)
- engine accepts non-critical Heartbeat from edge

Edge-side smoke script: `isales-telephony/scripts/cloud_edge_smoke.py`
(committed 2026-05-17, commit `cbd2d02`). It uses the production
`CloudEdgeGrpcClient` so it exercises the same code path D1 §9.1 ("tray
goes green on activation") would.

### Known trap — mac → ECS 50051 idle-stream cut (2026-05-19)

While running the §3.9 real-cloud smoke for archived
`macos-artc-pyobjc-binding` (`archive/2026-05-19-macos-artc-pyobjc-binding/
acceptance.md`), the bidi stream was observed to be **cut by an
intermediate Aliyun network layer ~1 ms after `call.initial_metadata()`
returns**. Pattern:

- TCP three-way handshake: 100 % succeeds (`nc -zv` instant OK)
- HTTP/2 setup: `call.initial_metadata()` returns
- Next `async for response in call:` iteration: `UNAVAILABLE: Socket
  closed`
- Engine localhost smoke (`127.0.0.1:50051` from the ECS itself):
  3 / 3 reliable — so engine code is fine
- Adding `grpc.keepalive_time_ms=30000` etc. channel options on client
  alone **did not** mitigate; the cut is upstream of the keepalive
  ping cadence

The current diagnosis is an Aliyun-side stateful idle-cleanup (ECS
security group / SLB if interposed / connection-tracking GC). Fix is
tracked in OpenSpec change `cloud-edge-grpc-keepalive`:

1. **Code side** (both sub-repos, this change): symmetric HTTP/2
   keepalive options on `grpc_client.py` and `grpc_server.py` +
   `cloud_edge_stream_connected` / `cloud_edge_stream_opened` INFO
   logs so ops can correlate.
2. **Aliyun console side** (this RUNBOOK): re-confirm the inbound
   50051 security group rule has no idle-cleanup; if an SLB is
   introduced in front, require seven-layer HTTP/2 + idle-timeout
   ≥ 60 min. See `deploy/RUNBOOK-cloud.md` § "50051 TCP idle-timeout
   配置".
3. **Acceptance gate**: `scripts/cloud_edge_smoke.py --soak 600
   --report-file <path>` from a real dev rig MUST report stream
   lifetime p95 ≥ 300 s.

Update this section after the soak gate clears; cite the
`cloud-edge-grpc-keepalive` archive commit for closure.

## Secrets

### Cloud service env files

Real values live in `deploy/cloud/env/{api,engine,scheduler,worker}.env`
of THIS repo (private), committed per the 2026-05-17 decision. See
`deploy/cloud/env/README.md` for the rotation procedure and migration
path when secrets need to leave git. Key values currently in env files:

| Key | Value (audit hint, full value in env file) | Source |
|---|---|---|
| `ISALES_RTC_APP_ID` | `o6dpsan9` | Aliyun RTC console (DingRTC 3.x PaaS) |
| `ISALES_RTC_APP_KEY` | `c4f5feb...` (32 hex) | Aliyun RTC console; cloud-only |
| `ISALES_DINGRTC_LINUX_SDK_PATH` | `/opt/isales/vendor/DingRTC_Linux_SDK_3_9_0` | OS-level vendor, **2026-05-27 PM** (replaced legacy `aliyun-artc-linux-python` path) |
| `LD_LIBRARY_PATH` | `/opt/isales/vendor/DingRTC_Linux_SDK_3_9_0/lib/x86_64` | dlopen `libDingRTC.so` for `dingrtc_pywrap` extension |
| `ISALES_ENGINE_LLM_PROVIDER` | `dashscope` | **2026-05-27 PM** (was `volcengine`); volcengine ark API key ≠ OpenSpeech `app_token`, dashscope api_key reused for Qwen 通义 |
| `ISALES_ENGINE_ASR_PROVIDER` | `volcengine` | V3 SAUC bigmodel (post-2026-05-27-PM rewrite) |
| `ISALES_ENGINE_TTS_PROVIDER` | `volcengine` | V3 SSE SeedTTS 2.0 (post-2026-05-27-PM rewrite) |
| `ISALES_JWT_SECRET` | `7426829e...` (64 hex) | random; identical across api/engine env files |
| `ISALES_DATABASE_URL` | `postgresql+asyncpg://isales:***REMOVED***@127.0.0.1:5432/isales` | local PG, password matches `pg_hba` config |
| `ISALES_ENGINE_CLOUD_EDGE_GRPC_BIND` | `0.0.0.0:50051` | v1.0 IP-direct (was `127.0.0.1:50051` until 2026-05-17, see commit `8a0a6ab`) |

The 4 files are mirrored to `/etc/isales/env/*.env` on the ECS
(root:isales 0640), and each systemd unit's drop-in
`/etc/systemd/system/isales-*.service.d/env.conf` sets
`EnvironmentFile=/etc/isales/env/<svc>.env`.

### GitHub PAT on ECS (for `git pull` / OTA upgrade path)

Classic PAT, owner `tommax-bai`. Lives at `/opt/isales/.git-credentials`
(isales:isales 0600). git config `credential.helper=store` is set in
`/opt/isales/.gitconfig` (isales home is `/opt/isales`, NOT `/home/isales`
— `useradd -d /opt/isales`). Verified by `sudo -u isales -H git ls-remote
isales-common.git` returning the HEAD SHA.

This unblocks in-place `git pull` for release updates from ECS without
needing to scp from the dev box. (Note: PAT classic = full `repo` scope.
A future tightening would re-issue as fine-grained PAT with Contents:Read
on the 5 repos only.)

Token expiration: 90 days from creation (default; verify before TTL
elapses via GitHub Settings → Developer Settings → Personal access
tokens). When expiring:

```bash
# Replace TOKEN on the next line and run:
printf 'https://tommax-bai:<NEW>@github.com\n' | \
    ssh -i C:/Users/tianx/codes/isales-4.pem root@121.89.85.150 \
    'tee /opt/isales/.git-credentials > /dev/null && \
     chown isales:isales /opt/isales/.git-credentials && \
     chmod 0600 /opt/isales/.git-credentials'
# Sanity:
ssh ... 'sudo -u isales -H git ls-remote https://github.com/tommax-bai/isales-common.git refs/heads/main'
```

### EDGE_DEVICE_TOKEN for current dev rig

`device_id=edge-01`, TTL 365d (expires ~2027-05-17), minted via:

```bash
ssh ... 'set -a; source /etc/isales/env/api.env; set +a; \
    /opt/isales/current/venv/bin/isales-edge-token-mint \
        --device-id edge-01 --ttl 365d'
```

For local testing, full token sits at the Windows dev box repo path
`isales-telephony/.edge-token-test.jwt` (gitignored by `*.jwt` rule
in `isales-telephony/.gitignore`). For each new edge / device, mint a
fresh token with its own `--device-id`.

## DingRTC SDK vendor — where the binaries live

**Switched 2026-05-26 from ApsaraVideo Live ARTC SDK → DingRTC 3.x** (see
openspec change `engine-rtc-dingrtc-migration`). Root cause: ECS AppId
`o6dpsan9...` is a DingRTC 3.x AppId (RTC PaaS new-generation), while
the SDK we'd been using (`AliRTCSDK_Linux-7.10.2` from
`alivc-demo-cms.alicdn.com`) is from the **ApsaraVideo Live** product
line — cross-product, the Live SDK's tokens are rejected by the DingRTC
roomserver (`ERR_JOIN_BAD_TOKEN 0x02010205`).

vendor README confirms (`api/README` in Linux/Windows SDK):
> DingRTC，作为AliRTC的升级版本，接口定义保持一致。服务器为钉钉的基础设施，
> 和旧版本AliRTC并不互通。

DingRTC SDK is proprietary and **gitignored** in every repo it touches.
Three platform variants, three locations:

| Platform | Used by | Location | sha256 (zip) |
|---|---|---|---|
| Linux C++ SDK (`libDingRTC.so`) | cloud engine | **ECS**: `/opt/isales/vendor/DingRTC_Linux_SDK_3_9_0/` (extracted from zip); dev mac: `~/codes/vendor/DingRTC_Linux_SDK_3_9_0/`. Project-internal pybind11 binding in `isales-engine/isales_engine/transport/dingrtc/`. | `3dc2361fbf6e9e181aba0fbdc30b488064e47f866c7d2d2ab1607c3cd53622e6` |
| Windows C++ SDK (`DingRTC.dll`) | edge (Windows client) | Dev rig + customer machines: `~/codes/vendor/DingRTC_Windows_SDK_3_9_0/`. Project-internal pybind11 binding in `isales-telephony/deploy/edge/windows/pybind/dingrtc_pywrap/` (rewritten from `aliyun_artc_pywrap`). | `f59482589a211e3fc4368c4750dfa50603f03c0acdf3d157728a41ac1ca19974` |
| macOS framework (`DingRTC.framework`) | edge (Mac dev/QA only) | dev mac: `~/codes/vendor/DingRTC_macOS_SDK_3_9_0/`. PyObjC binding in `isales-telephony/isales_telephony/audio_bridge/macos_dingrtc_pyobjc.py`. | `197337f2bc2ff2476abc988672cf5b20b381f5e12e9069f37dbd3fd157f7020e` |

Direct download URLs (no auth required, OSS bucket
`dingrtc.oss-cn-zhangjiakou.aliyuncs.com`, 2025-04-15 release):

```
https://dingrtc.oss-cn-zhangjiakou.aliyuncs.com/sdk/linux/3.9.0/DingRTC_Linux_SDK_3_9_0.zip
https://dingrtc.oss-cn-zhangjiakou.aliyuncs.com/sdk/windows/3.9.0/DingRTC_Windows_SDK_3_9_0.zip
https://dingrtc.oss-cn-zhangjiakou.aliyuncs.com/sdk/mac/3.9.0/DingRTC_macOS_SDK_3_9_0.zip
```

Three-end SDK MUST be the same minor + patch (互通保证 per vendor doc).
v1.0 locks to **3.9.0**. Upgrading minor / patch requires all-three-ends
in one PR.

Demo appid `a4zfr1hn` (in vendor demo sample packs) is used for isolated
PoC — verify "SDK + binding + rtc_token.py algorithm" work before
touching real `o6dpsan9...` credentials.

### Cloud Linux SDK structure

```
/opt/isales/vendor/DingRTC_Linux_SDK_3_9_0/
├── api/                                # C++ headers (cloud + Windows share)
│   ├── engine_interface.h              # class ding::rtc::RtcEngine
│   ├── engine_types.h                  # RtcEngineAuthInfo / RtcEngineAudioFrame / ...
│   ├── engine_conf.h                   # error codes (RtcEngineErrorJoinBadToken etc.)
│   ├── engine_utils.h
│   └── README                          # vendor product-line note
└── lib/x86_64/
    ├── libDingRTC.so                   # main SDK
    └── libffmpeg.so                    # ffmpeg dep
```

Headers, struct shapes, and selectors are captured in
`openspec/changes/engine-rtc-dingrtc-migration/notes/sdk_api_ground_truth.md`
— that file is the API reference for binding work.

### Build & runtime

Cloud Linux binding (project-internal pybind11):
1. `apt install build-essential cmake python3-dev` (or `dnf install gcc gcc-c++ cmake python3-devel`)
2. `pip install pybind11`
3. `cd isales-engine && pip install -e .` — invokes scikit-build / CMake
4. Produces `dingrtc_pywrap.so` inside `isales_engine/transport/dingrtc/`
5. At runtime, `LD_LIBRARY_PATH` must include `/opt/isales/vendor/DingRTC_Linux_SDK_3_9_0/lib/x86_64/`
6. `ISALES_DINGRTC_LINUX_SDK_PATH` env var overrides default vendor location

### ECS-deployed snapshot (2026-05-26)

| Layer | Value |
|---|---|
| `/opt/isales/current` → | `/opt/isales/releases/20260517-222944` |
| `isales-engine` commit on box | `243fbc1` (dingrtc-migration-cloud — `push_audio` SIGFPE fix) |
| `dingrtc_pywrap.so` location | `/opt/isales/current/venv/lib64/python3.11/site-packages/dingrtc_pywrap.cpython-311-x86_64-linux-gnu.so` |
| Build inputs | `VIRTUAL_ENV=/opt/isales/current/venv bash deploy/cloud/scripts/build-dingrtc-binding.sh` |
| §5.4 smoke verified | 2026-05-26 — `OnJoinChannelResult code=0` + 10s clean listen loop + `inbound_frames=1001 / push_count=99 / exit 0` |
| §5.1 self-sign verified | 2026-05-26 (`rtc_token.py::_pack_options` fix, byte-perfect vs vendor console "Token生成器") |

Box can't reach `github.com` over HTTPS (no PAT installed); deploy flow
for now = `scp` loose files from dev mac + `chown isales:isales` +
rebuild binding via the script above. To switch to `git pull` deploys,
either install a PAT at `~/.git-credentials` or set up SSH deploy key.

### Migration from ApsaraVideo Live ARTC SDK (legacy, gone)

The previous vendor layout (`/opt/isales/current/vendor/aliyun-artc-linux-python/`,
137 MiB Python wrapper + TCP sidecar `AliRtcCoreService`) is **obsolete**.
Per `engine-rtc-dingrtc-migration` § 6, the old wrapper code
(`isales-engine/isales_engine/transport/{aliyun_rtc,_rtc_sdk,_rtc_driver}.py`,
~1269 lines) is deleted; old vendor directories on ECS can be cleaned up
once the DingRTC cloud smoke is green. The
`engine-artc-sdk-thread-model` change is being archived as "superseded by
DingRTC migration — sidecar pump model no longer needed".

## OSS / object storage

**Not provisioned in v1.0.** The decision is to use ECS local
filesystem for v1.0 storage needs (recording uploads, opener prerender
PCM). v1.0 worker code doesn't yet exercise `ISALES_OSS_*` envvars, so
this is a no-op decision today; if/when recording upload lands, switch
to either OSS or a larger ECS disk.

## Active OpenSpec changes touching the cloud (status 2026-06-08)

> 2026-06-08 清账：active change 22 → 5（+1 当日新建并已部署）。归档 17 个见顶部 16:03 "openspec 文档清账" 条目。
> **下表只列剩余 active**；已归档的（含 `arch-cloud-edge-split` A2 数据面奠基、`windows-artc-pybind11` ×2）见
> `openspec/changes/archive/2026-06-08-*`。

| Change | Status（真实，非 tasks.md 勾选） | Cloud impact |
|---|---|---|
| `engine-rtc-dingrtc-migration` | 75/90；cloud+mac 段已部署运行，Windows binding §7 未起 | 云端 engine 已跑 DingRTC（**已部署**）；归档卡 Windows 真机 |
| `interruption-detection-text-length-gate` | 0/35；打断门控原型硬编码**已在生产**，config 化/测试/schema 未做 | 云端 engine 打断检测路径（原型在跑，正式化待补） |
| `joint-mvp-gate-13301035545` | 15/47；CLI/脚本就绪，等 dingrtc Windows 才能真拨 | 联合 MVP 验收门，依赖云+边都就绪 |
| `pipeline-stream-realmachine-acceptance` | 0/9；纯验收，卡 bug2（远端挂断 loop 冻死）+ Windows 硬件 | 验收已部署的 gate-first 双 LLM 管线 |
| `edge-modem-audio-out-recovery` | 13/32；上行+发现已做，soft-reset 核心未写 | Edge-side（Windows modem 仍需手动重插 USB） |
| `web-admin-scene-single-page-config` | §1-6 **已部署**（2026-06-08，见顶部 16:03 条目）；tasks.md 仍 0/34 | web admin（场景单页配置，承接单角色 IA 的 D6 deferred） |

历史（已归档）：`windows-client-core`(D1) + `impl-real-at`(A1) 2026-05-17 归档；`arch-cloud-edge-split`(A2，本快照 IS
其数据面) + `windows-artc-pybind11` ×2 于 2026-06-08 清账时归档。

## Deviations from spec to record at archive time

When A2 is archived, the following deviations must land as `design.md`
notes in the archived `openspec/changes/archive/...` directory:

1. **AL3 vs Ubuntu 22.04** — install.sh not actually adapted to dnf; manual
   port used 2026-05-17 (Steps A-G in the conversation log; reproducible).
2. **Python 3.11 vs 3.12** — install.sh `step_venv` hardcoded `python3.12`
   which AL3 doesn't provide; switched to `python3.11` (still satisfies
   `requires-python = ">=3.11"`).
3. **PG 13 vs PG 16** — schema-compatible; cite "alinux3-updates default" reason.
4. **8C8G vs 4C16G** — half RAM; load-test to confirm; bump if needed.
5. **PG + Redis on the ECS vs managed RDS/Tair** — no HA; cite v1.0 PoC scope.
6. **No OSS** — local filesystem; cite "worker doesn't read OSS_* yet".
7. **No nginx + no domain + no TLS** — v1.0 IP-direct; cite STATE.md
   posture decision.
8. **No isales-web** — admin console deferred; cite same scope decision.
9. **install.sh `ISALES_DOMAIN` hard-require + nginx step** — bypassed by
   running phases manually; the script proper should grow a `--ip-direct`
   mode flag.
10. **Secrets in private repo git** — non-default policy; cite "single
    collaborator + internal PoC" with the README's migration path.

## Next deployment steps (what's still pending)

In rough order. **This list is authoritative for cloud-side punch-list
status — A2 OpenSpec `tasks.md` checkboxes are signed-in progress, not
ground truth.**

1. ~~Mirror `deploy/cloud/env/*.env` to `/etc/isales/env/` on the ECS.~~
   **DONE 2026-05-17**.
2. ~~Adapt `deploy/cloud/scripts/install.sh` for AL3 dnf.~~ **WORKED
   AROUND 2026-05-17** via manual phase-by-phase run; proper script
   adaptation still owed for next clean deploy. Reasonable timing: when
   first OTA upgrade is needed or when standing up a second ECS.
3. ~~Upload ARTC SDK Linux Python tarball.~~ **DONE 2026-05-17**.
4. ~~Clone 5 sibling repos + venvs + alembic + systemd + engine
   `0.0.0.0:50051` bind + security group.~~ **DONE 2026-05-17**.
5. ~~nginx + Let's Encrypt + domain.~~ **DEFERRED to v1.x**.
6. **End-to-end MVP**: scheduler dispatches a fake lead → engine joins
   ARTC channel → edge (Windows) joins same channel → audio flows → AI
   says opener → hang up. **A2 §12 / D1 §9 joint MVP gate.** Sub-gates:
   - ✅ Cloud-edge gRPC control plane (smoke 2026-05-17, see § above)
   - ❌ **pybind §9.4** real ARTC RTC join on Windows edge (needs RTC
     client token signed with AppKey)
   - ❌ **pybind §9.5** real PCM push/pull end-to-end P95 ≤ 50 ms
   - ❌ **AI provider stack ready** — grep `engine.env` for which
     ASR/LLM/TTS provider is wired; if mock, swap to 豆包 / real provider
   - ❌ **PG seed data** — `campaign` + `lead` rows pointing at test
     phone number (e.g. dev's own `13301035545`)
   - ❌ **isales-telephony-edge full daemon on dev box** — pyserial COM12
     (AT) + COM11 (audio SerialPcm) + ARTC pybind + cloud-edge gRPC
     client all wired through `main_windows.py` or `edge/main.py`
7. **isales-web admin console deploy** — deferred until UX needs require it.

## pipeline-stream-and-referee 运维 (2026-06-04)

**部署顺序** (editable install, scp/rsync 源码即生效): common → engine → worker
→ api → web。common 先跑 `alembic upgrade head`，再 seed campaign 配置，最后
4 服务一起 restart（避免旧进程查到被删的 role 行）。详见 change `design.md`
Migration Plan。

**post-call extractor 排障**: engine 在 call 结束 LPUSH `isales:extract` +
`call_record.extract_status='pending'`；worker `extract_loop` BLPOP 处理后置
`'done'`(+`extracted`) 或 `'failed'`(+`extract_error`)，**失败不重 LPUSH**(防
雪崩)。查失败通话:
```sql
SELECT id, extract_status, extract_error FROM call_record WHERE extract_status='failed';
```
手工重跑某通: `redis-cli LPUSH isales:extract '{"call_record_id":<id>,
"transcript_snapshot":[...],"extractor_role_config_id":<id>,
"extractor_prompt_version_id":<id>}'`（transcript_snapshot 从 call_record.
transcript 取 dialog 事件）。

**campaign 重建**: migration 删了所有 role/judge/polish 行；每个 campaign 需用
`isales-api/scripts/seed_pipeline_stream_campaign.py <campaign_id>` 重建
main/referee/extractor 三 role_config + prompt_version（或在 web admin 手建）。

## Bootstrap a new dev session — verify before asserting state

A fresh Claude Code session should run these 4 commands (each ~10 s)
before reporting any cloud-side status. Each verifies one layer against
authoritative sources, replacing the "trust the OpenSpec checkbox"
failure mode (see [[feedback-ground-truth-before-pending]] memory).

```powershell
# 1. ECS reachable + 4 services up + ports listen
ssh -i C:/Users/tianx/codes/isales-4.pem -o ConnectTimeout=8 root@121.89.85.150 `
    'systemctl is-active isales-api isales-engine isales-scheduler isales-worker postgresql redis; \
     echo "---"; ss -tln | grep -E ":50051|:8000"'
# expect: 6 "active" lines + "0.0.0.0:50051" + "0.0.0.0:8000" listeners

# 2. alembic at head + 19 tables
ssh -i C:/Users/tianx/codes/isales-4.pem root@121.89.85.150 `
    'cd /opt/isales/current/isales-common && set -a && source /etc/isales/env/api.env && set +a && \
     sudo -u isales -H -E env ISALES_DATABASE_URL="$ISALES_DATABASE_URL" \
        /opt/isales/current/venv/bin/alembic current; \
     echo "---"; cd /tmp && sudo -u postgres psql -d isales -tAc \
        "SELECT count(*) FROM pg_tables WHERE schemaname = '\''public'\'';"'
# expect: "580b817550c8 (head)" + "20" (19 tables + alembic_version)

# 3. cloud-edge gRPC reachable from local box
Test-NetConnection -ComputerName 121.89.85.150 -Port 50051 -WarningAction SilentlyContinue | `
    Select-Object ComputerName,RemotePort,TcpTestSucceeded
# expect: TcpTestSucceeded True

# 4. cloud-edge end-to-end smoke (mint fresh token + run smoke)
ssh -i C:/Users/tianx/codes/isales-4.pem root@121.89.85.150 `
    'set -a; source /etc/isales/env/api.env; set +a; \
     /opt/isales/current/venv/bin/isales-edge-token-mint --device-id edge-test --ttl 1h' `
    > "$env:TEMP\smoke.jwt"
cd C:\Users\tianx\codes\isales-telephony
.\.venv\Scripts\python.exe scripts\cloud_edge_smoke.py `
    --endpoint 121.89.85.150:50051 --token-file "$env:TEMP\smoke.jwt" --timeout 15
# expect: "==> CONNECTED" + "==> Heartbeat sent OK" + "==> done"
```

If ANY of the 4 fails, that is the ground truth — report it and dig in.
**Never** infer cloud state from OpenSpec tasks.md checkbox alone (see
[[feedback-ground-truth-before-pending]] for past regressions and
prevention rules).

## Related state files

- `deploy/edge/windows/STATE.md` — Windows dev rig (Python 3.12, CMake,
  VS BuildTools, ARTC Windows SDK, pybind .pyd, SIM7600G-H modem)
- `archive/2026-05-17-windows-client-core/acceptance.md` — D1 archived
  acceptance log; § "Out-of-scope deferred items" lists §9 joint MVP gates
- `archive/2026-05-17-impl-real-at/acceptance.md` — A1 archived; §3.4
  hangup_cause samples deferred to D1 §9.3 (now joint MVP)
