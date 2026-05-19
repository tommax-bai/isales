## 1. isales-telephony grpc_client keepalive

- [ ] 1.1 在 `isales-telephony/isales_telephony/transport/grpc_client.py::_run_one_stream` 中给 `grpc.aio.insecure_channel(endpoint)` 加 `options=` 参数，包含 keepalive_time_ms=30000 / keepalive_timeout_ms=10000 / keepalive_permit_without_calls=1 / http2.max_pings_without_data=0 / http2.min_time_between_pings_ms=10000 / http2.min_ping_interval_without_data_ms=10000
- [ ] 1.2 在 `_run_one_stream` 中 `await call.initial_metadata()` 之后 `self._connected.set()` 之前新增 `logger.info("cloud_edge_stream_connected", extra={"endpoint": self._endpoint})`
- [ ] 1.3 单元测试 `tests/test_grpc_client.py`：mock 一个 `grpc.aio.AioRpcError(UNAVAILABLE, "Socket closed")` 在 `async for response in call:` 第一次 iterate 时抛出，验证 `_connect_loop` 走 reconnect path、backoff 正确递增、log line 出现
- [ ] 1.4 单元测试 `tests/test_grpc_client.py`：mock `grpc.aio.insecure_channel` 并验证 `options=` 列表包含全部 6 个 keepalive key（防止重构时丢配置）

## 2. isales-engine grpc_server keepalive

- [ ] 2.1 在 `isales-engine/isales_engine/transport/grpc_server.py::start` 中改 `grpc.aio.server(...)` 为 `grpc.aio.server(interceptors=..., options=[...])`，options 包含 keepalive_time_ms=30000 / keepalive_timeout_ms=10000 / keepalive_permit_without_calls=1 / http2.max_ping_strikes=0 / http2.min_time_between_pings_ms=10000 / http2.min_ping_interval_without_data_ms=10000
- [ ] 2.2 在 `_handle_bidi` 中 `await context.send_initial_metadata([])` 之后 `_register_stream` 之前新增 `logger.info("cloud_edge_stream_opened", extra={"edge_device_id": identity.edge_device_id})`
- [ ] 2.3 单元测试 `tests/test_grpc_server.py`：验证 server 创建时传入正确 options（用 fixture stub `grpc.aio.server`）
- [ ] 2.4 单元测试 `tests/test_grpc_server.py`：验证 `_handle_bidi` 在 authenticate 成功后 INFO 日志包含 edge_device_id

## 3. `scripts/cloud_edge_smoke.py` --soak 模式

- [ ] 3.1 给 `cloud_edge_smoke.py` 加 `--soak N`（int seconds）参数：连接成功后不立即 stop，循环 `[heartbeat → idle 30s →]` 直到 N 秒到达或 stream cut；每次 cut 记录 (start_ts, end_ts, duration_s)
- [ ] 3.2 退出前打印分布表：成功 stream 数、总连接尝试、p50/p95/max/min lifetime（秒）、最长存活 stream 时间
- [ ] 3.3 增加 `--report-file <path>` 把上述统计写 JSON，供后续 acceptance.md 自动汇入
- [ ] 3.4 在 `scripts/README.md`（若不存在则新建）补一节"`--soak` 用法 + 期望分布（p95 ≥ 5 min）"

## 4. 部署文档 + STATE.md

- [ ] 4.1 修改 `isales/deploy/RUNBOOK-cloud.md` § 网络配置，补一节"50051 TCP idle-timeout 配置"，列：(a) 安全组 inbound 50051 TCP 不要配 stateful idle-cleanup；(b) 如接入 SLB 七层 / WebSocket / HTTP/2 模式，idle-timeout ≥ 60 min；(c) 验收命令 `cloud_edge_smoke.py --soak 600 --report-file report.json` 期望 p95 ≥ 300s
- [ ] 4.2 修改 `isales/deploy/cloud/STATE.md` § "Cloud-edge gRPC end-to-end smoke"，补"已知坑：外部 mac→ECS:50051 默认 ~1ms 杀 idle bidi，原因 = 中间层 stateful idle GC"段，引用本 change 与 archived `macos-artc-pyobjc-binding/acceptance.md`
- [ ] 4.3 (meta-repo) 跑 `openspec validate cloud-edge-grpc-keepalive --strict` 确保 spec delta 合法

## 5. 端到端 smoke + macos-artc-pyobjc-binding §3.9 收尾

- [ ] 5.1 manual smoke：升级 server + client → 跑 `cloud_edge_smoke.py --soak 600` from mac → 验证 p95 lifetime ≥ 300 秒（5 min）；记 report.json
- [ ] 5.2 manual smoke 续：mac 上起 `isales-telephony-edge --dev-no-modem`，触发 cloud-side fake_dial 拨真手机（13301035545），听 AI 开场白 + 故意打断 → 看 engine log barge-in / VAD / TTS cancel 路径
- [ ] 5.3 把 5.1 / 5.2 结果补到 `openspec/changes/archive/2026-05-19-macos-artc-pyobjc-binding/acceptance.md` 的 "Deferred follow-up" 段后做收尾。**不**重 archive `macos-artc-pyobjc-binding`
- [ ] 5.4 跑 `make test-all` 确认全 sub-repo 测试绿
- [ ] 5.5 跑 `openspec validate cloud-edge-grpc-keepalive --strict` 0 warning

## 6. archive 准备

- [ ] 6.1 写 `openspec/changes/cloud-edge-grpc-keepalive/acceptance.md`（含 soak 输出 + 拨电话 smoke + Aliyun 控制台配置确认截图 / 文字记录）
- [ ] 6.2 commit 拆分：(a) isales-telephony PR：keepalive options + log + smoke --soak + tests；(b) isales-engine PR：keepalive options + log + tests；(c) meta-repo commit：spec delta + RUNBOOK-cloud + STATE.md + 收尾 archive
- [ ] 6.3 PR review 通过后 push 两个 sub-repo + meta-repo；按 (a) → (b) → (c) 顺序部署 server → client → docs
- [ ] 6.4 跑 `openspec archive cloud-edge-grpc-keepalive`；spec delta 合进 `openspec/specs/service-communication/spec.md`
