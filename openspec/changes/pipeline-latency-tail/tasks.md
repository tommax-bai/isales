## 1. isales-common：campaign.asr_eos_silence_ms（A 配套）

- [ ] 1.1 `isales_common/models/campaign.py` 新增 `asr_eos_silence_ms: Mapped[int | None]`（INT, nullable, 注释默认语义 400）
- [ ] 1.2 `isales_common/schemas/campaign.py` CampaignBase 加 `asr_eos_silence_ms: int | None = None`（→ Create/Read 自动覆盖）
- [ ] 1.3 alembic migration（additive 一列）：`ALTER TABLE campaign ADD COLUMN asr_eos_silence_ms INT`；downgrade DROP
- [ ] 1.4 bump isales-common 版本 + CHANGELOG
- [ ] 1.5 跑 isales-common pytest（含 CampaignRead ORM round-trip 设 asr_eos_silence_ms）

## 2. isales-engine：C —— TTS 连接复用

- [ ] 2.1 `providers/tts_volcengine.py`：`__init__` 建持久 `self._client = httpx.AsyncClient(timeout=..., limits=httpx.Limits(keepalive...))`；`synthesize_stream` 用 `self._client.stream(...)` 替换每句新建
- [ ] 2.2 新增 `async def aclose()` 释放 client；factory / main 在进程退出时调用（或注册 shutdown）
- [ ] 2.3 半开连接 / vendor 断连容错：保留现有 ProviderError 重试一层；失败重连不改调用方语义
- [ ] 2.4 测试 `tests/test_tts_volcengine.py`：复用同一 client 跨多次 synthesize_stream（mock transport 注入）；aclose 释放；既存 5 个 tts_volcengine fail 顺带评估是否本 change 一并修（`endpoint` kwarg 构造不符）

## 3. isales-engine：A —— ASR 端点参数化

- [ ] 3.1 `providers/asr_volcengine.py`：`_PARTIAL_STABLE_S` 写死 0.7 → 构造参数 `partial_stable_s`，默认 0.4
- [ ] 3.2 `providers/factory.py` build_asr 接受可选 `partial_stable_s` override
- [ ] 3.3 `runtime_config.py`：读 `campaign.asr_eos_silence_ms`（NULL→400）→ 透传到 ASR provider 构造（RuntimeConfig 加字段 + main.py build_asr 时注入，或 RuntimeConfig 携带）
- [ ] 3.4 测试 `tests/test_asr_volcengine.py`（如有）/ 新测：partial_stable_s 可配；默认 0.4

## 4. isales-engine：B —— producer/consumer + 预合成（核心）

- [ ] 4.1 重写 `run_loop._play_streaming`：producer task（`chat_stream → split_sentences` → 每句立即发起 `tts.synthesize_stream` → 塞有界 `asyncio.Queue(maxsize=2)`）+ consumer（取就绪句柄 → audio_out 播放）
- [ ] 4.2 `first_audio_ms` 记录点移到 consumer 播放第一句首 PCM chunk（语义不变）
- [ ] 4.3 main_reply_text 聚合：producer 侧累积切出的句子文本（供 pipeline_trace）
- [ ] 4.4 barge-in 三态处理：打断 → cancel consumer 当前播放 + cancel producer + drain 队列关闭未播 TTS iterator；`current_speaking_task` 仍指向当前播放 task（partial_monitor cancel 路径不变）
- [ ] 4.5 异常传播：producer 中途异常（main_stream fail → orchestrator 已有 chat() fallback；TTS 合成异常）→ consumer 不卡死 + 落 error；filler preempt 仍生效（filler_enabled 时）
- [ ] 4.6 测试 `tests/test_run_loop.py`：流式主路径 + 句间无空档（mock TTS 计时）+ 三态打断 + 异常注入（producer/consumer/TTS 各抛一次）+ first_audio_ms 记录
- [ ] 4.7 测试 `tests/test_realtime_interruption.py` 同步：打断点落在预合成中 / 播放中 / 队列等待中

## 5. isales-engine：D —— transfer LLM 移出主链路

- [ ] 5.1 `transfer/manager.py`：拆 `evaluate_transfer` → `evaluate_transfer_cheap`（keyword/round，零 LLM，inline）+ LLM 检测分离
- [ ] 5.2 `run_loop`：PROCESSING 前只调 cheap 检测；intent/llm 检测删除 inline 调用，复用 referee 的 `transfer` decision
- [ ] 5.3 过渡兼容：campaign 显式 `transfer_llm_enabled` 且 referee 未覆盖 → 与 main streaming 并行 spawn（同 referee），结果在 SPEAKING 结束前 await
- [ ] 5.4 测试 `tests/test_transfer*.py`：cheap 检测 inline 不调 LLM；referee transfer 驱动 TRANSFERRING；显式 transfer_llm 并行不阻塞

## 6. isales-engine：回归 + commit

- [ ] 6.1 全量 `cd ~/codes/isales-engine && .venv/bin/python -m pytest -q`（确认无新增回归；既存 tts_volcengine 5 fail 状态记录）
- [ ] 6.2 ruff + mypy 我改的文件
- [ ] 6.3 commit + push isales-engine（feature 分支 fix/inbound-stereo-downmix-20260601）

## 7. isales-api / isales-web：asr_eos_silence_ms 配置入口

- [ ] 7.1 isales-api：升级 common pin；CampaignNestedUpdate 加 `asr_eos_silence_ms`（PATCH）；测试
- [ ] 7.2 isales-web：types Campaign 加 `asr_eos_silence_ms`；Campaign 配置页加输入 + 提示"太短会把停顿误判成说完打断客户"；vitest
- [ ] 7.3 commit + push isales-api + isales-web

## 8. ECS 部署

- [ ] 8.1 common → engine → api → web rsync editable + alembic upgrade（additive 列）
- [ ] 8.2 restart 服务 + log clean
- [ ] 8.3 更新 deploy/cloud/STATE.md（连接复用 / 端点默认 0.4 / producer-consumer）

## 9. mac dev 真通话验收

- [ ] 9.1 mac dev 跑真通话：量 EOS→首音频（ECS 日志 partial_stable→first tts_first_byte）+ 句间空档（连续 tts_first_byte 间隔 vs 音频时长）
- [ ] 9.2 对照基线（本次诊断 call_record 137：EOS 0.7s + 句间 250-500ms 空档）确认改善
- [ ] 9.3 验证 barge-in 不回归（5/28 路径）+ 端点 0.4 不频繁误打断
- [ ] 9.4 校准 Q1（maxsize 2/3）/ Q2（eos 350/400/500）/ Q3（transfer 复用 vs 并行）三档

## 10. 验证 + archive

- [ ] 10.1 `openspec validate pipeline-latency-tail --strict` 通过
- [ ] 10.2 `/opsx:archive pipeline-latency-tail`
- [ ] 10.3 archive commit + push meta-repo
