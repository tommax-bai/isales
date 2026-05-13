## Context

A1 是 v1.0 路线（10-phase 一体发布，A1 → D3）的**第一块地基**。
关键现状（提交时审计确认）：

- `modem_controller/at_client.py:36` 定义 `ATClient` Protocol：`dial / hangup / get_signal / get_iccid / get_imei`
- 同文件 `:63` 定义 `MockATClient`——返回硬编码 ICCID / IMEI / RSSI，模拟一通 5s 通话；时序由 `MOCK_DIAL_DELAY_MS / MOCK_CALL_DURATION_MS` 控制
- `modem_controller/drivers.py:63` 已定义抽象 `ModemDriver` + 三个具体子类：`A7670Driver` / `SIM800CDriver` / `QuectelUC20Driver`；`HANGUP_CAUSE_MAP` 已含 `NO CARRIER / BUSY / NO ANSWER / NO DIALTONE` 与 3GPP `+CEER` cause code 子集
- `modem_controller/serial_protocol.py:99` 定义低层 `AtClient`（**不要与 Protocol `ATClient` 混淆**）：跨串口收发 AT 命令，按行分发到响应队列与 URC 队列
- `modem_controller/main.py:39` 与 `handlers.py:53` 双处硬编码 `MockATClient`
- PR #12 12.1 已在真硬件（A7670E + 国内移动 SIM）上验证过 `ModemDriver.dial()` 跑通；阻塞点纯粹是上层胶水

**为什么需要 design.md**：A1 看似"new SerialATClient → 注入 main"，但 URC 时序、`dial()` 的并发设计（同时要立刻返回 `call_id` + 推 ATEvent 流）、env dispatch 的失败语义、状态机覆盖范围都不是显然的，要先定。

**约束**：

- 接口签名 `ATClient` Protocol **保持不变**——上游 `handlers.py / state machine / ipc_server` 不动
- 测试与开发流（CI 用 `MockATClient` 跑全 pytest）保留
- 单 modem-controller 进程同时只持有 1 个 modem 的 `SerialATClient` 实例（v1 单 PC 单 modem）
- URC handling 复用 `AtClient.urc_queue` —— 不要自己重做 framing

## Goals / Non-Goals

**Goals:**

- 落地 `SerialATClient`：实装 `ATClient` Protocol，桥接 `ModemDriver` + URC 流 → `ATEvent`
- `main.py` 按环境 dispatch（生产 = Serial、CI/dev = Mock）；线上不可静默 fall back
- `device-hardware` / `call-state-machine` spec delta 把"v1 生产 ATClient 实现"与"真硬件 URC 状态转换"固化
- 真硬件冒烟脚本 `scripts/at_smoke.py` 可作为后续运维 / D2 hardware-observability 的种子代码
- 让 A2（云-边拆分）开 proposal 时能直接说"边缘进程持 SerialATClient 实例 + 通过 gRPC 暴露 ATClient 远端接口"，不再因为没真硬件路径而推迟

**Non-Goals:**

- ASR/LLM/TTS 流式、barge-in、多角色 PK——已实装，本 change 不动
- 云-边拆分、gRPC 控制面、WebRTC 音频通道——A2 范围
- Windows 平台 backend——D1 范围
- SIM 卡热插拔事件、AT+CSQ 周期轮询告警——D2 hardware-observability 范围
- 多 modem 单进程并发——v1 单进程单 modem，多席位 = 多客户端 PC 装多个 modem-controller
- 把 `MockATClient` 改造成更逼真——本 change 反而要让 mock 路径**显式**（只在 CI/dev），不让它伪装成生产

## Decisions

### 决策 1：`SerialATClient.dial()` 的并发设计——立即返回 `call_id` + 后台 URC 翻译协程

`ATClient.dial()` 签名要求 `tuple[str, AsyncIterator[ATEvent]]`——`call_id` 立即可拿（IPC 层马上 ack），事件流由 caller 异步消费。

**采用方案**：

```python
async def dial(self, number: str) -> tuple[str, AsyncIterator[ATEvent]]:
    call_id = uuid.uuid4().hex[:12]
    # ModemDriver.dial() 仅发 ATD<n>; 等 OK ack；URC 由 AtClient.urc_queue 推
    ack = await self._driver.dial(number, timeout=ATD_ACK_TIMEOUT_S)
    if not ack.connected:
        async def failed_stream():
            yield ATEvent("remote_hangup", call_id, cause=ack.hangup_cause or "device_error")
        return call_id, failed_stream()
    return call_id, self._urc_stream(call_id)
```

其中 `_urc_stream()` 是 async generator：

- 监听 `self._at.urc_queue.get()`（已在 `AtClient.__aenter__` 启动的 URC 分流任务里推送）
- `CONNECT` URC（或 `+CIEV: "CALL",1`，依 vendor）→ `yield ATEvent("connected", call_id)`
- `NO CARRIER` / `BUSY` / `NO ANSWER` / `+CEER` cause → 映射 `HANGUP_CAUSE_MAP` → `yield ATEvent("remote_hangup", call_id, cause=...)` → return（结束 generator）
- `hangup()` 触发 → 推一个 sentinel 给 URC 通道 → `yield ATEvent("remote_hangup", call_id, cause="local_clearing")` → return

**为什么不直接 `await driver.dial()` 等到 CONNECT 再返回 `call_id`**：当前 `A7670Driver.dial()` 已经"ATD ACK 返回即 connected=True"，把真"connected"等到 URC——这是 spec § "拨号期间状态" 要求（ATD 成功 ACK 仅意味着指令被接受，CONNECT URC 才是真接通）；上层 IPC 已经设计为先 ack `call_id`、后异步推 `connected` 事件，这个分两阶段的设计本来就是为真硬件预留的，mock 也在这么走（先返回 `call_id`，1s 后流出 `connected`）。

**替代方案**：

- (A) `dial()` 阻塞到 CONNECT URC——破坏 IPC 早 ack `dial_id` 语义、把"拨号 ACK ↔ 接通"两个事件捏成一个，状态机 `DIALING` 状态变没意义。**否决**。
- (B) 让 `ModemDriver` 持有 URC 翻译——`ModemDriver` 是 vendor 适配层，应保持薄；URC → `ATEvent` 是 ATClient Protocol 的语义粒度。**否决**。

### 决策 2：`ModemDriver.dial()` 的修正——不再吞 URC

当前 `A7670Driver.dial()` 注释说"OK 即 connected=True"，这条**留作 ACK 校验语义**：在 `SerialATClient.dial()` 里把 `DialResult.connected` 解读成"ATD 命令被接受"，不是"通话真接通"。**不修改 `ModemDriver.dial()` 接口**——保持向后兼容（PR #12 12.1 跑过的真硬件回归不破坏）；仅在 `SerialATClient` 这一层重新定义这条返回值的语义。

**实施细节**：`SerialATClient.__init__` 时调 `detect_driver(at, hint=os.environ.get("ISALES_MODEM_DRIVER", ""))` → `await driver.init()`（ATE0 / CMEE / CLIP）→ 之后所有 dial / hangup 走该 driver。

### 决策 3：`main.py` env dispatch 与失败语义

```python
def _make_at_client() -> ATClient:
    tty = os.environ.get("ISALES_MODEM_SERIAL_PATH")
    if tty:
        return SerialATClient.create_from_tty(tty)  # 工厂方法，里面 open serial + AtClient + detect_driver
    if os.environ.get("ISALES_ALLOW_MOCK_AT") == "1":
        logger.warning("modem-controller using MockATClient (dev/CI mode)")
        return MockATClient()
    raise RuntimeError("ISALES_MODEM_SERIAL_PATH required; set ISALES_ALLOW_MOCK_AT=1 only for dev/CI")
```

**线上不会静默走 Mock**——`ISALES_ALLOW_MOCK_AT=1` 必须显式开。CI 流水线 / 单元测试在 `pytest.ini` env 段设置 `ISALES_ALLOW_MOCK_AT=1`；生产 systemd unit / launchd plist 必填 `ISALES_MODEM_SERIAL_PATH` 且**不**带 `ISALES_ALLOW_MOCK_AT`。

`SerialATClient.create_from_tty` 失败（设备不存在 / 权限不够 / 串口被占）→ 抛异常 → `main.py` 不 catch → 进程 exit 非零 → systemd / launchd 重启。

**替代方案**：

- (A) 自动 detect tty（`pyserial.tools.list_ports.comports()` 取第一个 GSM modem）——多 modem 环境下不确定性强，PR #12 已踩过坑；显式 `ISALES_MODEM_SERIAL_PATH` 简单可控。**否决**。

### 决策 4：spec delta 范围—— `device-hardware` + `call-state-machine` 各加一条 Requirement

**`device-hardware`**：新增 Requirement「ATClient 实现策略」——SerialATClient 为 v1 生产实现 + MockATClient 限 CI/dev + main 按 env 严格 dispatch + 不可静默回退；补 URC → `ATEvent` 翻译契约（CONNECT / NO CARRIER / BUSY / NO ANSWER + `+CEER` cause code 的 hangup_cause 映射）。

**`call-state-machine`**：现有 § "关键状态转换" scenario 是与具体硬件无关的状态层契约，**不改**。新增 Requirement「真硬件 URC 驱动状态转换」——补一组 scenario，约束 ATD ACK 到达后状态停留在 `dialing`、CONNECT URC 到达才转 `in_call`、`NO CARRIER`/`BUSY`/`NO ANSWER` URC 到达转回 `idle` 且 `hangup_cause` 与 `HANGUP_CAUSE_MAP` 一致。

**为什么不在 `device-hardware` § "AT 命令通道" 上 MODIFIED**：现行该 Requirement 只描述"通过 ttyUSB 发 AT 命令"，没下沉到"哪个类实装 ATClient Protocol"。本 change 是新增"实现层契约"，ADDED Requirement 比 MODIFIED 干净，避免动既有 scenario 行号 / 上下文。

### 决策 5：测试策略

- **单元测试**：用 pty + 假 URC stream 喂 `SerialATClient`，断言它把 `CONNECT` URC 翻译成 `ATEvent("connected", ...)` 等；覆盖 `NO CARRIER` / `BUSY` / `NO ANSWER` / `+CEER 17/18/41` 几条路径
- **集成测试**：`scripts/at_smoke.py` 真硬件手工跑——给定 `ISALES_MODEM_SERIAL_PATH` + 拨号号码（如自己的手机号），观察 ATEvent 序列 + 通话能不能接通
- **回归**：CI 跑 pytest 时 `ISALES_ALLOW_MOCK_AT=1` 走 MockATClient，行为与 stage-2 一致；新增的 `SerialATClient` 单元测试走 pty
- **不做**：自动化端到端真硬件 CI——拨号 SIM 真号有运营商成本 + 法规风险，留运维抽查

## Risks / Trade-offs

- **[URC 时序差异]** SIM800C / Quectel UC20 vs A7670 在 `CONNECT` / `NO CARRIER` 推送时机不同 → 单测覆盖 A7670 完整路径，SIM800C / Quectel 子类 best-effort（v1.0 主要 SKU 是 A7670）；新 vendor 上需要新增 driver 子类 + 单测，归 D2 hardware-observability 范畴
- **[ATD ACK 与 CONNECT URC 之间状态停留]** 状态机在 `dialing` 状态可能停留 30s+（拨号到对方接听）→ scheduler 的"call timeout"已经定义在 60s（`call-state-machine` § "长时间无进展挂断"），不冲突；但要确保 IPC 层不会因为 30s 内没事件就 timeout
- **[`MockATClient` 仍被引用]** 取消默认兜底后，handlers.py 显式注入路径要更新；旧测试可能默认依赖兜底 → 改测试 fixture 显式传 `MockATClient()`
- **[真硬件单元测试覆盖不全]** PR #12 12.1 只跑过 A7670E + 一次通话 → A1 落地后再做一轮"5 通连续呼出 / 5 通连续被叫"硬件抽查，归 12.x acceptance 续接
- **[serial 串口竞争]** 同一 `/dev/ttyUSB*` 被两个进程同时打开 → fcntl flock 在 `SerialATClient.create_from_tty` 里加，失败抛 `BusyDeviceError`；deploy 层确保 modem-controller 单实例

## Migration Plan

A1 是新增能力，不破坏现状（mock 路径继续可用）：

1. PR 1：新增 `SerialATClient` + 单元测试（pty）；CI 全绿
2. PR 2：`main.py` env dispatch + handlers.py 取消默认 mock；deploy/linux + deploy/macos 的 systemd / launchd 补环境变量；CI 加 `ISALES_ALLOW_MOCK_AT=1` 守护
3. PR 3：`scripts/at_smoke.py` + README 部署步骤
4. 真硬件冒烟：A7670E + 国内 SIM，跑 `at_smoke.py` 拨自己手机，5 通连呼，记录 ATEvent 时序 + hangup_cause 准确性
5. Spec deltas（`device-hardware` + `call-state-machine`）归档

**回滚**：把 `main.py` 改回硬编码 `MockATClient()` 即可——`SerialATClient` 不删，只是不挂到 main；下游 IPC / 状态机 / handlers 不感知。

## Open Questions

- **SIM800C / Quectel UC20 真硬件覆盖**：v1.0 主要 SKU 是 A7670（USB Audio Class），SIM800C 走纯 AT 无 USB 音频，跟 v1.0 音频架构对不齐；Quectel UC20 vs UC25 / EC25 选型未定。是否在 A1 范围内删掉 SIM800C / Quectel driver 子类 + HANGUP_CAUSE_MAP 里相关 entry？还是留作 future SKU 占位？→ **倾向保留**（代码已写、删了只是减 ~30 行，留着不影响 A1 主路径），不在 spec 上承诺
- **`+CIEV: "CALL",1` vs `CONNECT` 哪个作为接通信号**：A7670 实测两者都会推、`+CIEV` 略早；先按 `CONNECT` 实现，真硬件冒烟阶段如果发现 latency 差 > 100ms，再切到 `+CIEV`
- **`local_clearing` cause 值与既有 spec 的对齐**：当前 mock 用 `local_clearing`，`HANGUP_CAUSE_MAP` 未列；需要在 `call-state-machine` spec 的 hangup_cause enum 加上 `local_clearing`，或者改名 `user_hangup` 统一。→ 留在 specs delta 编写阶段对齐
