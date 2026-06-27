# Tasks — engine-ambient-background-mix

实装前先读 `proposal.md` + `design.md`；落点跨 isales-engine（主）/ isales-common / isales-api / isales-web。
实装中代码改动落在对应 sub-repo，本文件进度回写在 meta-repo。
每完成一个 task 用 HTML 注释 `<!-- commit-sha 备注 -->` 标 `[x]` 并写 PR#/commit/偏离说明。

## 1. isales-common — campaign 配置列（加性迁移）

- [x] 1.1 `campaign` 模型加 `ambient_audio`（str，默认空/NULL=关闭）+ `ambient_gain`（float，默认低电平 ~-20dB 量级）两列 <!-- common dd2c359 -->
- [x] 1.2 campaign Pydantic schema（Create/Read/Update）暴露两字段 <!-- common dd2c359。偏离：dial 消息 NOT 携带——引擎从 campaign 行经 load_runtime_config 读取（与 filler_phrases/interruption_min_chars 同路径），dial schema 不需改 -->
- [x] 1.3 alembic 加性迁移 a2c4e6b8d0f2（Revises d1e2f3a4b5c6，确认单 head 不撞），server_default 0.1 backfill，存量 campaign ambient_audio NULL=关闭；downgrade 删两列 <!-- common dd2c359 -->
- [x] 1.4 bump isales-common 0.8.17→0.8.18（消费者 pin 为 `>=,<0.9` 区间，无需改） <!-- common dd2c359 -->

## 2. isales-engine — 背景音素材加载

- [x] 2.1 背景音素材（WAV）解码为 16kHz mono int16 预载内存，全局缓存（AmbientLoop 不可变共享）；非目标格式经 audioop 转换（缺 audioop 时 log+skip） <!-- engine ecf9e34 realtime/ambient.py _load/get_ambient_loop -->
- [x] 2.2 环形读取器 AmbientReader（per-call 读指针）loop；`_make_seamless` 在加载时一次性 tail→head 交叉淡入淡出，读侧线性 wrap 无爆音 <!-- engine ecf9e34 -->
- [x] 2.3 `ambient_audio` 空/缺失/不可读 → 不启泵，走原直推路径（等价现状）；素材标识=资产目录下 basename（拒绝路径穿越） <!-- engine ecf9e34 -->

## 3. isales-engine — 出向常驻混音泵（核心）

- [x] 3.1 `_CallState` 加 `playout_q`（maxsize=300 背压）+ `outbound_pump` + `ambient_reader` + `ambient_gain` <!-- engine ecf9e34 -->
- [x] 3.2 `_outbound_loop` 协程：单调墙钟绝对调度（target=start+idx·10ms，落后即追、不累积漂移），每 10ms 一帧 = `mix_frame(tts, bg, gain)`（pure-array int16 + clip） <!-- engine ecf9e34。偏离：泵复用现有 push_audio 单帧推送（单 320B 帧不触发其内部 sleep），不新增 binding 方法 -->
- [x] 3.3 泵在 `enable_ambient`（connect 后、greeting 前）启动、`close_iterators` 里 `stop_outbound_pump` 取消；`_pump_ts` 连续 +10 <!-- engine ecf9e34 -->
- [x] 3.4 `audio_out()` ambient 开启时走 `feed_playout`（切 10ms + 短帧补零写 playout_q，await q.join() 保「播放完成」语义），关闭时走原直推 <!-- engine ecf9e34。偏离：双模式由 config 选择（非 fallback），默认关闭路径字节级不变以降风险；移除触发=真机验证泵稳定后考虑统一为单路径 -->
- [x] 3.5 逐样本混音 pure-array（不依赖 audioop/numpy）——audioop 在 Py3.13+ 已移除，纯 array 单路径可在任意 Python 测试 <!-- engine ecf9e34 -->
- [x] 3.6 出向 jitter cushion（集成期 follow-up）：泵 10ms 严格节拍 + 空队列塞静音，混音前 direct-push 靠 RTC SDK jitter buffer 抹平 vendor 抖动/慢供帧，泵路径无此层 → TTS 瞬时欠载被打成语音静音空洞 = 对话「生硬/卡顿」（一轮第一句最重；开场白整段先缓冲故不受影响）。`feed_playout` 先攒满 `PLAYOUT_PREBUFFER_FRAMES`(=20,200ms) 再放给泵；已 pre-synth 句子 cushion 瞬填≈0 延迟，慢 vendor 最多付 200ms；流结束 flush cushion 防短句死锁。+2 测（保序完整 + 短句仍播），engine 21 ambient 测通过 <!-- engine 部署 scp+restart active；commit 见 isales-engine HEAD; 真机听感验收并入 §7.3/7.4 -->

## 4. isales-engine — 打断路径

- [x] 4.1 `feed_playout` 收到 CancelledError（barge-in）→ `_flush_playout` 清空 playout_q 使语音立即停；泵继续推背景音 → 打断后不死寂；`current_speaking_task` 取消保留 <!-- engine ecf9e34 -->

## 5. isales-api / isales-web — 配置入口

- [x] 5.1 isales-api：CampaignNestedCreate 继承 common（自动得字段），CampaignNestedUpdate 显式声明二字段（否则 PATCH 丢字段）；update 经 model_dump(exclude_unset)+setattr 通用透传 <!-- api 160f6fa -->
- [x] 5.2 isales-web：新增 AmbientAudioTab，插在 FillerEditor 后；CampaignBase + CAMPAIGN_DEFAULTS 加字段，经 buildPayload 白名单提交；默认关闭、回显、hint 提示回声风险 <!-- web d0cf6c7 -->
  - [x] 5.2a 改进：填文件名 → **启用开关 + 场景下拉**（AMBIENT_PRESETS：安静室内/办公室/呼叫中心），关→ambient_audio=null；自定义素材（不在 catalog）仍作额外项不丢 <!-- web 28c7681 -->

## 6. 测试

- [x] 6.1 engine 单测：泵配速实时性（0.2s≈20 帧，10–30 容差，无 runaway/stall） <!-- engine ecf9e34 test_pump_pacing_is_realtime -->
- [x] 6.2 engine 单测：playout_q 空→只推背景音；非空→混音；clip 正负溢出；gain≤0/空 bg passthrough <!-- engine ecf9e34 test_pump_*/test_mix_* -->
- [x] 6.3 engine 单测：barge-in flush playout_q 后泵仍推背景音帧 <!-- engine ecf9e34 test_barge_in_flush_keeps_background -->
- [x] 6.4 engine 单测：loop 320B 帧 + wrap 连续 + 接缝无大跳变 <!-- engine ecf9e34 test_reader_*/test_seamless_no_large_seam_jump -->
- [x] 6.5 隔离性断言：启泵+推背景音后 inbound_q/vad_q 仍为空（入向零污染） <!-- engine ecf9e34 test_ambient_never_touches_inbound -->
- [x] 6.6 engine 455 passed（+19 新）/api 21 campaign passed/web 90 passed/common 校验通过；`openspec validate --strict` 通过。两处 pre-existing fail（engine gate timeout / api redis-steal）已 stash 甄别与本变更无关 <!-- 见各仓测试输出 -->

## 7. 部署 + 真机验收（真机回声门 WAIVED 2026-06-27 — 用户批准归档）

> 原计划把真机验收并入 `pipeline-stream-realmachine-acceptance`，但该聚合 tracker 已于
> 2026-06-27 撤回（superseded：逐 change 在 STATE.md 各自冒烟取代了汇总表）。工程侧已 100%
> 完成并于 2026-06-16 全栈部署上云；背景音为 opt-in（无 campaign 启用即零影响）。§7.2-7.4 的
> 真机回声/听感门 WAIVE，不阻塞归档——真正启用前应先在白名单 campaign 跑一次 §7.3 回声实测，
> 必要时下调 `ambient_gain` 或换无人声素材。

- [x] 7.1 全栈部署 ECS：common scp+`alembic upgrade head`（d1e2f3a4b5c6→a2c4e6b8d0f2，两列已建实证）/ engine 5 文件（部署前 md5==main base 00b4c48 防覆盖分支）+重启 active / api schemas.py+重启 / web rebuild+scp+nginx reload（http200）/ 示例素材 `/opt/isales/ambient/office.wav`（16k mono RMS≈5000）+引擎内 get_ambient_loop 实证可加载。STATE.md 已更新 <!-- 见 deploy/cloud/STATE.md 2026-06-16 16:37 条 -->
  - 偏离：素材目录用引擎默认 `/opt/isales/ambient`（未设 ISALES_AMBIENT_DIR）；office.wav 是合成占位底噪，建议换真实办公室录音
- [ ] 7.2 白名单 campaign 配 `ambient_audio` + 低电平 `ambient_gain`
- [ ] 7.3 **真机回声实测**：开背景音后真人 mic 通话，确认入向 ASR 无持续 partial / 误 finalize / 误触发 barge-in；客户侧持续听到背景音；TTS 无变调/卡顿。回声超标 → 下调电平或换无人声素材。**无此验收不视为完成**
- [ ] 7.4 真机听感：句间空档与静默期背景音持续不断、打断后背景音延续

## 8. 收口

- [ ] 8.1 文档 sync：触及的 sub-repo / deploy 文档与 meta-repo 根文档（README/DESIGN/CLAUDE）一并对齐（部署时一并做）
- [x] 8.2 `openspec validate engine-ambient-background-mix --strict` 通过 <!-- 见本 session 校验输出 -->
