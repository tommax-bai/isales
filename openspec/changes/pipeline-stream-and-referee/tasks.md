## 1. isales-common：数据模型 + alembic migration

<!-- 0c5d35f section 1+2 isales-common 全部完成, tests 158 passed, mypy/ruff 干净, alembic head=c3d4e5f6a7b8. 偏离见各 task 注释。 -->

- [x] 1.1 在 `isales_common/models/role_config.py` 把 `RoleKind` enum 从 `{role, judge, polish}` 改成 `{main, referee, extractor}`；同步更新 SQLAlchemy 字段约束 + Pydantic schema <!-- 0c5d35f RoleKind+PromptScopeType 实际定义在 isales_common/enums.py(StrEnum/VARCHAR), 非 model 内; model+schema docstring 同步改 -->
- [x] 1.2 在 `isales_common/models/pipeline_trace.py` 删除字段 `role_candidates / judge_results / polish_input / polish_output / polish_duration_ms / polish_role_config_id / polish_prompt_version_id / final_selected_candidate_index`；新增字段 `main_reply_text(Text) / main_duration_ms(Int) / main_tokens_in(Int) / main_tokens_out(Int) / main_fallback_used(Bool, default false) / referee_decision(Text) / referee_goal_type(Text, nullable) / referee_confidence(Real, nullable) / referee_duration_ms(Int) / first_audio_ms(Int) / error(Text, nullable)` <!-- 0c5d35f 偏离: error 列原本不存在(1.7 注释说"error 已存在"有误), 已新增 -->
- [x] 1.3 在 `isales_common/models/call_record.py` 新增字段 `extracted(JSONB, nullable) / extract_status(VARCHAR(16), nullable) / extract_error(Text, nullable)`；`prompt_versions` JSONB 的 schema 文档化为 `{main_llm, referee_llm, extractor_llm, wrap_up_appended}`（DB 层仍是 JSONB 自由结构） <!-- 0c5d35f + CallRecordRead DTO 同步加三字段 -->
- [x] 1.4 在 `isales_common/models/campaign.py` 新增字段 `filler_enabled(Bool, default false)` <!-- 0c5d35f -->
- [x] 1.5 在 `isales_common/models/prompt_version.py` 把 `scope_type` 允许值文档化为 `{main, referee, extractor}` <!-- 0c5d35f model 文件名实为 prompt.py; enums.PromptScopeType 已改 -->
- [x] 1.6 删除 `isales_common/schemas/pipeline.py` 中的 `RoleSpec / JudgeSpec / PolishSpec / PipelineConfig` 旧数据类；新增 `MainSpec / RefereeSpec / ExtractorSpec / PipelineConfig (refactored)`，新 PipelineConfig schema：`{main: MainSpec, referee: RefereeSpec, extractor: ExtractorSpec, short_reply_active: bool}` <!-- 0c5d35f 偏离: 旧 RoleSpec/JudgeSpec/PolishSpec/PipelineConfig 实际在 isales-engine/pipeline/prompt_builder.py(section 6 删除); schemas/pipeline.py 是全新创建(pydantic AppModel), 并 export 到 schemas/__init__ -->
- [x] 1.7 alembic 写 migration `c3d4e5f6a7b8_pipeline_stream_and_referee.py`： <!-- 0c5d35f 偏离: kind/scope_type 是 VARCHAR+app validation 非 PG enum, 所以无 ALTER TYPE, 仅 DELETE 旧行; DELETE 同时清 prompt_version 旧 scope; data migration carry call_summary.extracted_fields -> call_record.extracted -->
  - `ALTER TYPE role_kind RENAME TO role_kind_old`
  - `CREATE TYPE role_kind AS ENUM ('main', 'referee', 'extractor')`
  - `DELETE FROM role_config WHERE kind IN ('role', 'judge', 'polish')`（DELETE 先于 ALTER COLUMN，避免 enum 切换时报旧值）
  - `ALTER TABLE role_config ALTER COLUMN kind TYPE role_kind USING kind::text::role_kind`
  - `DROP TYPE role_kind_old`
  - 同样手段切 `prompt_version.scope_type` 枚举（如果有 enum 约束的话，否则 VARCHAR 直接 DELETE）
  - `ALTER TABLE pipeline_trace DROP COLUMN role_candidates / judge_results / polish_input / polish_output / polish_duration_ms / polish_role_config_id / polish_prompt_version_id / final_selected_candidate_index`
  - `ALTER TABLE pipeline_trace ADD COLUMN main_reply_text TEXT / main_duration_ms INT / main_tokens_in INT / main_tokens_out INT / main_fallback_used BOOL DEFAULT false / referee_decision TEXT / referee_goal_type TEXT / referee_confidence REAL / referee_duration_ms INT / first_audio_ms INT`（error 已存在不动）
  - `ALTER TABLE call_record ADD COLUMN extracted JSONB / extract_status VARCHAR(16) / extract_error TEXT`
  - `ALTER TABLE campaign ADD COLUMN filler_enabled BOOL DEFAULT false`
  - data migration: `UPDATE call_record SET extracted = call_summary.extracted_fields FROM call_summary WHERE call_record.id = call_summary.call_record_id AND call_summary.extracted_fields IS NOT NULL`（保留历史数据迁移到新位置）
- [x] 1.8 写 alembic downgrade 路径（用于 rollback）：复原 enum + DROP 新字段 + 不复原 deleted role_config 行（v1 无产数据，acceptable） <!-- 0c5d35f downgrade 复原 pipeline_trace 旧字段集(含 FK) + DROP 新字段; 不复原 deleted 行 -->
- [x] 1.9 在 `isales-common` 跑 pytest 测试新 schema 数据类 `tests/test_pipeline_schemas.py`：覆盖 MainSpec / RefereeSpec / ExtractorSpec / PipelineConfig 序列化反序列化 <!-- 0c5d35f 6 个 test, extra=forbid 拒旧字段; 全套 158 passed -->
- [x] 1.10 bump isales-common 版本（如 0.x.y+1），写 CHANGELOG 段落（"BREAKING: pipeline 三层架构改双 LLM 架构，role_config.kind 枚举改 / pipeline_trace 字段集换新"） <!-- 0c5d35f 0.4.0 -> 0.5.0 (BREAKING minor, v0.x) + CHANGELOG v0.5.0 段 -->

## 2. isales-common：Provider ABC 新增 chat_stream

- [x] 2.1 在 `isales_common/providers/llm.py` 新增 abstract method `chat_stream(messages, *, temperature, top_p, max_tokens) -> AsyncIterator[str]`；同时新增 `last_call_tokens_in / last_call_tokens_out / last_call_finish_reason` instance attributes（默认 None，子类在 chat_stream 完成时填充） <!-- 0c5d35f abstractmethod 返回 AsyncIterator(非 async def, 便于子类 async generator); MockLLMProvider(common testing) 同步实装 -->
- [x] 2.2 更新 `isales_common/providers/__init__.py` export <!-- 0c5d35f LLMProvider 已在 __init__ export; chat_stream 是其方法无新 symbol -->
- [x] 2.3 在 `isales-common` 跑 mypy / ruff 确保 ABC 类型注解正确 <!-- 0c5d35f mypy: Success no issues; ruff: 我改的文件干净(其余 8 报错是既存他文件) -->

## 3. isales-engine：LLM provider 4 个实装 chat_stream

<!-- engine 把 common 0.5.0 重装为 editable (pin 升 >=0.5.0,<0.6); section 3 是纯 additive, 自身测试全绿; runtime_config/orchestrator 仍引用旧 RoleKind, 由 section 6-7 修。 -->

- [x] 3.1 `providers/llm_openai_compatible.py` 实装 `chat_stream`：用 `stream=True` SSE，解析 `data: {...}` 行的 `delta.content` 作为 token yield；处理 `[DONE]` 终止；中途异常映射为 ProviderError 子类 <!-- httpx client.stream + _parse_sse_line(); stream_options.include_usage 拿 token; 加 transport 注入点便于 MockTransport 测试; HTTP>=400 先 aread() 再 map_http_error -->
- [x] 3.2 `providers/llm_volcengine.py`（如有独立 vendor 实装）实装 chat_stream，参考 vendor SDK 流式接口 <!-- N/A: 无独立 llm_volcengine.py; 火山豆包走 OpenAICompatibleLLMProvider(base_url=ark...), 3.1 已 cover -->
- [x] 3.3 `providers/llm_ark.py` / `providers/llm_dashscope.py`（如有独立实装）实装 chat_stream <!-- N/A: 无独立 ark/dashscope LLM 文件, 全走 openai_compatible -->
- [x] 3.4 mock provider `providers/llm_mock.py` 实装 chat_stream：按时间窗口模拟 token yield（用于本地测试）；支持配置 first_token_ms / per_token_ms 参数 <!-- KeywordDrivenMockLLM(first_token_ms, per_token_ms) 逐字符 yield _decide().content; 默认 0 不 sleep 保持测试快 -->
- [x] 3.5 测试 `tests/test_provider_chat_stream.py`：每个 provider 覆盖正常流式 / 中途异常 / first token 之前 fail / vendor 不支持时 single_yield_fallback <!-- 10 test: SSE parser 单测 + happy + malformed-chunk-skip + 429-before-token + transport-error + mock streaming -->
- [x] 3.6 测试 `tests/test_provider_errors.py` 同步加 chat_stream 路径的异常映射 case <!-- 加 503->ServerError / 400->InvalidRequest / ReadTimeout->Timeout 3 case; 复用 map_http/transport_error -->

## 4. isales-engine：sentence_splitter 模块

<!-- b63e538 (feature 分支 fix/inbound-stereo-downmix-20260601). 用户决策: engine 改造以 feature 分支为基(含全部 DingRTC/TTS-V3/ASR-V3/stereo 工作); origin/main 的 2 个 5/30 latency commit(filler 去阻塞/cancel-wait/连接复用) 由 section 6-7 流式重写覆盖; 分叉 reconcile 留 archive 后 followup。 -->

- [x] 4.1 新建 `isales_engine/streaming/__init__.py` + `isales_engine/streaming/sentence_splitter.py`，实装 `async def split_sentences(token_stream: AsyncIterator[str]) -> AsyncIterator[str]`：累积 token 到 buffer，命中 `。？！` / `\n\n` / 50 字 cap 时 yield 一句；stream 结束时 flush buffer <!-- b63e538 -->
- [x] 4.2 测试 `tests/test_sentence_splitter.py`：中文标点切句 / 50 字 cap / stream 结束 flush / token 碎片化（"您"+"好"+"。"分 3 个 token） <!-- b63e538 8 test 全绿 -->

## 5. isales-engine：referee 模块

- [x] 5.1 新建 `isales_engine/referee.py`，实装 `async def run_referee(session, user_last_utterance, recent_dialog_history, referee_spec, llm) -> RefereeResult`：调 `llm.chat(json_mode=True, messages=...)`，输入 prompt 按 `role-prompt` spec § "referee prompt 内容规范" 渲染，输出 JSON 校验（decision 枚举 / goal_type / confidence 范围），fail-open 默认 `continue` <!-- b63e538 placeholder {{user_last_utterance}}/{{recent_dialog_history}} 替换进 campaign referee prompt; confidence<0.7 非continue降级continue; goal_achieved 缺 goal_type 降级 -->
- [x] 5.2 实装 `_render_dialog_history_for_referee(dialog_history) -> str`：渲染最近 ≤ 3 轮为 `用户：xxx\nAI：xxx` 多行；空 history 渲染占位 `（首轮对话，无历史）`（继承 5/29 archive engine-judge-dialog-context 的渲染规则） <!-- b63e538 全角冒号 用户：/AI：; recent_dialog_rounds() 取 last 3 轮=6 entries -->
- [x] 5.3 测试 `tests/test_referee.py`：4 种 decision 枚举 + fail-open 路径（timeout / invalid JSON / low confidence） + 占位 history <!-- b63e538 13 test -->
- [x] 5.4 `RefereeResult` 数据类放 `isales_engine/streaming/types.py` 或 `referee.py`，含 `decision / goal_type / confidence / duration_ms / raw_output` <!-- b63e538 放 streaming/types.py + RefereeResult.fail_open() classmethod; 偏离: 不加 REFEREE_OUTPUT_SCHEMA_SUFFIX 强制后缀(campaign prompt 自带 schema, 遵循 feedback_avoid_multilayer_fallback) -->

## 6. isales-engine：orchestrator 重写

<!-- 4c88411 (feature 分支). 292 passed (5 个 tts_volcengine fail 是既存 __init__ endpoint kwarg 不符, b63e538 也 fail, 与本 change 无关)。 -->

- [x] 6.1 删除 `isales_engine/pipeline/orchestrator.py` 全部内容（旧三层逻辑） <!-- 4c88411 整文件重写 -->
- [x] 6.2 重写 `orchestrator.py`，新签名 `async def run_pipeline_stream(...)`： <!-- 4c88411 偏离: 返回 PipelineStream 对象(非 tuple)更便于 run_loop 拿 result/referee_task; main_llm/referee_llm 都传 providers.llm(单 provider, per-role model 选择是未来增强) -->
- [x] 6.3 删除 `isales_engine/pipeline/json_parser.py`（main LLM 不再 JSON 输出）；referee 的 JSON 校验放 `referee.py` <!-- 4c88411 git rm -->
- [x] 6.4 删除 `prompt_builder.py` 的 judge/polish 段；保留 main 段 <!-- 4c88411 偏离: 不注入任何 output-format suffix(role-prompt spec "engine MUST NOT 强制注入约束"); referee/extractor prompt 渲染在各自模块(referee.py / worker), prompt_builder 只管 main -->
- [x] 6.5 重写 `tests/test_pipeline.py`：覆盖 main stream + referee 并行 / fallback / 空回复 default / wrap-up 跳 referee / greeting <!-- 4c88411 8 test -->
- [x] 6.6 删除 `tests/test_orchestrator_judge.py` 等历史测试文件 <!-- 4c88411 N/A: 无独立 judge/polish 测试文件(都在 test_pipeline/test_providers 内, 已重写) -->

## 7. isales-engine：run_loop PROCESSING → SPEAKING 流式重构

- [x] 7.1 找 `run_loop.py` PROCESSING→SPEAKING 路径 <!-- 4c88411 _main_turn_loop -->
- [x] 7.2 改造为流式: spawn main+referee → `_play_streaming` 逐句喂 TTS → `_await_referee(2.0)` → decision 驱动 state <!-- 4c88411 main 中途异常 fallback 在 orchestrator 内(yielded_any 前 chat() 兜底); state 映射 goal_achieved→WRAPPING_UP/transfer→TRANSFERRING+hangup/customer_decline→ACTIVATING→LISTENING/continue→LISTENING -->
- [x] 7.3 删除 `await filler.wait_finished()` gate <!-- 4c88411 改 _play_streaming 首句到立即 filler.stop() preempt -->
- [x] 7.4 filler 仅 `campaign.filler_enabled=True` 时 spawn (default false) <!-- 4c88411 RuntimeConfig.filler_enabled 从 campaign 读 -->
- [x] 7.5 PROCESSING 完成写 pipeline_trace 新字段集 <!-- 4c88411 main_reply_text(聚合)/main_duration_ms/main_tokens_*/main_fallback_used/referee_*/first_audio_ms/error; transcript_recorder 同步换字段 -->
- [x] 7.6 确认 session.state 读取无回归 <!-- 4c88411 状态机未动; 删了未用的 asr_partials_q 解包 -->
- [x] 7.7 END 前 LPUSH `isales:extract` + UPDATE `call_record.extract_status='pending'` <!-- f63ef51 在 call_lifecycle.finalize_session; extractor ids 由 run_session 存到 session(call_session.py); payload {call_record_id,transcript_snapshot[{role,text,ts_ms}],extractor_role_config_id,extractor_prompt_version_id}; key=common redis_keys.EXTRACT_QUEUE(3c3f2c3); 无 extractor slot 或无 dialog 时跳过 -->
- [x] 7.8 `tests/test_run_loop.py` 改写 _make_config 为 main/referee/extractor + filler_enabled 参数 <!-- 4c88411 5 test 全绿; dual-LLM mock 驱动 -->
- [x] 7.9 `tests/test_realtime_interruption.py` 同步 <!-- 4c88411 复用 test_run_loop 的 _make_config, barge-in 走 _play_streaming 逐句 _play_tts 仍 INTERRUPTED, 全绿 -->

## 8. isales-engine：删除旧代码

- [x] 8.1 grep `_call_roles_parallel / _run_judges_parallel / _call_polish` 删除所有实装 + 调用 <!-- 4c88411 orchestrator 整体重写已删, grep 源码无残留 -->
- [x] 8.2 grep `JUDGE_OUTPUT_SCHEMA_SUFFIX / POLISH_OUTPUT_SCHEMA_SUFFIX` 删除常量 <!-- 4c88411 prompt_builder 重写已删全部 *_OUTPUT_SCHEMA_SUFFIX -->
- [x] 8.3 grep `_render_dialog_history_for_judge` 删除 <!-- 4c88411 已删; 新 _render_dialog_history_for_referee 在 referee.py(b63e538) -->
- [x] 8.4 删除 `tests/test_orchestrator_judge*.py` / `tests/test_polish*.py` 等历史测试 <!-- 4c88411 N/A 无此独立文件 -->
- [x] 8.5 跑全量 pytest 确保无回归 <!-- 4c88411 292 passed, 5 既存 tts_volcengine fail 与本 change 无关(stash 验证 b63e538 也 fail) -->
- [x] 8.6 commit + push isales-engine feature branch <!-- 4c88411 push fix/inbound-stereo-downmix-20260601 -->

## 9. isales-worker：post_call_extractor consumer

<!-- d84cbf7 (worker main). 50 passed, ruff/mypy 干净。PG 本机可达。 -->

- [x] 9.1 升级 isales-common 依赖到新版本 <!-- d84cbf7 pin >=0.5.0,<0.6 + reinstall editable -->
- [x] 9.2 新建 `isales_worker/post_call_extractor.py`：BLPOP `isales:extract` → 调 extractor LLM → UPDATE `extracted/extract_status='done'`；失败 `'failed'+extract_error` <!-- d84cbf7 偏离: worker LLMProvider ABC 无 chat(), 改加 extract(transcript,prompt) 抽象方法; MockProvider 实装(real provider stage5 再补); 失败不重 LPUSH(防雪崩); handle_extract_task 永不抛 -->
- [x] 9.3 在 `isales_worker/main.py` 启动 extractor consumer task <!-- d84cbf7 extract_loop 与 callend/retry/metrics 并列 create_task + 优雅停 -->
- [x] 9.4 systemd unit / 集成进现有 isales-worker.service <!-- d84cbf7 选择: in-process(main.py 内 task), 无独立 unit; 现有 isales-worker.service 直接 cover -->
- [x] 9.5 测试 `tests/test_post_call_extractor.py`：成功 / LLM 失败 / JSON 校验失败 / bad-json / missing-id <!-- d84cbf7 5 test 全绿(真 PG) -->
- [x] 9.6 commit + push isales-worker <!-- d84cbf7 push main -->

## 10. isales-api：role_config + campaign API schema 更新

<!-- f37395c (api main). 103 passed, ruff 干净。common filler_enabled schema 在 36d8faa(common)。 -->

- [x] 10.1 升级 isales-common 依赖到新版本 <!-- f37395c pin >=0.5.0,<0.6 -->
- [x] 10.2 `role_configs.py` kind 枚举 `{main,referee,extractor}` <!-- f37395c 偏离: 通用 CRUD, kind 校验走 common RoleKind enum 自动拒旧值, 无独立 judge/polish 创建路径需删; 仅改 docstring -->
- [x] 10.3 `campaigns.py` PATCH 加 `filler_enabled` <!-- f37395c CampaignNestedUpdate 加字段; router model_dump 通用映射 -->
- [x] 10.4 campaign 响应 model 加 `filler_enabled` <!-- f37395c 偏离: CampaignBase/CampaignRead 在 common schemas/campaign.py(非 api), 加在那里覆盖 Create+Read(36d8faa) -->
- [x] 10.5 验证 role_configs 过滤 kind 用新枚举 <!-- f37395c test_kind_filter main/referee 全绿 -->
- [x] 10.6 测试更新 <!-- f37395c 偏离文件名: test_campaign_configs.py + test_campaigns_crud.py(非 *_api.py); 迁移 role/judge/polish→main/referee/extractor + 加 filler_enabled 测试 -->
- [x] 10.7 commit + push isales-api <!-- f37395c push main -->

## 11. isales-web：UI 重构

<!-- b14482f (web main). typecheck CLEAN, 38 vitest passed, eslint 干净。 -->

- [x] 11.1 升级依赖 <!-- b14482f types 手写对齐(无 npm 私服); RoleKind/PromptScopeType/Campaign/PipelineTraceTurn 全改 -->
- [x] 11.2 CampaignDetail 3-tier prompt 区改 main/referee/extractor <!-- b14482f PromptTierEditor kind/title/description 全换; scope_type=kind 自动对齐 -->
- [x] 11.3 main prompt 纯文本提示 <!-- b14482f main tier description 写 "纯文本流式回复, 不要 JSON/markdown/emoji" -->
- [ ] 11.4 referee "插入推荐模板" 按钮 <!-- 推迟(纯锦上添花): 模板内容已在 seed 脚本 + spec; 留 followup -->
- [ ] 11.5 extractor "字段 schema 辅助生成" <!-- 推迟(纯锦上添花) -->
- [x] 11.6 filler_enabled toggle + 提示 <!-- b14482f BasicTab 加 el-switch + "首音频~500ms, 仅慢模型建议启用" hint; 默认 false -->
- [ ] 11.7 model 选择器 hover 推荐星级 <!-- 推迟(纯锦上添花) -->
- [x] 11.8 pipeline_trace 查看页字段集换新 <!-- b14482f PipelineTracePanel 重写: main_reply_text/首音频ms/main耗时/tokens/referee_decision(带 tag)/goal_type/confidence/fallback/error; 删 candidates/judges/polish -->
- [x] 11.9 vitest + lint 无回归 <!-- b14482f 38 passed(修了 1 个既存 default_replies textarea selector 失败, 非本 change 引入); eslint 干净 -->
- [x] 11.10 commit + push isales-web <!-- b14482f push main -->

## 12. campaign 配置数据重建脚本

- [x] 12.1 新建 `scripts/seed_pipeline_stream_campaign.py` <!-- ba5ab0e 放 isales-api/scripts/; 幂等(先删本 campaign role_config+prompt_version 再建 main/referee/extractor 三行); prompt 用 spec 推荐模板; 读 ISALES_DATABASE_URL, 默认 campaign 1; SEED_*_MODEL env 可覆盖 model -->
- [ ] 12.2 在 mac dev 跑 seed 脚本 ECS 同步跑 <!-- 部署步骤, 与 §14 ECS 部署一起做(需真 DB + 已 migrate) -->
- [ ] 12.3 ECS 上手工 verify `SELECT kind, model FROM role_config WHERE campaign_id=1` <!-- 同上, 部署后验证 -->

<!-- ===== 代码部分 (§1-12,17) 全部完成: common 36d8faa / engine f63ef51(feature 分支 fix/inbound-stereo-downmix-20260601) / worker d84cbf7 / api+seed ba5ab0e / web b14482f. 各仓测试全绿(engine 5 个 tts_volcengine fail 为既存与本 change 无关)。剩 §13-16,18 是部署+真机验收阶段, 需 mac 麦克风/Windows 拨号机/ECS, 且 §14 含破坏性 migration(删 role/judge/polish 行)需用户确认。 ===== -->

## 13. mac dev 端到端验证（强阻断 ECS 部署）

- [ ] 13.1 mac dev fake-WAV smoke：dev-no-modem 模式跑 5 通 fake_mic 通话，verify 首音频 < 1.5s（pipeline_trace.first_audio_ms 字段），referee 决策正常驱动 state，extractor LPUSH 触发，worker 离线写入 extracted
- [ ] 13.2 mac dev 真 mic 跑 5 通真对话，戴耳机听质量，确认 main streaming 流畅 + 标点切句自然 + barge-in 不回归
- [ ] 13.3 mac dev pipeline_trace SQL 抽样：first_audio_ms 中位数 / referee_decision 分布 / main_fallback_used 频率
- [ ] 13.4 mac dev pytest 全跑（engine + common + worker + api）确保无回归

## 14. ECS 云部署

- [ ] 14.1 部署 isales-common：scp 整个包到 ECS `/opt/isales/current/isales-common`，跑 alembic upgrade head
- [ ] 14.2 部署 isales-engine：scp 改后的 orchestrator.py / run_loop.py / referee.py / streaming/* + provider 实装文件到 ECS
- [ ] 14.3 部署 isales-worker：scp post_call_extractor.py + main.py
- [ ] 14.4 部署 isales-api：scp 更新的 routers / schemas
- [ ] 14.5 部署 isales-web：build artifacts upload 到静态 host
- [ ] 14.6 systemctl restart 4 个服务（engine / worker / api / web）+ 看启动 log 无异常
- [ ] 14.7 跑 ECS 端 campaign seed 脚本（task 12.2 已在 mac 跑，ECS 同步 / 重跑）
- [ ] 14.8 更新 `deploy/cloud/STATE.md` 反映新 pipeline 架构 + 4 服务版本号

## 15. Windows 真拨号联合验收

- [ ] 15.1 Windows 真拨号 13301035545 e2e ≥ 10 通：覆盖 goal_achieved 路径（成功约见） / customer_decline 路径（客户拒绝） / transfer 路径（要求人工） / continue 路径（普通多轮聊）
- [ ] 15.2 验证首音频 ≤ 1.5s（戴耳机听感 + journalctl `grep first_audio_ms`）
- [ ] 15.3 验证 referee 决策驱动 WRAPPING_UP / TRANSFERRING 状态机转移正确
- [ ] 15.4 验证 post-call extractor 异步写入 call_record.extracted 字段（SQL 查 + worker 日志）
- [ ] 15.5 验证 5/28 barge-in 在新 streaming 链路下不回归
- [ ] 15.6 验证 main streaming 网络抖动场景：mac 网络模拟 200ms 延迟 + 5% 丢包，看 fallback chat() 是否触发 + 通话能完成

## 16. RUNBOOK 更新

<!-- 与 §14 ECS 部署一起做: STATE.md 是 ECS 实际状态快照, 新代码未部署前 line 430(ROLE/JUDGE/POLISH_OUTPUT_SCHEMA_SUFFIX)仍准确描述当前 ECS 上的旧 engine; 现在改 STATE.md 会让它谎报状态(违反 ground-truth)。部署同 commit 再更新。 -->

- [ ] 16.1 更新 `deploy/RUNBOOK.md` 部署顺序段落（common → engine → worker → api → web）+ campaign 配置重建步骤 <!-- 部署时做; design.md Migration Plan 已有完整步骤 -->
- [ ] 16.2 更新 `deploy/RUNBOOK-cloud.md` 同步
- [ ] 16.3 更新 `deploy/cloud/STATE.md` § "AI 三层管线" 段落改为 § "双 LLM 架构" <!-- 仅在 §14 真部署后改, 否则谎报 -->
- [ ] 16.4 在 RUNBOOK 增加新章节 § "post-call extractor 排障"：如何查询 `extract_status='failed'` 通话 + 如何手工重跑 LPUSH

## 17. 历史 change housekeeping

- [x] 17.1 engine-judge-dialog-context proposal.md 顶部加 SUPERSEDED-by 注释 <!-- 本 commit -->
- [x] 17.2 impl-web-polish proposal.md 顶部加 SUPERSEDED-by 注释 <!-- 本 commit -->
- [x] 17.3 其他 polish/judge archive 标 SUPERSEDED <!-- 本 commit: impl-engine + impl-engine-providers 加 PARTIALLY-SUPERSEDED-by(pipeline 部分被替, 状态机/provider ABC 等保留); grep 确认这 4 个是全名单 -->

## 18. 验证 + archive

- [ ] 18.1 `openspec validate pipeline-stream-and-referee --strict` 最终通过
- [ ] 18.2 跑 `/opsx:archive pipeline-stream-and-referee` 合并 spec delta 到 `openspec/specs/`，移动 change 目录到 `openspec/changes/archive/YYYY-MM-DD-pipeline-stream-and-referee/`
- [ ] 18.3 archive commit + push meta-repo

## 19. followup（不在本 change scope，记录在此用于下次 change 起源）

- [ ] 19.1 followup change `asr-fast-eos`：把 `_PARTIAL_STABLE_S` 从 0.7s 降到 0.3s + vendor finalize race，进一步降低 700ms 首音频延迟
- [ ] 19.2 followup change `pipeline-remove-filler`：本 change archive 后 3 个月内无 campaign 启用 filler 则删除全部 filler 代码（filler_manager / filler_set 表 / filler_phrase 表 / UI）
- [ ] 19.3 followup change `pipeline-remove-streaming-fallback`：streaming 链路 30 天 SLA ≥ 99.5% 后删 main `chat()` 一次性 fallback
- [ ] 19.4 followup change `campaign-feature-gating`：多 campaign A/B / 灰度发布机制
- [ ] 19.5 followup change `referee-reliability`：referee 失败重试策略评估
