# Tasks: engine-tts-bidi-streaming

> 实装落在 sub-repo（isales-common / isales-engine），进度回写本文件。每完成一项用 HTML 注释标注 PR#/commit/偏离。

## 0. 前置确认（实装前 ground-truth）

- [ ] 0.1 确认双向端点可用性仍成立：在 ECS 用 `ISALES_VOLC_FROM_DB=1 .venv/bin/python scripts/tts_bidi_probe.py`，moon/wvae 家族 PASS、xiaohe FAIL（零音频），记录 logid + 字节数。
- [ ] 0.2 确认 `volcengine_speech` 凭据含可用于 bidi 的 `tts_resource_id`（`volc.service_type.10029`）或确认按 speaker 家族推断；确认 moon/wvae 家族的**具体 speaker id**（shuangkuaisisi / M392 对应 vendor 字符串）。
- [ ] 0.3 确认 `isales-common` 是否已依赖 `websockets`（engine 已有），缺则加 pyproject 依赖。

## 1. isales-common：会话式双向流式 provider

- [ ] 1.1 在 `providers/tts.py`（ABC）新增会话式合成接口（session 对象：open / feed / audio iter / finish / close），保持 `synthesize_stream` 签名不变。
- [ ] 1.2 在 `providers/tts_volcengine.py`（或新 `tts_volcengine_bidi.py`）实装 V3 bidirection WS 协议：二进制帧编解码（参照 `scripts/tts_bidi_probe.py` 的 `_encode`/`_decode` + event 常量）、StartConnection→StartSession→TaskRequest×N→FinishSession、收 `AudioOnlyServer`/`TTSResponse` PCM。
- [ ] 1.3 bidi 路径按 speaker 家族选 `X-Api-Resource-Id`（moon/wvae → `volc.service_type.10029`），复用 `_resource_for` 模式；音色不兼容（零音频）时抛 provider 错误 fail-loud，不回落单向。
- [ ] 1.4 `MockTTSProvider`（`isales_common.providers.testing`）补会话式接口 mock 实现。
- [ ] 1.5 单测：会话式多句连续合成、中途 close 释放、音色不兼容 fail-loud；mock 路径覆盖。
- [ ] 1.6 bump `isales-common` 版本号；记录新版号。

## 2. isales-engine：主回复播放路径迁会话式

- [ ] 2.1 `run_loop.py`：`_play_streaming` 从「每句 `_SynthJob` 独立请求」改为「整轮 open 一个 TTS session、producer 对 `sentences()` 每句 feed、consumer 播 `session.audio()` 连续流」。
- [ ] 2.2 保留 `first_audio_ms` 锚点（`processing_start` 起算）+ 时间门控垫词逻辑不变。
- [ ] 2.3 barge-in / teardown：`session.close()` 替代 `_SynthJob.aclose()` 逐句取消；保留 `interrupt_remaining` 残句捕获（已 feed 未播出的句子）。
- [ ] 2.4 restructure 流式回复同样走会话式（多句）。
- [ ] 2.5 单片段路径（开场白 `_play_tts` / 垫词 / 默认回复 / listen_only 引导语）保持一次性 `synthesize_stream` 不变。
- [ ] 2.6 更新 `tests/test_play_streaming.py` / `test_providers.py` / `test_tts_cache.py`：会话式 producer/consumer、barge-in close、残句捕获。
- [ ] 2.7 pin 新版 `isales-common`。

## 3. 配置 / 音色迁移

- [ ] 3.1 生产 campaign `voice_id` 迁到 bidi-capable 的 moon/wvae 家族具体 speaker（按 0.2 结果）。
- [ ] 3.2 核对 `provider_credential` 的 bidi `tts_resource_id`；如需独立配置字段则评估（无 alembic 列变更优先按 speaker 家族推断）。

## 4. 测试 / 部署

- [ ] 4.1 `cd ../isales-engine && .venv/bin/python -m pytest -q` 全绿；`cd ../isales-common && .venv/bin/python -m pytest -q` 全绿。
- [ ] 4.2 `make test-all` 聚合绿（注意跳过 `?` 仓需先 bootstrap）。
- [ ] 4.3 scp engine + common 到 ECS，重启 engine；服务级 smoke（无异常日志、provider 构建成功）。
- [ ] 4.4 更新 `deploy/cloud/STATE.md`（如 alembic head / 服务状态变化）。

## 5. 验收（部分 deferred）

- [ ] 5.1 服务级验证：bidi session 在真 ECS 起得来、能合成、barge-in 能干净 close（脚本 / 日志）。
- [ ] 5.2 **真机听感对比 deferred 到 `pipeline-stream-realmachine-acceptance`**：长文本跨句连续性 vs 旧逐句起伏，用户耳朵确认 + 新音色（moon/wvae）可接受。

## 6. 收口

- [ ] 6.1 `openspec validate engine-tts-bidi-streaming --strict` 通过。
- [ ] 6.2 commit + push（meta + sub-repo）；更新相关 memory。
- [ ] 6.3 全 task 完成后 archive。
