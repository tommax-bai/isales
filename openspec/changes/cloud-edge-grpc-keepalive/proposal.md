## Why

2026-05-19 真云 smoke 在归档 `macos-artc-pyobjc-binding` 时暴露：
cloud-edge gRPC bidi 在 mac dev 机 → ECS `121.89.85.150:50051` 的路径上
**每次 stream 建立后 ~1 ms 被 cut**（`UNAVAILABLE: Socket closed`），导致 edge
daemon 永远 reconnect 拿不到一段稳定窗口，cloud `Cloud2Edge.dial` 无法路由到
edge。Same code path 在 ECS-localhost 内 100% reliable，故 engine /
servicer 代码本身没问题，问题位于**外部到 ECS 50051 的网络中间层** —— 高度
怀疑 Aliyun ECS 安全组 stateful tracking、Aliyun SLB（如有）idle-cleanup、
或网络中其他 stateful 设备杀掉 idle bidi stream。

短期手动验证：

- TCP 三次握手 100% 成功（`nc -zv` / `ss -tn` 都能看到）
- HTTP/2 `call.initial_metadata()` 返回 OK
- 紧接着 `async for response in call:` 第一次读时 `UNAVAILABLE: Socket closed`
- 加 `grpc.keepalive_time_ms=30000` / `permit_without_calls=1` /
  `min_time_between_pings_ms=10000` 等 channel options **不缓解**
- `device-id=edge-01` / `edge-mac-dev-01` / `smoke-loop` 行为一致 → 与 engine
  identity 路由无关
- ECS-localhost smoke 3/3 → engine + 配置 OK

商用 Windows 客户端在客户机网络也会面对类似的中间设备问题（家庭路由器 NAT
keepalive / 公司防火墙 stream idle-kill）。当前 `transport/grpc_client.py`
使用 `grpc.aio.insecure_channel(endpoint)` 无 channel options + 无显式
HTTP/2 keepalive → 任何中间状态设备都会随机干掉这条 stream。这是 v1.0
商用稳定性 blocker，**必须**在 Windows 客户端真正下到客户机环境前修。

## What Changes

### `isales-telephony` 侧（边缘 gRPC client）

- `transport/grpc_client.py::CloudEdgeGrpcClient._run_one_stream` 创建
  `grpc.aio.insecure_channel(endpoint)` 时新增以下 channel options：
  - `grpc.keepalive_time_ms = 30000`
  - `grpc.keepalive_timeout_ms = 10000`
  - `grpc.keepalive_permit_without_calls = 1`
  - `grpc.http2.max_pings_without_data = 0`
  - `grpc.http2.min_time_between_pings_ms = 10000`
  - `grpc.http2.min_ping_interval_without_data_ms = 10000`
- 不修改 `_connect_loop` 现有 exponential backoff 行为；keepalive 与
  reconnect 是正交的。
- 新增 `cloud_edge_stream_connected` INFO 日志（在 `call.initial_metadata()`
  返回之后），让 dev / ops 可以肉眼看到 stream 真上线时刻，而不是只看到
  WARNING `cloud_edge_stream_error` 的负面信号。

### `isales-engine` 侧（云端 gRPC server）

- `transport/grpc_server.py::CloudEdgeGrpcServer.start` 用 `grpc.aio.server`
  时传入对称的 server-side channel options：
  - `grpc.keepalive_time_ms = 30000`
  - `grpc.keepalive_timeout_ms = 10000`
  - `grpc.keepalive_permit_without_calls = 1`
  - `grpc.http2.max_ping_strikes = 0`（允许 client 高频 ping）
  - `grpc.http2.min_time_between_pings_ms = 10000`
- 新增 `cloud_edge_stream_opened` INFO 日志（在 `send_initial_metadata` 之后），
  帮助 cloud-side 区分"stream 建立成功"和"servicer 后续异常"。

### Aliyun 控制台 / 部署侧

- 在 `deploy/cloud/RUNBOOK-cloud.md` § 网络配置补一节"50051 TCP idle-timeout
  配置"：检查 Aliyun 安全组**不要**对 `:50051` 配 stateful idle-cleanup（如果
  console 提供这个配置）；如果接 SLB / WAF，要把 idle-timeout 调到 ≥ 60 min
  且**确认** SLB 支持 HTTP/2 长连接（七层模式）。
- 在 `deploy/cloud/STATE.md` § "Cloud-edge gRPC end-to-end smoke" 补"已知坑：
  外部 mac → ECS 50051 间歇性 stream cut；Windows / Linux 客户端在不同 ISP
  / NAT 下表现差异大"。

### 测试

- `isales-telephony/tests/test_grpc_client.py` 新增：mock 一个会立即 EOF 的
  stream，验证 client 进 reconnect + 在 keepalive timeout 后正确分类为
  TransientFailure 而不是永久错误。
- `isales-telephony/scripts/cloud_edge_smoke.py` 新增 `--soak N` 参数：连
  续 N 秒持续跑，统计 stream 维持时间分布（p50 / p95 / 最长存活）。
- Manual smoke：用 `--soak 600` 跑 10 分钟，verify 至少 1 个 stream 保持
  ≥ 5 分钟（说明 keepalive 真把中间层 idle-kill 抑制住了）。

### macos-artc-pyobjc-binding 收尾

- 本 change 落地 + 真云 smoke 稳定后，重跑 `macos-artc-pyobjc-binding/tasks.md
  §3.9` 的拨真手机 + AI 开场白 + barge-in 实测，结果补到
  `openspec/changes/archive/2026-05-19-macos-artc-pyobjc-binding/acceptance.md`
  的 "Deferred follow-up" 段后做收尾。**不需要**重 archive
  `macos-artc-pyobjc-binding`。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `service-communication`：在既有 "云-边控制面 gRPC bidi" Requirement 后并列
  新增 "gRPC bidi keepalive + idle-stream resilience" Requirement，明确双向
  keepalive 参数 + Aliyun 部署侧配置要求；不修改既有 Requirement 主体。

## Impact

**受影响代码：**

- `isales-telephony/isales_telephony/transport/grpc_client.py` — 加 channel
  options + INFO 日志（约 ~15 行）。
- `isales-engine/isales_engine/transport/grpc_server.py` — 加 server options
  + INFO 日志（约 ~15 行）。
- `isales-telephony/scripts/cloud_edge_smoke.py` — 加 `--soak` 模式（约
  ~30 行）。
- `isales-telephony/tests/test_grpc_client.py` — 加 idle-EOF reconnect 测试
  + keepalive options 在 channel 上正确设置的断言（约 ~80 行）。
- `deploy/cloud/RUNBOOK-cloud.md` § 网络配置补一节。
- `deploy/cloud/STATE.md` § "Cloud-edge gRPC end-to-end smoke" 补"已知坑"段。

**不受影响：**

- `isales-common` / 任何 proto schema（wire-format 不变）
- `isales-api` / `isales-scheduler` / `isales-worker`（不走 gRPC bidi）
- `isales-web` / `MacosArtcPyObjCSession` / `WindowsRtcSession`（这是 transport
  层修复，不动 RtcSession ABC / 实装）
- 已经 archive 的 `arch-cloud-edge-split` / `macos-artc-pyobjc-binding` / 
  `windows-artc-pybind11`

**APIs / 协议：** cloud-edge gRPC `.proto` 不变；channel options 是 client /
server 本地配置，不进 wire-format。

**依赖：** 不引入新 Python 包。`grpcio` 内置 HTTP/2 keepalive 支持。

**风险：**

- gRPC 默认 keepalive `permit_without_calls=False` 是为了避免 server 收到
  无活动流的 ping 风暴；我们打开它是因为 cloud-edge 是少量长链接，不会暴增。
- 如果 Aliyun 网络层真在用 stateful firewall 杀连接（推测但未确认），
  client-side keepalive 可能仍 not enough，需 console 侧调整。这种情况下
  本 change 是必要但**不充分**条件 —— 部署侧任务一定要跟上。

## Open Questions

1. Aliyun ECS 安全组对 `:50051` 是否真有 stateful idle-cleanup？需要 console
   截图或调用 API 确认。
2. SLB 是否已 / 计划接入？如已接入，其 `:50051` 七层 vs 四层模式？idle-timeout
   配置多少？
3. Windows 客户端在不同 ISP / NAT 下的 stream cut 时间分布如何？需要先用
   `--soak` 模式跑一遍 Windows rig 拿基线数据。
