# Tasks — engine-llm-disable-thinking

## 1. Provider 层关思考

- [x] 1.1 `isales-engine/isales_engine/providers/llm_openai_compatible.py` 新增 `_thinking_off_payload()` helper（按 `self._provider` 返回 dashscope=`{"enable_thinking": False}` / volcengine=`{"thinking": {"type": "disabled"}}` / 其他=`{}`），含注释注明场景 + 移除触发条件。 <!-- engine cb2e756 -->
- [x] 1.2 在 `chat()` 的 payload 构造处 merge `_thinking_off_payload()`。 <!-- engine cb2e756 -->
- [x] 1.3 在 `chat_stream()` 的 payload 构造处 merge `_thinking_off_payload()`。 <!-- engine cb2e756 -->

## 2. 测试

- [x] 2.1 新增 provider 单测：`httpx.MockTransport` 捕获请求体，断言 `chat(provider="dashscope")` payload 含 `enable_thinking=False`、`chat(provider="volcengine")` payload 含 `thinking={"type":"disabled"}`。 <!-- engine cb2e756 tests/test_llm_thinking_disabled.py -->
- [x] 2.2 同样断言 `chat_stream` 两 provider 的 payload。 <!-- engine cb2e756 -->
- [x] 2.3 `mock` 路径不受影响（无 HTTP）—— `test_chat_unknown_provider_injects_nothing` 覆盖非注入分支。 <!-- engine cb2e756 -->
- [x] 2.4 跑 `isales-engine` 全量测试绿（430 passed；唯一失败 `test_gate_fails_open_to_main_on_referee_timeout` 为 main HEAD pre-existing、与本 change 无关，stash 隔离已证）。 <!-- engine cb2e756 -->

## 3. 部署

- [x] 3.1 scp `llm_openai_compatible.py` 到 ECS（`/opt/isales/current/isales-engine/...`，current→releases/20260517-222944），`systemctl restart isales-engine`，验证服务健康。 <!-- 2026-06-15 deploy: 新 PID 1012106 active(running)，旧进程 graceful_shutdown active=0 无打断；isales_engine_started + credentials_loaded count=6；isales venv import 确认 _thinking_off_payload 返回 dashscope={'enable_thinking':False}/volcengine={'thinking':{'type':'disabled'}} -->
- [x] 3.2 部署后运行时确认两 provider helper 返回值正确（isales venv `-c` import 实测）。 <!-- 2026-06-15 -->

> ⚠️ STATE.md 未改：本 change 为纯代码补丁（scp 单文件 + restart），无新服务/端口/alembic/凭据变化，不属 STATE.md 跟踪的部署拓扑变更。

## 4. 真机验收

- [ ] 4.1 部署后下一通真实通话的 `pipeline_trace`：`tokens_out` ~50、`first_audio_ms` ~1-3s（dashscope 路径）。
- [ ] 4.2 volcengine 路径真机生效 —— **deferred**（火山账号当前无可用豆包模型）。

## 5. 收口

- [x] 5.1 `openspec validate engine-llm-disable-thinking --strict` 通过。
- [ ] 5.2 commit engine + meta（tasks.md 进度回写），push origin。 <!-- engine cb2e756 done; meta + push 进行中 -->
- [ ] 5.3 archive。
