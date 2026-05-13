## 1. SerialATClient 落地（PR 1）

- [x] 1.1 在 `isales_telephony/modem_controller/at_client.py` 新增 `class SerialATClient`：构造接收 `pyserial.Serial` 实例 + `serial_protocol.AtClient` + `drivers.ModemDriver`；实装 `ATClient` Protocol 全部方法（`dial / hangup / get_signal / get_iccid / get_imei`）
- [x] 1.2 新增 `SerialATClient.create_from_tty(tty_path: str, driver_hint: str = "") -> SerialATClient` 工厂方法：开串口（`pyserial-asyncio`，115200 8N1）→ `fcntl.flock(LOCK_EX | LOCK_NB)` 拿独占锁，拿不到抛 `BusyDeviceError` → 构造 `AtClient` 并启动 → `await detect_driver(at, hint=driver_hint)` → `await driver.init()` → 返回 `SerialATClient`
- [x] 1.3 实装 `SerialATClient.dial()`：调 `driver.dial(number, timeout=ATD_ACK_TIMEOUT_S)` 取 `DialResult`；`connected=False` → 立即返回 `(call_id, 单事件流 yield remote_hangup cause=DialResult.hangup_cause or "network_out_of_order")`；`connected=True` → 启动 AT+CLCC 后台 poller，返回 `(call_id, self._urc_stream(call_id))`
- [x] 1.4 实装 URC → ATEvent 翻译：`on_urc` 回调把 `NO CARRIER` / `BUSY` / `NO ANSWER` / `NO DIALTONE` 映射经 `drivers.HANGUP_CAUSE_MAP` → push `ATEvent("remote_hangup", ..., cause=<canonical>)` 到 per-call queue；`AT+CLCC` poll state=0 → push `ATEvent("connected", ...)`；`_urc_stream` 去重 connected 并在 remote_hangup 后 return；本端 `hangup()` 推 `ATEvent("remote_hangup", ..., cause="manual_hangup")`
- [x] 1.5 实装 `SerialATClient.hangup(call_id)`：调 `driver.hangup()` 发 ATH/`+CHUP` → push manual_hangup ATEvent；同一 call_id 多次调 hangup 幂等（active_call_id 不匹配 → 静默 no-op）
- [x] 1.6 实装 `get_signal / get_iccid / get_imei`：直接转 `ModemDriver.signal_strength() / iccid() / imei()`
- [x] 1.7 在 `at_client.py` 新增 `class BusyDeviceError(RuntimeError)` 异常
- [x] 1.8 在 `tests/modem_serial/test_serial_at_client.py` 新增 11 个单元测试，用 socket-pair 假 modem 覆盖：AT+CLCC active → connected、NO CARRIER → user_hangup、BUSY → user_busy、NO ANSWER → no_answer、NO DIALTONE → network_out_of_order、ATD ACK 超时 → 立即 remote_hangup、本端 hangup → manual_hangup、未知 call_id hangup 幂等、并发 dial 拒绝、`get_signal/iccid/imei` 透传、`_clcc_has_active_call` 解析正确性
- [x] 1.9 跑 `pytest tests/modem_serial/test_serial_at_client.py` 全绿（11 passed, 0.24s）；跑全套 modem 相关测试 50 passed

## 2. main.py / handlers.py 切换（PR 2）

- [x] 2.1 修改 `modem_controller/main.py`：新增 `_make_at_client() -> ATClient`，按 design 决策 3 实现 env dispatch（`ISALES_MODEM_SERIAL_PATH` → SerialATClient；`ISALES_ALLOW_MOCK_AT=1` → MockATClient；其余抛 RuntimeError）
- [x] 2.2 `main.py` 用 `await _make_at_client()` 替换硬编码 `MockATClient()`；构造失败 MUST 让进程 exit 非零（不要 catch）；shutdown 路径补 `at_client.aclose()`
- [x] 2.3 修改 `modem_controller/handlers.py`：`build_handlers()` 的 `at_client` 改为必填关键字参数，取消 `at_client or MockATClient()` 默认兜底；`DEFAULT_HANDLERS` 常量替换为 `default_mock_handlers()` 工厂函数（避免导入即实例化 mock）
- [x] 2.4 修改所有现有调 `build_handlers()` 的测试代码：`test_modem_dial / test_modem_pump_cancel / test_fake_modem_e2e` 已显式传 `MockATClient()`，`test_modem_ipc` 改用 `default_mock_handlers()`
- [x] 2.5 在 `tests/conftest.py` 顶部 `os.environ.setdefault("ISALES_ALLOW_MOCK_AT", "1")`（pytest-env 未安装，conftest setenv 更靠谱）；pyproject 里加备注指向 conftest
- [x] 2.6 systemd unit `deploy/isales-modem-controller.service` 与 macOS plist `deploy/macos/plist/com.isales.modem-controller.plist` 补强 `ISALES_MODEM_SERIAL_PATH` 必填注释（plist 由 install.sh 在装配期内联 /etc/isales/env/modem-controller.env）
- [x] 2.7 更新 `deploy/RUNBOOK.md` §5 故障对照表：补两条新症状——「`ISALES_MODEM_SERIAL_PATH is required` 退出」与「生产日志出现 `MockATClient (dev/CI mode)`」的诊断与处置
- [x] 2.8 启动测试：`ISALES_ALLOW_MOCK_AT=1 python -c "_make_at_client()"` → 日志 WARN + 返回 MockATClient；清空 env → `RuntimeError: ISALES_MODEM_SERIAL_PATH is required` 抛出；两条路径都验证 OK

## 3. 真硬件冒烟脚本（PR 3）

- [x] 3.1 新增 `scripts/at_smoke.py`：argparse 入参 `--tty <path> --number <phone> [--driver <hint>] [--wait-seconds <s>] [--verbose]`
- [x] 3.2 脚本逻辑：构造 `SerialATClient` → 调 `dial(number)` 拿 call_id + 事件流 → `async for event in stream` 打到 stdout（带相对时间戳）→ 收到 connected 后异步 `asyncio.sleep(wait_seconds)` 默认 5 → `client.hangup(call_id)` → 等 remote_hangup → exit 0；BusyDeviceError → exit 2；其他异常 traceback → exit 1；stream 提前结束无 remote_hangup → exit 3
- [x] 3.3 在 isales-telephony README 新增 "## Real hardware smoke test" 章节：Linux 与 macOS 各给一个调用示例 + tty 发现命令 + 期望输出样本；新版 env 变量表更新（`ISALES_MODEM_SERIAL_PATH` 必填、`ISALES_MODEM_DRIVER` 可选、`ISALES_ALLOW_MOCK_AT` CI-only）
- [ ] 3.4 真硬件验收：用 A7670E + 国内移动 SIM，拨打自己手机号，5 通连呼，记录每通 `ATEvent` 序列与 hangup_cause；至少要看到：1 通正常应答 + 自己接听 + 5s 后由脚本主动挂断（`manual_hangup`）；1 通自己不接，等到 NO ANSWER（`no_answer`）；1 通自己按"忙线"或"拒接"（`user_busy`）；记录到 acceptance log

## 4. spec deltas 归档前 dry-run

- [x] 4.1 跑 `openspec validate impl-real-at` 全绿
- [x] 4.2 跑 `openspec change show impl-real-at --json --deltas-only` 浏览 delta 文本；spec delta 与 main spec 的 `hangup_cause` 词汇、`session_id` / `call_id` 命名、ATEvent 字段全部对齐
- [x] 4.3 **现状审计发现 `drivers.HANGUP_CAUSE_MAP` 用非规范值**（`callee_busy / callee_no_answer / carrier_congestion / device_error / local_clearing`），与 `isales_common.enums.HangupCause` 与 `retry-followup` spec 词汇 (`no_answer / user_busy / network_out_of_order / temporary_failure / normal_clearing / call_rejected / user_hangup / manual_hangup`) 不一致。**在本 change 内一并修正**：
  - `drivers.py:HANGUP_CAUSE_MAP` value 全部对齐到 HangupCause 枚举
  - `at_client.py` 中 `local_clearing` → `manual_hangup`、`device_error` 兜底 → `network_out_of_order`
  - `tests/test_modem_dial.py` 断言更新；`tests/modem_serial/test_drivers.py` 断言更新；新建的 SerialATClient 测试断言更新
  - `call-state-machine` spec delta 加新 Requirement「hangup_cause 单一来源」，明确 `isales_common.enums.HangupCause` 为唯一权威枚举，禁止平行词汇表；scenarios 列出 GSM-side / 应用层完整枚举值集合，并把 `manual_hangup` 排除出 retry-followup 重试列表
- [ ] 4.4 验收 log（含 PR #1/#2/#3 commit hash + 真硬件 5 通通话记录 + 完整 `pytest` 结果）写到 `openspec/changes/impl-real-at/acceptance.md`（与 impl-deploy-macos 12.x acceptance 同格式）—— **依赖 3.4 真硬件验收完成**

## 5. 收尾

- [ ] 5.1 跑 `openspec archive impl-real-at` 把 change 归档到 `openspec/changes/archive/2026-MM-DD-impl-real-at/`
- [ ] 5.2 更新 `openspec/v1-roadmap.md`：把 A1 状态从 "待开" 标记为 "已归档"，给下一步 A2 `arch-cloud-edge-split` 留 propose 指引
