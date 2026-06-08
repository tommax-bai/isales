# engine-send-timeout-multi-edge

## Context

- iSales v1.0 cloud-edge 控制面：cloud-side `isales-engine` gRPC server + edge-side `CloudEdgeGrpcClient` 维持长 bidi stream
- `arch-cloud-edge-split` 设计假设 "A2 assumes single edge"（settings.py 注释），`RtcTelephonyClient._edge_device_id` 是单值，所有 DialCommand 都发给同一个 Edge
- `_ServerStream.send()` 内部用 `asyncio.Queue(maxsize=64)` 缓冲出站消息，`put()` 无超时。如果 Edge "半连接"（stream 存在但不消费），put 永久阻塞，session 僵死占满并发槽
- 实测发现：Engine 消费 Redis `engine:dial` 队列中的旧消息后，如果 Edge 未响应，call_record 卡在 `init` 状态永不结束
- 同时产品需要支持多个 Edge 设备并行处理 leads，单值 `_edge_device_id` 成为瓶颈

## Goals

1. `_ServerStream.send()` 加显式超时兜底，防止 session 因 Edge 半连接而僵死
2. 支持多 Edge 并行：根据 `device_id` 动态路由 DialCommand 到拥有该 device 的 Edge
3. 向后兼容：现有单 Edge 部署无需改配置即可正常工作

## Non-Goals

- 不改 protobuf schema（`cloud_edge.proto` 不变）
- 不改 scheduler 选 device 逻辑（scheduler 已在云内 PG 选好 device_id）
- 不做 Edge 负载均衡（路由是确定性的：device 属于哪个 Edge 就发给谁）
- 不做 Edge 故障自动迁移（device 换 Edge 需要物理重新插拔）

## Decisions

### Decision 1: gRPC 出站队列超时保护

问题：`_ServerStream._outbound` 队列 `maxsize=64`，`put()` 无超时。Edge 半连接时 put 永久阻塞。

方案：
- `_ServerStream.send()` 用 `asyncio.wait_for(self._outbound.put(message), timeout=self._send_timeout_s)` 包裹
- 超时后抛 `EdgeNotConnected(edge_device_id)`
- 上层 `RtcTelephonyClient.dial()` 已有 `EdgeNotConnected` 处理逻辑，会正确清理 session
- 超时值可配置：`ISALES_ENGINE_GRPC_SEND_TIMEOUT_S`，默认 5.0 秒
- 超时值通过 `CloudEdgeGrpcServer.__init__(send_timeout_s=...)` → `_ServerStream.__init__(send_timeout_s=...)` 链式传递

实现文件：
- `isales_engine/settings.py`: 新增 `engine_grpc_send_timeout_s: float = 5.0`
- `isales_engine/transport/grpc_server.py`: `_ServerStream.send()` 加 `asyncio.wait_for`
- `isales_engine/main.py`: 构造 `CloudEdgeGrpcServer` 时传入配置值

### Decision 2: 多 Edge 动态路由

问题：`RtcTelephonyClient._edge_device_id` 是单值，所有 DialCommand 只能发给一个 Edge。多 Edge 场景下无法并行。

方案：
- `CloudEdgeGrpcServer` 新增 `_device_to_edge: dict[int, str]` 映射
- Edge 发送 Heartbeat 时（`heartbeat.devices[]` 列表），更新 `device_id → edge_device_id` 映射
- Edge 断连时（`_deregister_stream`），清理该 edge 拥有的所有 device 映射
- 新增 `resolve_edge_for_device(device_id: int) -> str`，未找到时抛 `EdgeNotConnected`
- `RtcTelephonyClient.__init__` 中 `_edge_device_id` 重命名为 `_legacy_edge_device_id`
- `dial()` 中：`_legacy_edge_device_id` 非空走旧模式；为空则调 `resolve_edge_for_device(state.device_id)` 动态路由
- `_CallState` 新增 `edge_device_id: str` 字段，存储路由结果供 hangup 使用

实现文件：
- `isales_engine/transport/grpc_server.py`: 映射 + resolve + heartbeat 注册 + 断连清理
- `isales_engine/realtime/rtc_telephony.py`: 动态路由逻辑
- `isales_engine/settings.py`: 注释更新
- `isales_engine/main.py`: 移除空 edge_device_id 启动检查

### Backward Compatibility

- `ISALES_ENGINE_EDGE_DEVICE_ID` 环境变量非空 → 旧的单 Edge 模式（行为完全不变）
- `ISALES_ENGINE_EDGE_DEVICE_ID` 为空字符串 → 动态路由模式（根据 Heartbeat 注册的 device 映射路由）
- 所有现有测试使用 `edge_device_id="edge-1"`（legacy 模式），继续通过

## Risks / Trade-offs

- Edge Heartbeat 的 `devices` 字段需要 Edge daemon 实际发送（如果当前 Edge 版本未携带该字段，动态路由模式下会抛 `EdgeNotConnected`）。建议部署时先保留 `ISALES_ENGINE_EDGE_DEVICE_ID` 配置，待 Edge 升级后再清空切换。
- 5s send 超时在极端网络抖动下可能误判。但 `connect_timeout_s=30s` 的上层超时仍是最终兜底，5s 仅影响单次 send 操作。