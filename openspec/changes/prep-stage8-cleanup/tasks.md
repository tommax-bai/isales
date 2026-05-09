> 实施跨 4 个仓 + 主仓：isales-telephony / isales-engine / isales-web / 主仓。
> 6 个 PR 顺序合入，每个 PR 自带测试。

## 1. telephony pump task cancellation（PR #1）

- [ ] 1.1 `Connection` 类加 `cancel_event: asyncio.Event = asyncio.Event()`
- [ ] 1.2 `IPCServer._on_connect` finally 块里 `conn.cancel_event.set()`，确保 client disconnect 时所有引用 conn 的协程能 unblock
- [ ] 1.3 `handlers.handle_dial._pump`：每次 emit 前 check `conn.cancel_event.is_set()`；set 即 break
- [ ] 1.4 `handlers.handle_dial._pump`：在 `_set_device_status` 之前 check cancel_event；避免连接关闭后还写 device.status 污染下游测试
- [ ] 1.5 `IPCServer.stop()`：先 close server，再 wait_closed；现有逻辑足够（每 connection task 收到 EOF 自然退出，cancel_event 在 finally 触发）
- [ ] 1.6 测试：故意写一个 `test_pump_does_not_leak_after_disconnect`——发 dial、读 dial_ack、立刻 close writer、等 100ms、断言 device.status 没被改回 IN_CALL
- [ ] 1.7 验证 flake 修了：`pytest -q` 全套跑 5 次，每次都过

## 2. IPC 协议字段名统一为 session_id（PR #2）

- [ ] 2.1 telephony `handlers.handle_dial`：caller 没传 session_id 时用 modem UUID（`call_id`）作为 session_id 兜底；ack / events 只 emit `session_id`，不 emit `call_id`
- [ ] 2.2 telephony `handlers.handle_hangup`：caller 传 session_id 优先；fallback 接受旧 `call_id` 字段触发 ATClient.hangup（保留兼容路径）；但 ack 只回 session_id
- [ ] 2.3 telephony `tests/test_modem_dial.py`：assertion 改成读 `session_id` 而不是 `call_id`；验证缺省 session_id 时的兜底（用 UUID）
- [ ] 2.4 telephony `tests/test_modem_ipc.py`：同上
- [ ] 2.5 telephony `tests/test_fake_modem_e2e.py`：assertion 简化（只看 session_id）
- [ ] 2.6 engine `realtime/real_telephony.py`：`_dispatch` 删除对 `call_id` 字段的容忍读取；只读 session_id
- [ ] 2.7 engine `tests/test_real_telephony.py`：fake server 的 emit 移除 `call_id` 字段
- [ ] 2.8 验证 telephony 70/70 + engine 166/166

## 3. 跨仓测试 orchestrator（PR #3）

- [ ] 3.1 主仓 `scripts/test_all.sh`：bash 脚本，依次跑 isales-common / api / telephony / scheduler / worker / engine 的 `.venv/bin/python -m pytest -q --no-header`，再跑 isales-web 的 `npx vitest run`
- [ ] 3.2 每个仓跑前检测 `.venv/bin/python` 存在，否则报错并提示 `pip install -e .[dev]`（web 报错提示 `npm install`）
- [ ] 3.3 每个仓跑完写一行 summary：`✓ isales-telephony 70 passed in 2.1s` 或 `✗ isales-telephony 1 failed`；脚本继续，不 abort
- [ ] 3.4 脚本结尾打印总 summary：成功仓数 / 失败仓数 / 总耗时；任一仓失败 exit 1
- [ ] 3.5 主仓 `Makefile`：`test-all:` target 调脚本
- [ ] 3.6 主仓 README 加一行 `make test-all` 说明
- [ ] 3.7 跑一次 `make test-all` 确认所有仓全绿（PR #1+#2 的改动已落）

## 4. CallList 分页（PR #4）

- [ ] 4.1 `views/Calls/CallList.vue`：加 `page` / `page_size` reactive；调 `callsApi.list({page, page_size})`
- [ ] 4.2 加 `el-pagination` 模板（layout / total / page-sizes 与 LeadList 一致）
- [ ] 4.3 注意：`callsApi.list` 现在返 `CallRecordSummary[]`（已 unwrap items）；如果要分页需要返 `total`，扩展为返 `{items, total}` 或 store 层封装
- [ ] 4.4 测试：跟 LeadList pagination 同风格的 vitest，验证 page change → re-fetch
- [ ] 4.5 验证 web 41/41 全绿（原 39 + 2 新）

## 5. impl-web-polish DEFERRED 收尾（PR #5）

- [ ] 5.1 `isales-web/README.md` 顶部加 GitHub Actions CI badge（assume default branch=main）
- [ ] 5.2 `isales-web/tests/setup.ts` 当前只是注释占位；删，并验证 vitest 不再引用（看 vite.config.ts 的 test.setupFiles）
- [ ] 5.3 验证 `npm run typecheck && npm run lint && npx vitest run` 全过

## 6. 收尾

- [ ] 6.1 `make test-all` 全绿
- [ ] 6.2 主仓 commit 标记 prep-stage8-cleanup 实施完成
- [ ] 6.3 archive 由 /opsx:archive 触发
