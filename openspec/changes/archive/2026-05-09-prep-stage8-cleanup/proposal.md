## Why

stage 1-7 + stage 6（除真硬件）都已交付并归档，stage 8 端到端联调即将启动。复盘最近三次 change（impl-engine-providers / impl-web-polish / impl-modem-controller）的归档清单，发现一批小问题如果带进 stage 8 会增加噪音：

- isales-telephony `test_health_monitor::test_scan_flags_unhealthy` 在 full-suite 下偶发失败（pre-existing flake，root cause 是 stage-2 handlers `_pump` 异步任务跨测试遗留）
- IPC 协议 dial_ack 与事件帧同时回 modem-端 UUID `call_id` + caller 端 `session_id`；按 device-hardware spec § engine ↔ modem-controller IPC 协议只规约了 `session_id`——impl 对 spec 有 drift
- 跨仓测试要分别 `cd` 进 7 个仓跑 pytest / vitest，stage 8 联调时心智成本高
- impl-web-polish 归档时 5 个 DEFERRED 项，部分能顺手做掉（README CI badge / 检查 tests/setup.ts 残留）
- isales-web `CallList` 调 `callsApi.list` 没接 `el-pagination`，跟 LeadList 不对齐

本 change 集中收掉这些；零新功能、零新依赖、零 spec 主体改动；目的是把 stage 8 启动前的"环境噪音"降到 0。

## What Changes

- **修 telephony test_health_monitor flaky bug**
  - `handlers.build_handlers` 返回 `(handlers, pump_tasks_set)`，IPCServer 引用并在 `stop()` / 连接关闭时 cancel + await 所有未结束的 pump task
  - 或者更轻量：在 `Connection` 上挂 `cancel_event`，pump 在 `_set_device_status` 之前 check；连接关闭即触发
  - 顺手把 `test_modem_ipc` / `test_modem_dial` / `test_fake_modem_e2e` 的 socket fixture 统一到一个 helper（避免每次都临时建 sock 文件）

- **IPC 协议字段名统一为 session_id**
  - `handlers.py`：dial_ack / connected / remote_hangup / hangup_ack / device_error 都只 emit `session_id`；caller 没传就用 modem UUID 作为 session_id 兜底（保留 backward-compat 行为）
  - 删除事件帧里的 `call_id` 字段（modem-端 UUID 是内部值，不暴露到 IPC）
  - 更新 `test_modem_dial.py` / `test_modem_ipc.py` / `test_fake_modem_e2e.py` 的 assertion
  - engine `RealTelephonyClient._dispatch` 已经只读 session_id，本 change 顺手清理它对 `call_id` 字段的容忍代码（spec drift cleanup）

- **主仓加跨仓测试 orchestrator**
  - `scripts/test_all.sh`：依次跑 isales-common / api / telephony / scheduler / worker / engine 的 `pytest -q`，再跑 isales-web 的 `npx vitest run`
  - 输出 summary：各仓 pass/fail 数 + 总耗时 + 总 pass/fail；任一仓失败 exit code 非零
  - `Makefile` `test-all` target 调用此脚本
  - 主仓 README 加一行 "make test-all"

- **impl-web-polish DEFERRED 收尾**
  - **1.4 README CI badge**：在 isales-web/README 顶部加 GitHub Actions CI status badge
  - **1.6 tests/setup.ts**：当前文件只有注释，没真用上；删
  - **2.6 全站 list 切 ListLoadingSkeleton + EmptyState**：仍保持 DEFERRED（el-table 内置 v-loading + empty-text 已够用）；本 change 不做，但在 impl-web-polish archive 里把这条标 v2

- **CallList 分页对齐**
  - `views/Calls/CallList.vue` 加 `el-pagination` + `page` / `page_size` reactive state，调 `callsApi.list({page, page_size})`；与 LeadList 实现风格一致

## Capabilities

### New Capabilities

无。

### Modified Capabilities

无 spec 改动。本 change 是纯实现层的 cleanup：

- `device-hardware` spec § engine ↔ modem-controller IPC 协议 已经只规约了 `session_id`，本 change 让 telephony handlers + engine RealTelephonyClient 的 impl 对齐 spec（删除 stage-2 留下的 `call_id` 字段）；spec 不动

## Impact

- **isales-telephony 仓改动**：handlers.py 重构 pump 任务跟踪 + 字段名清理；test_modem_dial / test_modem_ipc / test_fake_modem_e2e 测试 assertion 更新
- **isales-engine 仓改动**：real_telephony.py 清理对 `call_id` 字段的兼容代码；test_real_telephony.py 更新 fake server 的 emit
- **isales-web 仓改动**：CallList.vue 加分页；README 加 badge；删 tests/setup.ts
- **主仓改动**：scripts/test_all.sh + Makefile + README 一行
- **依赖链**：本 change 完成后 stage 8 启动；可独立实施，不阻塞任何后续 change
- **无新依赖、无新环境变量**
- **测试预期**：
  - isales-telephony 70 → 保持 70（修 flake；字段名改动同步反映在 assertion）
  - isales-engine 166 → 保持 166（RealTelephonyClient 实现简化，测试 mock server 同步简化）
  - isales-web 39 → 可能 +1-2（CallList pagination 测试）
- **超出本 change 范围**：
  - 任何新功能 / spec 演进
  - 真硬件验收（PR #11 of impl-modem-controller 仍 deferred）
  - 大型重构（如把 modem_controller IPC 协议升级到 length-prefix）
  - 端到端手工 + 多浏览器联调（仍 DEFERRED 到 stage 8 本身）
