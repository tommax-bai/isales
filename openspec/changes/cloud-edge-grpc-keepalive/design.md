## Context

iSales v1.0 cloud-edge 控制面 = cloud-side `isales-engine` gRPC server
`:50051` + edge-side `CloudEdgeGrpcClient` 维持的长 bidi stream。Stream
携带 `DialCommand` / `DialAck` / `CallEvent` / `HardwareAlert` / `Heartbeat`
等控制帧；audio data 走 Aliyun RTC PaaS（另一套 UDP 通道，不在本 change 范围）。

`arch-cloud-edge-split` 实装 client / server 时使用 `grpc.aio.insecure_channel`
+ `grpc.aio.server` 默认配置 —— **无 HTTP/2 keepalive ping**。在直连内网或
testbench 环境下没问题，但 2026-05-19 真云 smoke 暴露：mac dev 机 → ECS
`121.89.85.150:50051` 的 bidi stream 每次握手成功后 ~1 ms 即被 cut（详见
`archive/2026-05-19-macos-artc-pyobjc-binding/acceptance.md`）。

约束：

- 不能改 gRPC `.proto` / wire-format（spec 锁定）
- 不能改 `RtcSession` ABC（已 archive，spec 锁定）
- 不能改 edge orchestrator dev/prod 分支结构（已 archive）
- keepalive 参数必须 client / server 对称、互相兼容（否则 server-side
  `max_ping_strikes` 限制会反过来把 client 踢掉）
- v1.0 商用客户端在客户机环境（家庭 / 公司 NAT），中间层行为更不可控，
  必须 server 侧也允许频繁 ping

## Goals / Non-Goals

**Goals**

- cloud-edge bidi stream 在外部到 ECS 的网络路径上**至少存活 5 分钟**（短
  TTL keepalive 周期 + 服务侧不踢）
- `cloud_edge_smoke.py --soak 600` 报 p95 stream 存活 ≥ 5 分钟
- `macos-artc-pyobjc-binding §3.9` 的真云 e2e（拨真手机 + AI 开场白 + barge-in）
  在 cloud-edge-grpc-keepalive 落地后能跑得通
- 真云 smoke 失败的诊断信号清晰：dev / ops 能从 INFO 日志看到 stream 真上线 +
  ERROR 日志区分 transport / auth / handler 三类失败

**Non-Goals**

- 不解决 Aliyun RTC PaaS UDP 层连通性（audio plane 独立）
- 不改 reconnect 主流程（exponential backoff 已经 work，本 change 只补 keepalive）
- 不实施 durable pending-buffer 强一致语义（`SqliteEventBuffer` 已存在，本 change
  不动）
- 不做 server-side 分布式 stream tracking（A2 单 engine 实例假设不变）
- 不做 Aliyun 控制台自动化配置（部署侧任务给 ops manual）

## Decisions

### Decision 1：keepalive 参数双向对称、30s 周期、10s 超时

**选**：client / server 都用 `grpc.keepalive_time_ms = 30000` +
`grpc.keepalive_timeout_ms = 10000` + `keepalive_permit_without_calls = 1`。
含义：每 30s 发一次 HTTP/2 PING，10s 内必须收到 PING ACK，否则视为 transport
失败（client 进 reconnect，server 显式 close stream）。`permit_without_calls=1`
让无活动流的纯心跳也能跑（cloud-edge 大部分时间是 idle）。

**否决**：60s 周期 / 20s 超时（节省带宽，但 Aliyun stateful 设备的 idle GC
window 经验值在 30-60s 之间，60s 边界太险）；10s 周期 / 5s 超时（带宽 OK 但
ping ACK 抖动会触发 false-positive cut）。

**Why**：30 / 10 是 gRPC 社区在 GCP / AWS / 阿里云上反复测出的"穿透 stateful
NAT / firewall" 工作点。带宽开销可忽略（HTTP/2 PING 9 字节 + ACK 9 字节，
每分钟两轮 = 36 字节/分钟，远小于 heartbeat 自身的 ~200 字节）。

### Decision 2：`min_time_between_pings_ms = 10000`，`max_ping_strikes = 0`

**选**：client 设 `grpc.http2.min_time_between_pings_ms = 10000`；server 设
`grpc.http2.max_ping_strikes = 0`（不踢任何 ping）+ `min_time_between_pings_ms
= 10000`。

**否决**：默认 `min_time_between_pings_ms = 5 min`（gRPC 默认值）会把 30s 周期
的 keepalive ping 视作"过频" → server 自动 GOAWAY + reset stream。这是 gRPC
官方 default 的"反 DDoS"逻辑，但对 cloud-edge 控制面是反优化。

`max_ping_strikes = 0` 意思"不计 strike，永远不主动踢 client"。安全场景：
cloud-edge 是受信对端（凭 JWT auth），不需要 server 主动惩罚。

**Why**：client / server 必须互相兼容。如果 client 30s ping、server 期望
≥ 5 min，server 会踢；如果 server 容忍但 client 期望 5 min ack、5s 不到就
认 transport 死，无意义。

### Decision 3：保留现有 reconnect / 指数退避 + 不动 send_buffer

**选**：`CloudEdgeGrpcClient._connect_loop` 的 `initial_backoff_s=1, max=30,
factor=2` 保持不变；keepalive 是正交修复，不替代 reconnect。`SqliteEventBuffer`
durable buffer 已实装，pending Edge2Cloud 帧会在 reconnect 后 `_flush_buffer`
正常 drain，不需要本 change 改进。

**否决**：换成 fixed backoff（让 reconnect 更激进） / 给 reconnect 加 jitter
（解决 thundering-herd，但 v1.0 单 edge 实例不会有 herd）。

### Decision 4：INFO 日志补 `cloud_edge_stream_connected` / `cloud_edge_stream_opened`

**选**：client 在 `await call.initial_metadata()` 之后 `_connected.set()` 之前
加一个 `logger.info("cloud_edge_stream_connected")`；server 在 `await
context.send_initial_metadata([])` 之后 `_register_stream` 之前加
`logger.info("cloud_edge_stream_opened")`，带 `edge_device_id` extra。

**否决**：只加 DEBUG（dev 默认看不到，ops 也调不到 DEBUG 级别）；不加日志
（symmetric to `cloud_edge_grpc_server_started` 已经在 startup 时打了，所以
streams 应该有相应级别日志）。

**Why**：当 2026-05-19 smoke 失败时，ops 只能从 client 侧看 `WARNING
cloud_edge_stream_error`，看不到 server 视角"stream 真上线 N 次然后死了"。这
让诊断花了大量时间猜测。补 INFO 日志后未来这种问题 5 分钟内可定位。

### Decision 5：`--soak N` smoke 模式作为持续验证手段

**选**：`scripts/cloud_edge_smoke.py --soak 600` 表示"连续跑 600 秒"，每次
stream 死掉记录 lifetime，输出 p50 / p95 / max 分布 + 总成功 stream 数。

**否决**：CI-grade soak（需要长跑 30+ min + 持续 phone smoke，cost 高）；
单次连接测试（覆盖不到 idle 段）。

**Why**：dev / ops 验证 cloud-edge 稳定性的最小可用工具；output 直接进
`archive/.../acceptance.md` 或 STATE.md。

### Decision 6：部署侧任务 manual 不做控制台自动化

**选**：`deploy/cloud/RUNBOOK-cloud.md` + `STATE.md` 补"已知坑 + 应对"段，
但不写 Aliyun OpenAPI 调用脚本调整安全组 / SLB。

**否决**：写 Terraform / aliyun CLI 自动化（v1.0 单 ECS 实例 + 单 region，
ROI 低；C2 多租户阶段再做）。

**Why**：v1.0 部署是 manual deploy，安全组改动由运维一次性做。文档化坑位
+ 期望配置比自动化更稳。

## Risks / Trade-offs

- **[Risk] keepalive ping 把 Aliyun 监控误判为"高频请求"**：可能性低，gRPC
  ping 是 HTTP/2 内部帧，不计入 RPC 计数。Mitigation：在 RUNBOOK 里写明
  "30s ping ≠ 高频 RPC"。
- **[Risk] server `max_ping_strikes=0` 让恶意 client 高频 ping ddos server**：
  cloud-edge 凭 JWT 信任 + 单实例只接受少量受信 edge，攻击面接近零。可接受。
- **[Trade-off] 30s 周期意味着断连最坏要 40s 检测出来**：当前 reconnect 流程
  本来就是错误驱动的，新加的 keepalive 在没有传统 transport 错误时提供
  liveness floor。Loss 一个 30s 窗口的 DialCommand 路由不可避免（heartbeat
  + edge 端的 SqliteEventBuffer 在 Edge→Cloud 方向已 cover，Cloud→Edge
  方向当前 spec 只保证 at-least-once via cloud-side retry queue）。
- **[Risk] Aliyun 中间层可能真的连 keepalive ping 都拦**：这种情况
  需要 console 调整（开 long-lived TCP whitelist）。本 change 通过加日志 +
  soak 工具确保问题能快速发现。

## Migration Plan

无 schema migration。纯代码 + 部署文档调整。

回滚：删除 channel / server options 即可还原默认行为；keepalive 是
backwards compatible，不影响已部署的旧 client / server（旧 client 不发 ping，
新 server 不会因此踢；新 client 发 ping，旧 server 当作 unknown frame ignore）。

部署顺序：先升 server（接受新 ping 行为）→ 再升 client（开始发 ping）。
若同时升，gRPC 协议本身不要求顺序。

## Open Questions

1. Aliyun ECS 安全组对 `:50051` 是否真有 stateful idle-cleanup？需 console 确认。
2. 未来商用 Windows 客户端在客户机网络下的中间层行为如何？应在 D1 部署阶段做
   一次 baseline soak（不在本 change 必做范围内，但建议跟 D1 联动）。
