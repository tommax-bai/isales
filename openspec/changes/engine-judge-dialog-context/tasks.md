## 1. 代码改动（已实装，仅回写引用 commit）

<!-- 84c5db8 isales-engine commit "experiment(judge-context-and-greeting)" -
     chat-history 那部分已实装 + SCP 部署 ECS + 真拨号实证 -->

- [x] 1.1 `isales-engine/isales_engine/pipeline/prompt_builder.py`: `build_judge_messages` 签名加 `session: CallSession` 参数 — 已 commit `84c5db8`
- [x] 1.2 `isales-engine/isales_engine/pipeline/prompt_builder.py`: user message 重组成 `### 对话历史\n{...}\n\n### 销售 AI 准备发给客户的候选回复\n{...}\n\n按上述系统提示的 JSON schema 输出。` 两段 markdown section — 已 commit `84c5db8`
- [x] 1.3 `isales-engine/isales_engine/pipeline/prompt_builder.py`: 新增 `_render_dialog_history_for_judge(session: CallSession) -> str` 辅助函数（用户：/AI：前缀 + 全角冒号 + 无尾部 `AI:` 提示行 + 空历史返回 `"（尚无对话历史，这是首轮回复）"`）— 已 commit `84c5db8`
- [x] 1.4 `isales-engine/isales_engine/pipeline/orchestrator.py`: `_run_judges_parallel(...)` 加 `session: CallSession` 参数 — 已 commit `84c5db8`
- [x] 1.5 `isales-engine/isales_engine/pipeline/orchestrator.py`: `run_pipeline` 调用 `_run_judges_parallel` 时传 `session=session` — 已 commit `84c5db8`

## 2. 单元测试（本 change 补全）

<!-- 当前 grep 显示 tests/test_pipeline.py 和 tests/test_prompt_builder.py 都
     无 build_judge_messages 测试覆盖。本 change archive 前补齐。 -->

<!-- 实装于 isales-engine working tree (uncommitted), 5 test methods 落在
     tests/test_pipeline.py 末尾 class TestBuildJudgeMessages 下, 8 个 judge 相关
     test (5 new + 3 existing) 全绿; 全套 272 passed (5 pre-existing TTS 失败无关) -->
- [x] 2.1 在 `isales-engine/tests/test_pipeline.py` 新增 `class TestBuildJudgeMessages` + import `build_judge_messages` / `JUDGE_OUTPUT_SCHEMA_SUFFIX` 到顶部 import 块
- [x] 2.2 case：N 轮对话历史拼接 — `test_n_turn_history_rendered_in_user_message`，构造 2 轮 `DialogTurn`（greeting + user_speech），assert user message 含 `### 对话历史` / `AI：<greeting>` / `用户：<speech>` / `### 销售 AI 准备给客户的候选回复` / candidate / `按上述系统提示的 JSON schema 输出。` 结尾
- [x] 2.3 case：空对话历史占位 — `test_empty_history_uses_explicit_placeholder`，`dialog_history == []` 时 assert `（尚无对话历史，这是首轮回复）`，不留空
- [x] 2.4 case：system prompt SUFFIX 保留 — `test_schema_suffix_on_system_not_repeated_in_user`，assert system 含 `[judge] ` + PG 内容 + SUFFIX；user 不含 SUFFIX 字面
- [x] 2.5 case：用户/AI 前缀 + 全角冒号 — `test_user_ai_prefixes_use_chinese_fullwidth_colon`，assert 中文 + 全角冒号；不含英文 `user:` / `assistant:` / 半角冒号变体
- [x] 2.6 case：尾部不带 `AI:` 提示行 — `test_no_trailing_ai_prompt_line`，assert 历史段最后非空行是 `用户：客户发言`（不是空 `AI:`）
- [x] 2.7 跑 `cd ~/codes/isales-engine && .venv/bin/python -m pytest tests/test_pipeline.py -k "TestBuildJudgeMessages or judge"` 8 passed + 15 deselected; 全套 272 passed

## 3. 部署确认（已部署，仅记录）

<!-- 84c5db8 已通过 SCP 部署 ECS, 走 [[feedback_ecs_deploy_scp]] 规则。
     无新增部署动作。 -->

- [x] 3.1 ECS engine `121.89.85.150` 跑的代码 = `84c5db8` 内容（SCP 三文件覆盖 `/opt/isales/current/isales-engine/isales_engine/pipeline/{prompt_builder,orchestrator}.py` + `runtime_config.py`；后者属 `campaign-fixed-greeting` 范围 不在本 change 内）
- [x] 3.2 ECS systemd `isales-engine.service` 重启后 `isales_engine_started` + `credentials_loaded count=5 providers=['dashscope', 'volcengine']` 无 import error
- [x] 3.3 mac dev DingRTC 真拨号验收 — pipeline_trace.call_record_id=51 三 turn 全 `passed=true`，polish_output 真销售话术（详见 memory `project_session_2026_05_29_handoff` § "实验结果"）

## 4. Archive 准备

- [x] 4.1 跑 `openspec validate engine-judge-dialog-context --strict` 全绿
- [x] 4.2 isales-engine 仓本地无新 commit（`84c5db8` 已 push 到 origin/dingrtc-migration-cloud），本 change 不在 isales-engine 仓再 commit — **修订**: tests/test_pipeline.py 加了 5 个 TestBuildJudgeMessages case，需要在 isales-engine 仓 commit 测试 + push origin
- [ ] 4.3 meta-repo `~/codes/isales` commit 本 change 全 4 个 artifact（proposal / design / specs/role-prompt/spec.md / tasks.md）+ tasks.md 进度回写
- [ ] 4.4 meta-repo push origin
- [ ] 4.5 跑 `/opsx:archive engine-judge-dialog-context`，合并 spec delta 到 `openspec/specs/role-prompt/spec.md`，移动 change 目录到 `openspec/changes/archive/YYYY-MM-DD-engine-judge-dialog-context/`
- [ ] 4.6 archive 后 commit + push meta-repo

## 5. 与 prompt-template-vars 的反向解耦（本 change 完成后由 step 1 收尾）

<!-- 本 change archive 后会反证 prompt-template-vars 不必要。step 1（按用户拍板顺序
     4 → 2 → 3 → 1）做以下事 — 不在本 change 范围，仅在此记录为 follow-up： -->

- [ ] 5.1 (follow-up, step 1) `git stash drop stash@{0}` 把 prompt-template-vars 实装代码扔掉
- [ ] 5.2 (follow-up, step 1) meta-repo `openspec/changes/prompt-template-vars/proposal.md` 顶部加 SUPERSEDED block 引用本 change，或整 `rm -rf` 该目录
- [ ] 5.3 (follow-up, step 1) memory `project_session_2026_05_29_handoff` 末尾标注 step 1 已完成
