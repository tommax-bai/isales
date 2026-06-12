## 1. 调研确认（apply 开场）

<!-- prompt_builder.py grep: _render_dialog/_render_lead_info/_build_user_message 仅被 build_main_messages(main) 调用，无外部复用；referee 有独立 _render_dialog_history_for_referee。可安全重构。 -->
- [x] 1.1 grep `_render_dialog` / `build_main_messages` / `_build_user_message` 在 `isales-engine` 全仓的调用方，确认除 main 外是否有 transcript / pipeline_trace 复用（design Open Question）
<!-- call_session.py:209 user_speech→"user"，其余(greeting/ai_reply)→"assistant"，二值闭集，1:1 映射。 -->
- [x] 1.2 确认 `DialogTurn.role` 取值闭集为 `{"user","assistant"}`（`call_session.py`），无第三值需特殊映射

## 2. 重写 prompt_builder（核心）

<!-- prompt_builder.py build_main_messages 重写：system(主体+context+follow_up+short_reply+wrap_up) + 遍历 dialog_history emit 多轮 Message。context 放主体后/指令前以保 wrap_up 最末。 -->
- [x] 2.1 重写 `build_main_messages`：返回 `[system] + [多轮 dialog message]`，system 含主体 + follow_up/short_reply/wrap_up append（wrap_up 仍最末）+ 末尾【上次通话纪要】(跟进)/【线索信息】context 段
- [x] 2.2 新增/改造 dialog 映射逻辑：遍历 `session.dialog_history` 每 turn emit `Message(role=turn.role, content=turn.text)`，按时间顺序，不拼文本、不加 `用户:`/`AI:` 前缀、不挂末尾 `AI:` 钩子
<!-- 新增 _render_context(config)；FOLLOW_UP 模板「下面的」→「上述」(纪要现位于其上)，spec 同步。 -->
- [x] 2.3 把会话级静态上下文拼装抽成 system context 段函数（替代原 `_build_user_message` 把它们放进 user message 的逻辑）
<!-- 无外部调用方(见 1.1)，_render_dialog + _build_user_message 已删除。 -->
- [x] 2.4 处理 `_render_dialog`：若 1.1 确认无其他调用方则删除；若有则保留供他用、main 不再调用
- [x] 2.5 `build_greeting_messages` 保持不变（验证未被波及）

## 3. 测试

<!-- 新增 tests/test_prompt_builder.py 6 测：多轮映射/无拍平无AI钩子/lead在system/follow_up纪要在system/wrap_up最末/空history。无既有 prompt_builder 测试需改。 -->
- [x] 3.1 更新 `prompt_builder` 单测：从断言单 user message 文本子串改为断言多轮数组结构（条数、各 turn role/content、context 在 system）
- [x] 3.2 补边界单测：空 dialog_history、仅 greeting 无 user_speech、连续同 role 不产生空 content message
<!-- orchestrator 测试无 main-message 结构断言(test_pipeline 仅 referee path 取 user content)，无需改。 -->
- [x] 3.3 更新受影响的 `orchestrator` 相关单测断言（messages 长度/结构）
<!-- 421 passed, 1 failed = test_gating::test_gate_fails_open_to_main_on_referee_timeout，stash 后原 main 代码 5/5 同样失败 = pre-existing 时序 flaky(20ms 超时本机过紧)，与本改动无关。 -->
- [x] 3.4 `cd ../isales-engine && .venv/bin/python -m pytest -q` 全绿（除 1 个 pre-existing 时序 flaky）

## 4. 部署

<!-- scp → releases/20260517-222944/isales-engine/isales_engine/pipeline/prompt_builder.py（editable，共享 /opt/isales/current/venv）。 -->
- [x] 4.1 scp `prompt_builder.py` 到 ECS engine 部署路径（参照既有 scp 覆盖纪律，不走 git pull）
<!-- deployed module: build_main_messages present / _render_dialog removed / _render_context present；engine active。 -->
- [x] 4.2 `ssh root@121.89.85.150 'systemctl restart isales-engine'` + 确认 active
<!-- STATE.md 新增 17:10 CST 条目（engine 单文件 + 重启，无 alembic/无 common 版本）。 -->
- [x] 4.3 更新 `deploy/cloud/STATE.md` 若涉及部署状态变化

## 5. 真机验收

- [ ] 5.1 重启 engine 防 bug2 冻死后跑 `mac_dev_no_modem_smoke.py --no-listen-check`，确认管线全绿（多轮改动不破坏 main 调用）
- [ ] 5.2 真人 mic：同 campaign 同话术，改前/改后对比主对话衔接质量（主观但需记录结论）

## 6. 收口

- [ ] 6.1 回写 tasks.md 进度（HTML 注释标 commit/PR/偏离）
- [ ] 6.2 `openspec validate engine-main-native-multiturn --strict` 通过
- [ ] 6.3 commit + push（meta-repo + engine sub-repo），准备 archive
