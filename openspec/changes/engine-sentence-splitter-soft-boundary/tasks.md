# Tasks: engine-sentence-splitter-soft-boundary

> 阶梯第 1 档（B）。纯 engine 单文件 + 测试。进度回写本文件（HTML 注释标 commit / 偏离）。

## 1. 实装

- [x] 1.1 `isales-engine/isales_engine/streaming/sentence_splitter.py`：加 `SOFT_SENTENCE_CHARS=60` + `_SOFT_BOUNDARIES="，、；：,;:"`；`MAX_SENTENCE_CHARS` 50→120；切句条件加「软阈值后软标点切」一档、`>=max_chars` 降为兜底；`split_sentences` 加 `soft_chars` 参数。 <!-- engine fa5617a -->
- [x] 1.2 句末标点 / `\n\n` / flush / 无可读内容过滤逻辑保持不变。 <!-- engine fa5617a；_TERMINATORS/_has_synthesizable_text/tail flush 未动 -->

## 2. 测试

- [x] 2.1 更新 `tests/test_sentence_splitter.py`：无标点串不再在 50 字硬切（拆成 `test_no_punctuation_run_under_ceiling_stays_whole` 保持整句 + `test_hard_ceiling_forces_split_for_punctuationless_runon` 到 120 才兜底切）。 <!-- engine fa5617a -->
- [x] 2.2 新增用例：`test_long_sentence_splits_at_soft_boundary_not_mid_word`（软标点切，非拦腰）；`test_comma_below_soft_threshold_does_not_split`（短句含逗号不因长度切，逐字不变）。 <!-- engine fa5617a -->
- [x] 2.3 pytest 全绿：目标 `test_sentence_splitter.py`+`test_play_streaming.py` 25 passed；全量 460 passed，唯一失败 `test_gating::test_gate_fails_open_to_main_on_referee_timeout` 经 stash 验证为 pre-existing（干净树同样红、不 import splitter）。 <!-- engine fa5617a -->

## 3. 部署 / 收口

- [x] 3.1 scp `sentence_splitter.py` 到 ECS `/opt/isales/current/isales-engine/.../sentence_splitter.py`（editable live import 路径）+ chown isales + 重启 engine；live import 实证 `MAX=120 SOFT=60 BOUND='，、；：,;:'`，日志 `isales_engine_started`+`credentials_loaded count=6` 无 traceback。 <!-- 2026-06-17 11:31 CST ECS 121.89.85.150 -->
- [x] 3.2 `openspec validate engine-sentence-splitter-soft-boundary --strict` 通过。
- [x] 3.3 commit + push（engine + meta）。 <!-- engine fa5617a；meta 见本提交 -->
- [ ] 3.4 **真机听感**：长文本跨句是否更连贯、拦腰切是否消失（用户耳朵确认）。听完再决定是否上阶梯第 2 档 A（整轮单向合并）/ 第 3 档双向流式。
- [ ] 3.5 全 task 完成 + 真机确认后 archive。
