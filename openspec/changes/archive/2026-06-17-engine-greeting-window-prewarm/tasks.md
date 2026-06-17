## 1. 现场核对(实装前 ground-truth)

<!-- c87e98c 全部 ground-truth 已核对,见各 task 注释 -->
- [x] 1.1 复读 `isales-engine` `run_loop.py` 开场白时序段(`_do_greeting` ≈ L205 → `_start_listen_pumps` ≈ L209)与 `_asr_pump` 音频消费起点,确认 ASR 建连与音频消费的解耦插桩点 <!-- 确认:ASR connect 发生在 `_asr_pump`(L458)首次推进 `stream_recognize` 生成器时;插桩=run_loop 侧把 pump 启动前移、monitor 后移 -->
- [x] 1.2 复读 `providers/asr_volcengine.py` 懒连点(`stream_recognize` 生成器 + `__aenter__` ≈ L354-355)与配置帧握手(≈ L361-387),确认"先连后喂"在 run_loop 侧编排可行、无需改 provider ABC <!-- 确认:`_stream_one_connection` 先 connect+config 再起 `_push_audio`;无需改 provider,run_loop 侧编排即可。偏离 D2:实采「开场白期喂真音频保活 + 开场白后 drain 结果」而非「门控音频路由」——更简且天然解决 vendor idle 断连,行为等价(开场白期语音不被消费) -->
- [x] 1.3 复读 `pipeline/greeting.py:38-39`(固定模板 return)+ `run_loop.py` `generate_greeting` 调用点(≈ L339,`providers.llm_for(config.pipeline.main)`),确认 main 槽 client 实例在开场白与 turn-1 间复用(同一 httpx client → 连接池共享) <!-- 确认:固定模板不调 LLM;LLM 模式 `chat` 与 turn-1 `chat_stream` 共享 `self._http`(llm_openai_compatible.py:73)→ 连接池复用 -->
- [x] 1.4 确认 `llm_registry.py:58-59` 默认 `provider=None` 短路返回 default client(裁判默认共享 main,无需单独预热);确认 pipeline_trace 字段 `main_first_token_ms` / `main_first_sentence_ms` / `first_audio_ms` 现存(`run_loop.py:1689-1690`) <!-- 确认:resolve(None)→default;trace 字段在 run_loop.py:1761-1762 写 JSONB,common read schema 未暴露 main_first_*(call.py:89 仅 first_audio_ms)→ 验收读 DB -->

## 2. ASR WebSocket 开场白窗口期并行建连(engine)

- [x] 2.1 在 run_loop 开场白阶段并行 kick off ASR WS 建连任务(fire-and-forget),使 connect + 配置帧握手与开场白播放重叠;音频消费 gate 到开场白结束(D2) <!-- c87e98c `_start_listen_pumps(start_monitors=False)` 在 `_do_greeting` 前启动 ASR+ev pump → 生成器推进触发 WS connect,与开场白并行 -->
- [x] 2.2 开场白播放完成后 drain 开场白期累积的入向缓冲帧(`inbound_q`),再开始正常 ASR 音频路由;严守"开场白不可打断 + 开场白期音频不喂 finalize"两不变量 <!-- c87e98c `_drain_greeting_era_asr` drain asr_finals_q/asr_partials_q + reset speech-start anchor;monitor 后移(`_start_monitors`)保开场白不可打断 -->
- [x] 2.3 预热建连失败 fail-soft:log + 回落到原懒连路径(turn-1 自行建连),不抛、不阻塞;加注释写明移除条件(D4) <!-- c87e98c ASR pump 既有 reconnect backoff 即懒连回落;`start_monitors=True` 原路径保留,任何 prewarm 调用方不传则行为不变 -->

## 3. main LLM 槽连接池预热(engine)

- [x] 3.1 固定模板开场白模式:开场白播放期间并行向 main 槽 client 发一次轻量预热请求(最轻形态 warm keep-alive 连接池,如极短 prompt + 最小 `max_tokens`),实现 Open Question「probe 最小有效形态」 <!-- c87e98c `_kick_main_llm_prewarm`:`chat([user:"hi"], max_tokens=1)` fire-and-forget,开场白后 `_reap_main_llm_prewarm` reap -->
- [x] 3.2 LLM 生成开场白模式:确认 `generate_greeting` 的 `chat` 已 warm 同一 main 槽连接池 → 不发冗余 probe(分支判定开场白模式) <!-- c87e98c `if not config.fixed_greeting: return None`(LLM 开场白自带 warm) -->
- [x] 3.3 预热请求失败 fail-soft:log + 回落,不影响 turn-1 正常 `chat_stream`;注释写明移除条件 <!-- c87e98c probe 内 try/except 吞错 + reap 用 contextlib.suppress;注释写明移除触发=未来跨通话连接池 -->

## 4. 测试(engine 单测)

- [x] 4.1 ASR 提前建连测试:断言开场白窗口期已发起 connect、且开场白期入向音频未喂入 finalize;开场白结束后 drain + 正常消费 <!-- c87e98c test_start_without_monitors_runs_asr_but_not_monitors + test_start_monitors_attaches_and_is_idempotent + test_drain_greeting_era_asr_clears_queues_and_anchor -->
- [x] 4.2 main 预热测试:固定模板模式发一次轻量 probe;LLM 模式不发冗余 probe <!-- c87e98c test_prewarm_fires_chat_for_fixed_greeting + test_no_prewarm_probe_for_llm_greeting -->
- [x] 4.3 fail-soft 测试:ASR 建连 / main probe 抛错时通话不中断、回落原路径、对外行为不变 <!-- c87e98c test_prewarm_failure_is_failsoft -->
- [x] 4.4 跑 `cd ../isales-engine && .venv/bin/python -m pytest -q`(甄别既有 pre-existing 失败:engine gating 时序),确认本 change 测试全绿 <!-- c87e98c 476 passed / 1 failed;唯一失败 test_gate_fails_open_to_main_on_referee_timeout 为 pre-existing(baseline stash 验证 3/3 红);修了 1 个被本 change 行为改变影响的 wall-clock 测试(test_speaking_interruption 喂 turn-1 改到开场白播完后) -->

<!-- ⚠️ 工程现场提示:engine 工作区有上个 session 遗留的未提交在途改动 `engine-wrap-up-bypass-referee`(llm_mock.py / runtime_config.py / wrapup/manager.py / test_run_loop.py + run_loop.py 内 _gated_wrap_up_turn 段),与本 change 无关。c87e98c 用 patch 精确只 stage 本 change 的 hunk,遗留改动原样保留在工作区未动。 -->


## 5. 部署与验收

- [x] 5.1 scp 部署 engine `run_loop.py`(及相关改动文件)到 ECS + `systemctl restart`(纯 engine,无 alembic / common 版本联动);部署后查 STATE.md 一致性 <!-- 2026-06-17 16:46 部署 committed c87e98c 版(非工作区,避开遗留 wrap-up-bypass);部署前 md5 89cb2a21==base d3c6c9e、部署后 430dd5c7;engine active + grpc_server_started + credentials_loaded count=6 + isales_engine_started 无 traceback;备份 /opt/isales/backups/run_loop.py.bak-20260617-prewarm;STATE.md 已更新 -->
- [ ] 5.2 真机拨测:对比同一通电话 turn-1 vs turn-2 的 `main_first_token_ms` / `first_audio_ms`(读 DB,api 未暴露这些字段),断言差距显著收窄、ASR 首 finalize 不再含 WS 建连握手 —— **可挂 `pipeline-stream-realmachine-acceptance` deferred** <!-- DEFERRED 到 pipeline-stream-realmachine-acceptance(沿用 wrap-up-silence-hangup §6.2 先例;archive 不阻塞) -->
- [ ] 5.3 验证 Open Question:开场白时长是否短于 ASR vendor idle 断连阈值;若证伪则按 D2 加保活占位帧(标记不参与 finalize) <!-- DEFERRED:随 5.2 真机一并验;证伪才补保活帧 -->

## 6. 收口

- [x] 6.1 `openspec validate engine-greeting-window-prewarm --strict` 通过 <!-- valid -->
- [x] 6.2 tasks.md 用 HTML 注释回写每个 task 的 commit / PR# / 偏离说明;commit + push(meta-repo + engine sub-repo) <!-- engine c87e98c push origin/main;meta ee1adce push origin/main -->
- [x] 6.3 全 task 完成 → `/opsx:archive engine-greeting-window-prewarm`(delta 合并进 `openspec/specs/ai-pipeline/spec.md`) <!-- 真机验收(5.2/5.3)deferred,沿用先例 archive;见 archive commit -->

<!-- 真机验收 5.2/5.3 deferred 到 pipeline-stream-realmachine-acceptance(用户确认 archive-with-real-machine-deferred);其余 §1-6 全部完成。 -->
