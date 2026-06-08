## ADDED Requirements

### Requirement: 云-边控制面 gRPC bidi keepalive + idle-stream 抗性

Cloud-edge 控制面 gRPC bidi stream SHALL 通过 HTTP/2 keepalive ping
保持 liveness，并 SHALL 与中间网络层（Aliyun ECS 安全组 / SLB 七层
模式 / 客户机 NAT / 公司防火墙）的 stateful idle-cleanup 兼容。
本 Requirement 与既有 "云-边控制面 gRPC bidi 连通性" Requirement 并列，
**不**替代后者；它定义 transport-layer keepalive 的 Producer / Consumer
双方契约。

服务于 v1.0 商用形态（Windows 客户机在不可控网络环境下需要维持长 bidi
stream）+ dev / QA 形态（mac dev 机连真 cloud engine 进行 e2e 演练），
在 `macos-artc-pyobjc-binding` archive 时发现的"stream 1 ms 即被 cut"
问题（2026-05-19）需要本 Requirement 解决。

#### Scenario: edge gRPC client 启用 HTTP/2 keepalive 默认参数

- **WHEN** edge `CloudEdgeGrpcClient` 创建 gRPC channel
- **THEN** channel SHALL 通过 `grpc.aio.insecure_channel(endpoint,
  options=...)` 传入以下 keepalive 参数：
  - `grpc.keepalive_time_ms = 30000`
  - `grpc.keepalive_timeout_ms = 10000`
  - `grpc.keepalive_permit_without_calls = 1`
  - `grpc.http2.max_pings_without_data = 0`
  - `grpc.http2.min_time_between_pings_ms = 10000`
  - `grpc.http2.min_ping_interval_without_data_ms = 10000`
- 即：edge 每 30 秒发一次 HTTP/2 PING，10 秒未收 ACK 视为 transport
  失败、走既有的 `_connect_loop` reconnect 路径
- 即使 stream 上当前无 RPC 活动，keepalive ping SHALL 照样进行（cloud-edge
  控制面大部分时间是 idle）

#### Scenario: cloud gRPC server 对称配置不踢 client ping

- **WHEN** cloud `CloudEdgeGrpcServer.start` 创建 `grpc.aio.server`
- **THEN** server SHALL 传入以下 options：
  - `grpc.keepalive_time_ms = 30000`
  - `grpc.keepalive_timeout_ms = 10000`
  - `grpc.keepalive_permit_without_calls = 1`
  - `grpc.http2.max_ping_strikes = 0`
  - `grpc.http2.min_time_between_pings_ms = 10000`
  - `grpc.http2.min_ping_interval_without_data_ms = 10000`
- **MUST NOT** 把 edge 的 30s 周期 ping 视为"过频"而 GOAWAY / RST_STREAM
  踢掉 stream（即 `max_ping_strikes = 0` 强制不计数）
- 即：cloud 与 edge 双向 keepalive 周期一致、互不踢，保证长 bidi stream
  在外部中间层有 stateful idle-cleanup 时仍存活

#### Scenario: stream 上线 + 上线时分别打 INFO 日志

- **WHEN** edge client 的 `_run_one_stream` 中 `call.initial_metadata()` 返回成功
- **THEN** SHALL 在 `_connected.set()` 之前打 INFO 日志 `cloud_edge_stream_connected`，
  携带 `endpoint` extra
- **WHEN** cloud server 的 `_handle_bidi` 中 `send_initial_metadata` 返回成功
- **THEN** SHALL 在 `_register_stream` 之前打 INFO 日志 `cloud_edge_stream_opened`，
  携带 `edge_device_id` extra
- 这两条 INFO 日志 SHALL 让 dev / ops 在 cloud-edge 稳定性诊断时**直接**
  看到 stream 真上线时刻，而不是只能间接看 `cloud_edge_stream_error` WARNING

#### Scenario: smoke 工具支持长时间 soak 验证

- **WHEN** `scripts/cloud_edge_smoke.py --soak <N>` 启动
- **THEN** SHALL 连接 cloud endpoint，stream 上线后每 30 秒发送一次 Heartbeat
  保持流活，每次 stream cut 记录 (start_ts, end_ts, lifetime_s)
- **THEN** SHALL 在 `N` 秒后退出，stdout SHALL 打印分布表（成功 stream 数 /
  总尝试 / p50 / p95 / max / min lifetime）
- **WHEN** 也传入 `--report-file <path>`
- **THEN** SHALL 把上述统计以 JSON 写到文件，供后续 acceptance.md 自动汇入

#### Scenario: cloud-side RUNBOOK 标明 50051 idle-timeout 配置

- **WHEN** ops 部署 / 排查 cloud-edge gRPC
- **THEN** `deploy/RUNBOOK-cloud.md` SHALL 含一节"50051 TCP idle-timeout
  配置"，列：
  - Aliyun ECS 安全组 inbound 50051 TCP 不要配 stateful idle-cleanup（如
    控制台提供此选项）
  - 如接入 SLB / WAF 在 :50051 前面，七层模式 idle-timeout SHALL ≥ 60 min；
    且 SLB SHALL 支持 HTTP/2 长连接
  - 验收命令：`cloud_edge_smoke.py --soak 600 --report-file report.json`
    应输出 p95 ≥ 300 秒

#### Scenario: 部署顺序：先升 server 再升 client

- **WHEN** rollout 本 Requirement 引入的配置
- **THEN** SHALL 先升级 cloud `isales-engine`（接受新 ping 行为）→ 再升级
  edge `isales-telephony`（开始发 ping）
- **MUST NOT** 反序（旧 server 默认 `max_ping_strikes` 大于 0，新 client
  30s ping 会被踢）
