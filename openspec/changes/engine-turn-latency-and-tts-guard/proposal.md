## Why

分析真机通话 call 194(思考关闭后首通)暴露三个 pipeline 观测/健壮性缺口:

1. **TTS 无可读内容报错**:main 回复 "呃...那个，您听岔啦..." 经 `sentence_splitter` 切句,省略号 "..." 被逐点切成裸标点 chunk(如单个 "."),送 Volcengine TTS 被 vendor 拒:`code=45002001 message=No readable text!`(call 194 turn 4 实录)。首音频虽仍出(后半句正常),但碎片丢失且每次刷 error。

2. **restructure 重组轮丢 pipeline_trace**:`_run_restructure` 发了 `ai_reply` 转录事件(用新 `turn_id`)却**不写** pipeline_trace(正常对话路两个都写)。call 194 转录有 turn 3 回复但 pipeline_trace 无 turn 3 行——这一轮的延迟/token 无法事后查询。

3. **首 token / 首句延迟算了就丢**:`MainStreamResult.first_token_ms` / `first_sentence_ms`(LLM 首字 TTFT、首句产出)在 orchestrator 内算出但从不落库,turn 结束即丢。排查"首音频 608ms 是 LLM 慢还是 TTS 慢"时无数据(本 session 查 193/194 就缺这一层)。

同时,dev 演练脚本 `mac_dev_no_modem_smoke.py` 当前只打印坏掉的 transcript 快照(用 `turn.get("speaker")`,但事件字段是 `type`/`text`,恒打印 `?`),没有按节点的耗时视图。

## What Changes

- **TTS 句过滤**:`sentence_splitter.split_sentences` 只 yield 含可合成内容的句——按 Unicode 类别判定(含任一 L*/N* 字母或数字即可合成),滤掉纯标点/空白/符号 chunk(如裸 "." / "…" / "。")。覆盖 main 流式 + 一次性 fallback(都过 splitter);固定话术(开场白/静默催/转人工)走 `_play_tts` 不经 splitter、是受控输入,不动。
- **restructure 落 trace**:`_run_restructure` 在播完后补写一条 pipeline_trace(restructure 输出轮,带 `rs.turn_id` / `restructure_active=true` / source_text / 该轮 main_* 延迟与 token),与正常对话路对齐。
- **首 token/首句入库**:`pipeline_trace` 新增 `main_first_token_ms` / `main_first_sentence_ms`(nullable int);`_base_trace` 从 `stream.result` 透传;`transcript_recorder` 显式构造同步加列。
- **smoke 脚本**:`mac_dev_no_modem_smoke.py` 新增对话+耗时视图——按 turn 打印 user/AI 文本;user 轮显示 说话→LLM 各节点(说话时长 / ASR finalize / 门控 referee 耗时);AI 轮显示 LLM 收到→播放 各节点(首 token / 首句 / 首音频 / main 总时长 / tokens)。数据从 `pipeline_trace` + `transcript`(脚本已有 ssh+psql 通道)。

## Capabilities

### New Capabilities
- `ai-pipeline`: 新增「TTS 不合成无可读内容的句」+「重组轮落 pipeline_trace」+「pipeline_trace 记首 token/首句延迟」三条 requirement。
- `data-model`: 新增「pipeline_trace 首 token / 首句延迟列」requirement(`main_first_token_ms` / `main_first_sentence_ms`)。

### Modified Capabilities
<!-- none — ADDED-only, 避开 archive 段错配 -->

## Impact

- **isales-common**:`models/pipeline_trace.py` +2 列;alembic 迁移 `d1e2f3a4b5c6`(down=`c0d1e2f3a4b5`,2 nullable 列,downgrade drop);版本 0.8.15→0.8.16。
- **isales-engine**:`streaming/sentence_splitter.py`(可合成过滤)、`run_loop.py`(`_base_trace` +2 键 / `_run_restructure` 补 trace)、`transcript_recorder.py`(+2 kwargs);pin common 0.8.16。
- **isales-telephony**:`scripts/mac_dev_no_modem_smoke.py`(对话+耗时视图;debug 分支 `debug/mac-dev-no-modem-asr-stereo-fix-20260601`)。
- 测试:engine splitter 纯标点过滤测 + restructure trace 测;common migration round-trip。
- 部署:common 0.8.16 + alembic d1e2f3a4b5c6 到 ECS DB,scp engine 三文件 + restart。
- 真机验收:新通话 pipeline_trace 见 `main_first_token_ms`/`main_first_sentence_ms` 落值、restructure 轮有行、无 `No readable text` error;smoke 脚本打印分节点耗时。
