# Tasks — engine-turn-latency-and-tts-guard

## 1. TTS 句过滤(无可读内容不送 TTS)

- [x] 1.1 `isales-engine/isales_engine/streaming/sentence_splitter.py` 加 `_has_synthesizable_text(s)`(Unicode 类别:含任一 L*/N* 即 True),两处 yield(emit + tail)前 gate。 <!-- engine -->
- [x] 1.2 测试:`test_ellipsis_punctuation_only_chunks_dropped`("呃...那个。"→["呃.","那个。"])/`test_all_punctuation_yields_nothing`/`test_digit_is_synthesizable`。 <!-- engine -->

## 2. restructure 重组轮落 pipeline_trace

- [x] 2.1 `run_loop.py` `_run_restructure` 入口取 `rs_ts_start = now_utc()`;播完后 append trace(`_base_trace(rs,...)` + `restructure_active=True` + trigger + source_text)。 <!-- engine -->
- [x] 2.2 调用点把 `sel.restructure_trigger` 传入 `_run_restructure`。 <!-- engine -->
- [x] 2.3 测试:扩 `test_auto_restructure_on_interrupt_fires_without_rule`——决策行+输出行各一、turn_id 不同。 <!-- engine -->

## 3. 首 token / 首句延迟入库

- [x] 3.1 `isales-common/.../models/pipeline_trace.py` 新增 `main_first_token_ms` / `main_first_sentence_ms`(nullable Integer)。 <!-- common -->
- [x] 3.2 alembic 迁移 `d1e2f3a4b5c6`(down=`c0d1e2f3a4b5`):add 2 nullable 列;downgrade drop。 <!-- common; alembic heads 本地 d1e2f3a4b5c6 -->
- [x] 3.3 common 版本 0.8.15→0.8.16。 <!-- common -->
- [x] 3.4 `_base_trace` 加 2 键;`transcript_recorder.py` 显式构造加 2 kwargs;engine pin common 0.8.16。 <!-- engine -->
- [x] 3.5 测试:common 189 passed;golden fixture 重生成(2 新键自动 scrub 成 `<volatile>`,仅 +6 行);engine 433 passed(唯一失败=pre-existing gate flake,无关)。 <!-- engine+common -->

## 4. smoke 脚本对话 + 分节点耗时

- [x] 4.1 `mac_dev_no_modem_smoke.py` 新增 `phase_dialog_timeline`:ssh+psql 拉 `pipeline_trace`(json_agg)+ `transcript`,按事件时序打印对话。 <!-- telephony debug branch -->
- [x] 4.2 user 轮:说话时长 + ASR/排队(ts_start - user_speech.ts)+ 门控 referee 耗时。 <!-- telephony -->
- [x] 4.3 AI 轮:首token→首句(+Δ)→首音频(+Δ TTS)→末token + tokens + error。 <!-- telephony -->
- [x] 4.4 删掉原坏 transcript 快照(`turn.get("speaker")` 恒 `?`),timeline 取代;py_compile OK。 <!-- telephony -->

## 5. 部署

- [x] 5.1 scp common(editable,model + 迁移)+ engine 三文件到 ECS;`alembic upgrade head`(`c0d1e2f3a4b5 → d1e2f3a4b5c6`,prod DB);restart engine。 <!-- 2026-06-15: 新 PID 1014192 active, isales_engine_started + credentials_loaded count=6 无报错;DB 两列 main_first_{token,sentence}_ms(integer,nullable)已建;isales venv 实测 _has_synthesizable_text("呃.")=T/(".")=F/("。。。")=F/("3")=T + model 两列 hasattr=T,T -->
- [x] 5.2 部署后运行时校验:分句器过滤 + model 列 import 实测通过。 <!-- 2026-06-15 -->

> ⚠️ STATE.md 未改:纯加列迁移(additive nullable)+ 单文件 scp,无新服务/端口/凭据/拓扑变更。alembic head 由 c0d1e2f3a4b5 → d1e2f3a4b5c6。

## 6. 真机验收 — **deferred**（部署后至收口无自然通话；用户选择收口）

- [ ] 6.1 新通话:pipeline_trace 见 `main_first_token_ms`/`main_first_sentence_ms` 落值、restructure 轮有行、无 `No readable text` error。 <!-- deferred 2026-06-15: 部署后 0 通话；行为由单测覆盖(splitter 3 测 + restructure 决策/输出行断言 + golden) + 部署期 isales-venv 运行时实测(过滤 T/F/F/T + 列 hasattr)双重背书。下一通真实通话即可坐实。 -->
- [ ] 6.2 smoke 脚本 `mac_dev_no_modem_smoke.py` 跑出对话 + 分节点耗时视图。 <!-- deferred: 需 mac edge + 真拨;py_compile OK -->

## 7. 收口

- [x] 7.1 `openspec validate engine-turn-latency-and-tts-guard --strict`。 <!-- valid -->
- [x] 7.2 commit common(675a192)/engine(87c8792)/telephony(40044b8)/meta(912d2b4+1c3010f),push。
- [x] 7.3 archive。 <!-- 2026-06-15 -->

> 说明:§6 真机验收 deferred（同 engine-llm-disable-thinking §4.2 模式）。代码行为由单测 + 部署期运行时实测背书；真机端到端坐实留给下一通自然通话。
