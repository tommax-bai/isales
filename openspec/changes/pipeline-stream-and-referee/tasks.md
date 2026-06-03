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

- [ ] 3.1 `providers/llm_openai_compatible.py` 实装 `chat_stream`：用 `stream=True` SSE，解析 `data: {...}` 行的 `delta.content` 作为 token yield；处理 `[DONE]` 终止；中途异常映射为 ProviderError 子类
- [ ] 3.2 `providers/llm_volcengine.py`（如有独立 vendor 实装）实装 chat_stream，参考 vendor SDK 流式接口
- [ ] 3.3 `providers/llm_ark.py` / `providers/llm_dashscope.py`（如有独立实装）实装 chat_stream
- [ ] 3.4 mock provider `providers/llm_mock.py` 实装 chat_stream：按时间窗口模拟 token yield（用于本地测试）；支持配置 first_token_ms / per_token_ms 参数
- [ ] 3.5 测试 `tests/test_provider_chat_stream.py`：每个 provider 覆盖正常流式 / 中途异常 / first token 之前 fail / vendor 不支持时 single_yield_fallback
- [ ] 3.6 测试 `tests/test_provider_errors.py` 同步加 chat_stream 路径的异常映射 case

## 4. isales-engine：sentence_splitter 模块

- [ ] 4.1 新建 `isales_engine/streaming/__init__.py` + `isales_engine/streaming/sentence_splitter.py`，实装 `async def split_sentences(token_stream: AsyncIterator[str]) -> AsyncIterator[str]`：累积 token 到 buffer，命中 `。？！` / `\n\n` / 50 字 cap 时 yield 一句；stream 结束时 flush buffer
- [ ] 4.2 测试 `tests/test_sentence_splitter.py`：中文标点切句 / 50 字 cap / stream 结束 flush / token 碎片化（"您"+"好"+"。"分 3 个 token）

## 5. isales-engine：referee 模块

- [ ] 5.1 新建 `isales_engine/referee.py`，实装 `async def run_referee(session, user_last_utterance, recent_dialog_history, referee_spec, llm) -> RefereeResult`：调 `llm.chat(json_mode=True, messages=...)`，输入 prompt 按 `role-prompt` spec § "referee prompt 内容规范" 渲染，输出 JSON 校验（decision 枚举 / goal_type / confidence 范围），fail-open 默认 `continue`
- [ ] 5.2 实装 `_render_dialog_history_for_referee(dialog_history) -> str`：渲染最近 ≤ 3 轮为 `用户：xxx\nAI：xxx` 多行；空 history 渲染占位 `（首轮对话，无历史）`（继承 5/29 archive engine-judge-dialog-context 的渲染规则）
- [ ] 5.3 测试 `tests/test_referee.py`：4 种 decision 枚举 + fail-open 路径（timeout / invalid JSON / low confidence） + 占位 history
- [ ] 5.4 `RefereeResult` 数据类放 `isales_engine/streaming/types.py` 或 `referee.py`，含 `decision / goal_type / confidence / duration_ms / raw_output`

## 6. isales-engine：orchestrator 重写

- [ ] 6.1 删除 `isales_engine/pipeline/orchestrator.py` 全部内容（旧三层逻辑）
- [ ] 6.2 重写 `orchestrator.py`，新签名 `async def run_pipeline_stream(session, user_input, config, main_llm, referee_llm, *, is_wrap_up, pipeline_timeout_ms) -> AsyncIterator[str], RefereeTask`：
  - 同时 spawn `main_task = asyncio.create_task(main_llm.chat_stream(...))` + `referee_task = asyncio.create_task(run_referee(...))`（is_wrap_up=True 时跳过 referee）
  - 返回 `(main_stream_iter, referee_task)`，调用方（run_loop）`async for sentence in split_sentences(main_stream_iter)` 喂 TTS，结束后 `await referee_task` 拿决策
- [ ] 6.3 删除 `isales_engine/pipeline/json_parser.py`（main LLM 不再 JSON 输出）；referee 的 JSON 校验放 `referee.py`
- [ ] 6.4 删除 `isales_engine/pipeline/prompt_builder.py` 中的 judge / polish 段；保留 main 段；新增 referee / extractor 段（或拆 `prompt_builder_referee.py` / `prompt_builder_extractor.py`，看代码组织）
- [ ] 6.5 重写 `tests/test_pipeline.py`：覆盖 main stream + referee 并行 / referee 早完 / referee 晚到 / main fallback 路径
- [ ] 6.6 删除 `tests/test_orchestrator_judge.py`（旧 judge 测试）等同类历史测试文件

## 7. isales-engine：run_loop PROCESSING → SPEAKING 流式重构

- [ ] 7.1 找 `isales_engine/run_loop.py` 当前 PROCESSING → SPEAKING 路径（约 line 364-631 的 `_main_turn_loop`）
- [ ] 7.2 改造为：
  - PROCESSING 入口同时 spawn main stream + referee task + （filler_enabled 时）filler task
  - `async for sentence in split_sentences(main_stream)` 立即 `await tts.synthesize_stream_chunk(sentence)` → `await rtc.audio_out(...)`
  - 首个 PCM chunk 推出时记录 `first_audio_ms`
  - main stream 中途异常 catch → 走 `main_llm.chat(...)` 非流式 fallback，一次性 TTS + log `main_fallback_used=true`
  - SPEAKING 状态结束（TTS 播完）→ `referee_result = await asyncio.wait_for(referee_task, 2.0)`
  - 根据 `referee_result.decision` 转 state：`goal_achieved → WRAPPING_UP / transfer → TRANSFERRING / customer_decline → ACTIVATING / continue → LISTENING`
- [ ] 7.3 删除 `await filler.wait_finished()` gate（filler 与 main TTS overlap，main TTS 首 chunk 到立即 preempt filler 通道）
- [ ] 7.4 filler 调用条件：`campaign.filler_enabled=True` 时才 spawn filler task（default false）
- [ ] 7.5 在 PROCESSING 完成时写 pipeline_trace 用新字段集（main_reply_text 由 split_sentences 输出聚合 + main_duration_ms + referee_* + first_audio_ms）
- [ ] 7.6 改 `run_loop.py:982` `status=session.state` 和别处 5 处 session.state 读取确认无回归
- [ ] 7.7 改 END 状态之前 LPUSH `isales:extract` 队列 + UPDATE `call_record.extract_status='pending'`，payload 按 `service-communication` spec § "isales:extract 队列消息 schema"
- [ ] 7.8 测试 `tests/test_run_loop.py` 全部改写：覆盖流式主路径 + filler 关闭模式 + filler 开启模式（preempt 验证）+ referee 不同 decision 驱动 state + main fallback 路径 + extract LPUSH 验证
- [ ] 7.9 测试 `tests/test_realtime_interruption.py` 同步更新（5/28 barge-in 路径仍然走 INTERRUPTED state，确认与新 streaming 路径兼容）

## 8. isales-engine：删除旧代码

- [ ] 8.1 grep `_call_roles_parallel / _run_judges_parallel / _call_polish` 删除所有实装 + 调用
- [ ] 8.2 grep `JUDGE_OUTPUT_SCHEMA_SUFFIX / POLISH_OUTPUT_SCHEMA_SUFFIX` 删除常量（5/28 commit 引入）
- [ ] 8.3 grep `_render_dialog_history_for_judge` 删除（5/29 archive engine-judge-dialog-context 引入）
- [ ] 8.4 删除 `tests/test_orchestrator_judge*.py` / `tests/test_polish*.py` 等历史测试
- [ ] 8.5 跑全量 `cd ~/codes/isales-engine && .venv/bin/python -m pytest -q` 确保无回归（应该 30+ 文件 100+ 测试全绿）
- [ ] 8.6 commit + push isales-engine feature branch

## 9. isales-worker：post_call_extractor consumer

- [ ] 9.1 升级 isales-common 依赖到 1.6 写的新版本
- [ ] 9.2 新建 `isales_worker/post_call_extractor.py`：BLPOP `isales:extract` 队列 → 调 LLM provider `chat(json_mode=True)` → UPDATE `call_record SET extracted = <result>, extract_status = 'done'`；失败 UPDATE `extract_status = 'failed', extract_error = <reason>`
- [ ] 9.3 在 `isales_worker/main.py`（或对应入口）启动 extractor consumer task
- [ ] 9.4 写 systemd unit `deploy/<linux|cloud>/systemd/isales-worker-extractor.service`（或集成进现有 isales-worker.service）
- [ ] 9.5 测试 `tests/test_post_call_extractor.py`：成功路径 / LLM 超时 / JSON 校验失败 / DB 写失败
- [ ] 9.6 commit + push isales-worker

## 10. isales-api：role_config + campaign API schema 更新

- [ ] 10.1 升级 isales-common 依赖到 1.6 版本
- [ ] 10.2 `isales_api/routers/role_configs.py` 改 kind 枚举允许值 `{main, referee, extractor}`；删除 judge / polish 创建路径
- [ ] 10.3 `isales_api/routers/campaigns.py` PATCH endpoint 加 `filler_enabled` 字段支持
- [ ] 10.4 `isales_api/schemas/campaign.py` Pydantic 响应 model 加 `filler_enabled` 字段
- [ ] 10.5 验证 admin API 接口契约：列出 role_configs 过滤 kind 用新枚举
- [ ] 10.6 测试 `tests/test_role_configs_api.py` / `tests/test_campaigns_api.py` 更新
- [ ] 10.7 commit + push isales-api

## 11. isales-web：UI 重构

- [ ] 11.1 升级 isales-api / isales-common 依赖（如有 npm 私服 / 直接拷贝 schema）
- [ ] 11.2 `src/views/CampaignEdit.vue` / `src/views/CampaignDetail.vue` 改 4-tier prompt 区为 3-tier：删除 judge / polish tab + tab content；新增 referee / extractor tab
- [ ] 11.3 main role prompt 编辑器右侧加提示卡片 "纯文本输出，不要 JSON / markdown / emoji"
- [ ] 11.4 referee role prompt 编辑器加 "插入推荐模板" 按钮（点击填入 referee prompt 模板）
- [ ] 11.5 extractor role prompt 编辑器加 "字段 schema 辅助生成"
- [ ] 11.6 campaign 详情页加 filler_enabled toggle + 提示 "streaming 主链路首音频 ~500ms，filler 仅在用慢模型时建议启用"；切到 false 时隐藏 filler_set / filler_phrase 编辑区
- [ ] 11.7 model 选择器 hover 显示 main/referee/extractor 推荐星级
- [ ] 11.8 调试视图 / pipeline_trace 查看页面字段集换新（删 role_candidates / judge_results / polish_*，加 main_reply_text / referee_decision / first_audio_ms 等）
- [ ] 11.9 跑 vitest 单元测试 + e2e（如有）确保无回归
- [ ] 11.10 commit + push isales-web

## 12. campaign 配置数据重建脚本

- [ ] 12.1 新建 `scripts/seed_pipeline_stream_campaign.py`：给现有 dev campaign 1 创建 main + referee + extractor 三个 role_config + 对应 prompt_version；prompt 内容用各 spec 推荐模板填充
- [ ] 12.2 在 mac dev 跑 seed 脚本 ECS 同步跑
- [ ] 12.3 ECS 上手工 verify `SELECT kind, model FROM role_config WHERE campaign_id=1` 含 main / referee / extractor 三行

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

- [ ] 16.1 更新 `deploy/RUNBOOK.md` 部署顺序段落（common → engine → worker → api → web）+ campaign 配置重建步骤
- [ ] 16.2 更新 `deploy/RUNBOOK-cloud.md` 同步
- [ ] 16.3 更新 `deploy/cloud/STATE.md` § "AI 三层管线" 段落改为 § "双 LLM 架构"
- [ ] 16.4 在 RUNBOOK 增加新章节 § "post-call extractor 排障"：如何查询 `extract_status='failed'` 通话 + 如何手工重跑 LPUSH

## 17. 历史 change housekeeping

- [ ] 17.1 在 `openspec/changes/archive/2026-05-29-engine-judge-dialog-context/proposal.md` 顶部加 HTML 注释 `<!-- SUPERSEDED-by: pipeline-stream-and-referee (judge layer removed, chat-history-into-judge thinking inherited to referee) -->`
- [ ] 17.2 在 `openspec/changes/archive/2026-05-08-impl-web-polish/proposal.md` 顶部加 `<!-- SUPERSEDED-by: pipeline-stream-and-referee (polish LLM layer removed) -->`
- [ ] 17.3 在 archive 其他相关 polish / judge 涉及的 changes 标 SUPERSEDED（grep `polish` / `judge` archive 目录确认全名单）

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
