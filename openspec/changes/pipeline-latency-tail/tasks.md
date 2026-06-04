## 1. isales-common：campaign.asr_eos_silence_ms（A 配套）

- [x] 1.1 `isales_common/models/campaign.py` 新增 `asr_eos_silence_ms: Mapped[int | None]`（INT, nullable, 注释默认语义 400） <!-- isales-common: Campaign model col -->
- [x] 1.2 `isales_common/schemas/campaign.py` CampaignBase 加 `asr_eos_silence_ms: int | None = None`（→ Create/Read 自动覆盖） <!-- + CampaignUpdate patch field -->
- [x] 1.3 alembic migration（additive 一列）：`ALTER TABLE campaign ADD COLUMN asr_eos_silence_ms INT`；downgrade DROP <!-- d4e5f6a7b8c9, revises c3d4e5f6a7b8 -->
- [x] 1.4 bump isales-common 版本 + CHANGELOG <!-- 0.5.0 → 0.5.1 -->
- [x] 1.5 跑 isales-common pytest（含 CampaignRead ORM round-trip 设 asr_eos_silence_ms） <!-- 158 passed; test_read_from_orm asserts asr_eos_silence_ms==250 -->>

## 2. isales-engine：C —— TTS 连接复用

- [x] 2.1 `providers/tts_volcengine.py`：`__init__` 建持久 `self._client = httpx.AsyncClient(timeout=..., limits=httpx.Limits(keepalive...))`；`synthesize_stream` 用 `self._client.stream(...)` 替换每句新建 <!-- max_keepalive=4, keepalive_expiry=60 -->
- [x] 2.2 新增 `async def aclose()` 释放 client；factory / main 在进程退出时调用（或注册 shutdown） <!-- providers per-call; main.py _run finally aclose tts (per-call 弃用点) -->
- [x] 2.3 半开连接 / vendor 断连容错：保留现有 ProviderError 重试一层；失败重连不改调用方语义 <!-- synthesize_stream retry-once loop unchanged; httpx pool auto-reconnects half-open -->
- [x] 2.4 测试 `tests/test_tts_volcengine.py`：复用同一 client 跨多次 synthesize_stream（mock transport 注入）；aclose 释放；既存 5 个 tts_volcengine fail 顺带评估是否本 change 一并修（`endpoint` kwarg 构造不符） <!-- rewrote file V1→V3 SSE (legacy 5 monkeypatched synthesize_stream, never tested real provider); 10 passed incl reuse + aclose -->>

## 3. isales-engine：A —— ASR 端点参数化

- [x] 3.1 `providers/asr_volcengine.py`：`_PARTIAL_STABLE_S` 写死 0.7 → 构造参数 `partial_stable_s`，默认 0.4 <!-- DEFAULT_PARTIAL_STABLE_S=0.4; monitor reads self._partial_stable_s -->
- [x] 3.2 `providers/factory.py` build_asr 接受可选 `partial_stable_s` override <!-- None → provider default; passed to both api_key + legacy paths -->
- [x] 3.3 `runtime_config.py`：读 `campaign.asr_eos_silence_ms`（NULL→400）→ 透传到 ASR provider 构造（RuntimeConfig 加字段 + main.py build_asr 时注入，或 RuntimeConfig 携带） <!-- RuntimeConfig.asr_partial_stable_s (ms/1000, NULL→0.4); main.py _run passes to build_asr -->
- [x] 3.4 测试 `tests/test_asr_volcengine.py`（如有）/ 新测：partial_stable_s 可配；默认 0.4 <!-- test_providers.py::test_asr_partial_stable_s_default_and_override -->>

## 4. isales-engine：B —— producer/consumer + 预合成（核心）

- [x] 4.1 重写 `run_loop._play_streaming`：producer task（`chat_stream → split_sentences` → 每句立即发起 `tts.synthesize_stream` → 塞有界 `asyncio.Queue(maxsize=2)`）+ consumer（取就绪句柄 → audio_out 播放） <!-- _SynthJob pre-synth into per-job buffer; _play_chunks shared by _play_tts -->
- [x] 4.2 `first_audio_ms` 记录点移到 consumer 播放第一句首 PCM chunk（语义不变） <!-- _marked() wrapper stamps on first yielded chunk -->
- [x] 4.3 main_reply_text 聚合：producer 侧累积切出的句子文本（供 pipeline_trace） <!-- sentences() accumulates result.reply_text as producer consumes it -->
- [x] 4.4 barge-in 三态处理：打断 → cancel consumer 当前播放 + cancel producer + drain 队列关闭未播 TTS iterator；`current_speaking_task` 仍指向当前播放 task（partial_monitor cancel 路径不变） <!-- finally: cancel producer + sentences.aclose + current_job.aclose + drain queue; _SynthJob.aclose explicitly closes TTS gen (deferred-finalization fix) -->
- [x] 4.5 异常传播：producer 中途异常（main_stream fail → orchestrator 已有 chat() fallback；TTS 合成异常）→ consumer 不卡死 + 落 error；filler preempt 仍生效（filler_enabled 时） <!-- producer catches+sentinels; consumer catches synth error → stream.result.error + break (not interruption); filler stopped on first job -->
- [x] 4.6 测试 `tests/test_run_loop.py`：流式主路径 + 句间无空档（mock TTS 计时）+ 三态打断 + 异常注入（producer/consumer/TTS 各抛一次）+ first_audio_ms 记录 <!-- new tests/test_play_streaming.py: order + pre-synth + 2 barge-in states + tts-synth-error + producer-stream-error + first_audio_ms (6 tests) -->
- [x] 4.7 测试 `tests/test_realtime_interruption.py` 同步：打断点落在预合成中 / 播放中 / 队列等待中 <!-- test_partial_monitor_cancels_play_streaming_midflight: real _partial_monitor drives barge-in vs _play_streaming, asserts no leaked pre-synth -->>

## 5. isales-engine：D —— transfer LLM 移出主链路

- [x] 5.1 `transfer/manager.py`：拆 `evaluate_transfer` → `evaluate_transfer_cheap`（keyword/round，零 LLM，inline）+ LLM 检测分离 <!-- evaluate_transfer_cheap (sync, no llm arg) + evaluate_transfer_llm (intent/llm); evaluate_transfer kept as composition for tests -->
- [x] 5.2 `run_loop`：PROCESSING 前只调 cheap 检测；intent/llm 检测删除 inline 调用，复用 referee 的 `transfer` decision <!-- pre-PROCESSING = evaluate_transfer_cheap only; referee transfer → _perform_handoff (unified helper, 3 call sites deduped) -->
- [x] 5.3 过渡兼容：campaign 显式 `transfer_llm_enabled` 且 referee 未覆盖 → 与 main streaming 并行 spawn（同 referee），结果在 SPEAKING 结束前 await <!-- transfer_llm_task spawned at PROCESSING entry; _resolve_transfer_llm (2s fail-open) after referee; guarded by `not referee_transfer`; cancelled on barge-in -->
- [x] 5.4 测试 `tests/test_transfer*.py`：cheap 检测 inline 不调 LLM；referee transfer 驱动 TRANSFERRING；显式 transfer_llm 并行不阻塞 <!-- test_transfer_and_wrapup: cheap-no-llm / cheap kw+round / llm-only-triggers; test_run_loop: transfer_llm_parallel_marks_handoff asserts pipeline ran + reason=llm -->>

## 6. isales-engine：回归 + commit

- [x] 6.1 全量 `cd ~/codes/isales-engine && .venv/bin/python -m pytest -q`（确认无新增回归；既存 tts_volcengine 5 fail 状态记录） <!-- 312 passed; the 5 tts_volcengine fails are FIXED (V1→V3 rewrite), no remaining fails -->
- [x] 6.2 ruff + mypy 我改的文件 <!-- ruff clean on my files; mypy clean (only pre-existing asr_volcengine ConnectionClosed name-defined remains, confirmed via stash) -->
- [x] 6.3 commit + push isales-engine（feature 分支 fix/inbound-stereo-downmix-20260601） <!-- engine 0e8762e pushed; common 063892c (0.5.1) pushed to main -->>

## 7. isales-api / isales-web：asr_eos_silence_ms 配置入口

- [x] 7.1 isales-api：升级 common pin；CampaignNestedUpdate 加 `asr_eos_silence_ms`（PATCH）；测试 <!-- pin →0.5.1; CampaignNestedUpdate field; test_asr_eos_silence_ms_create_default_and_patch (9 campaign tests pass) -->
- [x] 7.2 isales-web：types Campaign 加 `asr_eos_silence_ms`；Campaign 配置页加输入 + 提示"太短会把停顿误判成说完打断客户"；vitest <!-- campaign.ts + CAMPAIGN_DEFAULTS; InterruptionTab 「ASR 端点静默 (ms)」 + warning hint; campaignTabs.test.ts InterruptionTab block (5 pass) + vue-tsc clean -->
- [x] 7.3 commit + push isales-api + isales-web <!-- api 76b1709, web c0ac69b both pushed to main -->>

## 8. ECS 部署

- [x] 8.1 common → engine → api → web rsync editable + alembic upgrade（additive 列） <!-- scp 源码; alembic c3d4e5f6a7b8→d4e5f6a7b8c9; column verified nullable int; web rebuild rsync→/var/www/isales-web -->
- [x] 8.2 restart 服务 + log clean <!-- 4 python svc restart; engine credentials_loaded count=5 + isales_engine_started clean; api startup complete + /campaigns 401 + openapi has field; SPA 200 -->
- [x] 8.3 更新 deploy/cloud/STATE.md（连接复用 / 端点默认 0.4 / producer-consumer） <!-- prepended 2026-06-04 11:50 CST entry -->>

## 9. mac dev 真通话验收

- [ ] 9.1 mac dev 跑真通话：量 EOS→首音频（ECS 日志 partial_stable→first tts_first_byte）+ 句间空档（连续 tts_first_byte 间隔 vs 音频时长）
- [ ] 9.2 对照基线（本次诊断 call_record 137：EOS 0.7s + 句间 250-500ms 空档）确认改善
- [ ] 9.3 验证 barge-in 不回归（5/28 路径）+ 端点 0.4 不频繁误打断
- [ ] 9.4 校准 Q1（maxsize 2/3）/ Q2（eos 350/400/500）/ Q3（transfer 复用 vs 并行）三档

## 10. 验证 + archive

- [x] 10.1 `openspec validate pipeline-latency-tail --strict` 通过 <!-- valid -->>
- [ ] 10.2 `/opsx:archive pipeline-latency-tail`
- [ ] 10.3 archive commit + push meta-repo
