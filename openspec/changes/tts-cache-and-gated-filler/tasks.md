## 1. isales-common：campaign.filler_delay_ms（B 配套）

- [ ] 1.1 `models/campaign.py` 新增 `filler_delay_ms: Mapped[int | None]`（INT, nullable, 注释默认 600）
- [ ] 1.2 `schemas/campaign.py` CampaignBase + CampaignUpdate 加 `filler_delay_ms: int | None = None`
- [ ] 1.3 alembic migration（additive 一列）`campaign.filler_delay_ms INT`；downgrade DROP
- [ ] 1.4 bump isales-common 版本 + CHANGELOG
- [ ] 1.5 跑 isales-common pytest（CampaignRead ORM round-trip 设 filler_delay_ms）

## 2. isales-engine：A —— TTS 固定话术缓存

- [ ] 2.1 新增 `providers/tts_cache.py`：`TtsCacheStore`（进程级有界 LRU, key=(text,voice_id)→list[bytes], max_entries/max_total_bytes）+ `CachingTTSProvider(inner, store, max_cacheable_chars=60)`
- [ ] 2.2 `synthesize_stream`：命中重放；未命中且 len(text)≤阈值 → 透传+累积+完整成功后 put；超阈值 → 直透传不缓存；`aclose()` 透传 inner
- [ ] 2.3 `main.py`：进程级建一个 `TtsCacheStore`；per-call `build_tts(...)` 外包 `CachingTTSProvider(inner, store)`（aclose 链路保留）
- [ ] 2.4 测试 `tests/test_tts_cache.py`：命中零调用 inner（spy inner 调用计数）；未命中填充；超长不缓存；打断/异常不污染；LRU 淘汰；aclose 透传

## 3. isales-engine：B —— 时间门控垫词

- [ ] 3.1 `run_loop`：移除 PROCESSING 入口的无条件 `filler.start()`；改为把 filler + `filler_delay_ms` 传进 `_play_streaming`
- [ ] 3.2 `_play_streaming`：起 `_maybe_filler` 计时器（sleep filler_delay_s → 若 first_audio_ms is None 则 filler.start()）；消费第一个 job 前 cancel 计时器 + filler.stop()；打断/finally 清理计时器
- [ ] 3.3 `runtime_config`：读 `campaign.filler_delay_ms`（NULL→600）→ RuntimeConfig 加字段 → 透传
- [ ] 3.4 测试 `tests/test_play_streaming.py`：快轮次(first audio < delay)不播垫词；慢轮次(delay 到时无音频)播垫词；垫词在首句就绪时停；filler_enabled=false 不起计时器

## 4. isales-engine：回归 + commit

- [ ] 4.1 全量 `pytest -q` 无回归；ruff + mypy 改的文件
- [ ] 4.2 commit + push isales-engine（branch fix/inbound-stereo-downmix-20260601）

## 5. isales-api / isales-web：filler_delay_ms 配置入口

- [ ] 5.1 isales-api：升级 common pin；CampaignNestedUpdate 加 `filler_delay_ms`；测试
- [ ] 5.2 isales-web：types Campaign + CAMPAIGN_DEFAULTS 加 `filler_delay_ms`；filler 配置页加输入 + 提示"首音频超此时长才播垫词，留空默认 600ms"；vitest
- [ ] 5.3 commit + push isales-api + isales-web

## 6. ECS 部署

- [ ] 6.1 common → engine → api → web scp editable + alembic upgrade（additive 列）
- [ ] 6.2 restart 服务 + log clean
- [ ] 6.3 更新 deploy/cloud/STATE.md（TTS 缓存 + 门控垫词 + filler_delay_ms）

## 7. mac dev 真通话验收

- [ ] 7.1 第二通开场白：确认首声接近零（缓存命中，ECS 日志无 `volcengine_tts_first_byte` for greeting 第二通 / 或 cache_hit 日志）
- [ ] 7.2 慢轮次：确认垫词只在首音频 >600ms 时出现，且垫词无合成延迟（命中缓存）
- [ ] 7.3 快轮次：确认不播垫词

## 8. 验证 + archive

- [ ] 8.1 `openspec validate tts-cache-and-gated-filler --strict` 通过
- [ ] 8.2 `/opsx:archive tts-cache-and-gated-filler`
- [ ] 8.3 archive commit + push meta-repo
