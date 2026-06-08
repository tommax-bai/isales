## ADDED Requirements

### Requirement: 云-边控制面 — gRPC 出站超时保护

云端 `CloudEdgeGrpcServer` 的 `_ServerStream.send()` SHALL 对出站队列 `put` 操作施加显式超时（默认 5 秒，可通过 `ISALES_ENGINE_GRPC_SEND_TIMEOUT_S` 配置）；超时后 SHALL 抛 `EdgeNotConnected`，上层走既有断连清理路径。本 Requirement 补完 `arch-cloud-edge-split` 中 "出站缓冲策略" 的半连接场景兜底。

#### Scenario: Edge 半连接导致出站队列满

- **WHEN** Edge 的 gRPC bidi stream 存在但 Edge 不消费出站消息（半连接状态），导致 `_outbound` 队列（maxsize=64）堆满
- **THEN** `_ServerStream.send()` SHALL 在 `ISALES_ENGINE_GRPC_SEND_TIMEOUT_S`（默认 5.0）秒后超时，抛出 `EdgeNotConnected(edge_device_id)`
- **THEN** 上层 `RtcTelephonyClient.dial()` 收到 `EdgeNotConnected` 后 SHALL 走既有断连处理路径（finalize session、DECR 并发计数器、标记 call_record 为异常结束）

#### Scenario: 正常 Edge 消费不触发超时

- **WHEN** Edge 正常消费出站消息（队列不满）
- **THEN** `send()` SHALL 立即成功，不受超时影响（`asyncio.wait_for` 在 put 立即返回时无额外开销）

#### Scenario: 超时值可配置

- **WHEN** 部署调优
- **THEN** 运维 MAY 通过环境变量 `ISALES_ENGINE_GRPC_SEND_TIMEOUT_S` 调整超时值；默认 5.0 秒 SHALL 覆盖绝大多数网络抖动场景；MUST NOT 设为 0（会导致所有 send 立即超时）

### Requirement: 通信故障的容错 — 半连接场景

本 Requirement 扩展 `arch-cloud-edge-split` 已有的 "通信故障的容错" 场景，新增 "半连接" 故障模式：云端 engine SHALL 把「应用层不消费消息但物理 stream 仍在」的 Edge 视为断连处理，受影响的 call_session MUST 走既有 finalize 清理路径，MUST NOT 永久卡在 `init` 状态占满并发槽。

#### Scenario: Edge 半连接等同于断连

- **WHEN** Edge 的 gRPC bidi stream 物理层存在但应用层不消费消息（如 Edge 进程卡死、事件循环阻塞、消费速率远低于推送速率）
- **THEN** 云端 engine SHALL 在 send 超时后把该 Edge 视为断连（`EdgeNotConnected`）；受影响的 call_session MUST 走既有 finalize 清理路径；MUST NOT 让 session 永久卡在 `init` 状态占满并发槽

### Requirement: 多 Edge 动态路由

云端 `CloudEdgeGrpcServer` SHALL 维护 `device_id → edge_device_id` 映射，支持多个 Edge 设备并行处理通话。Engine 下发 `DialCommand` 时 SHALL 根据 `DialRequest.device_id` 动态路由到拥有该 device 的 Edge，而非硬编码发给单一 Edge。

#### Scenario: Edge 通过 Heartbeat 注册 device 映射

- **WHEN** Edge 发送 `Edge2Cloud.Heartbeat` 且 `heartbeat.devices[]` 列表非空
- **THEN** 云端 SHALL 遍历 `devices` 列表，对每个 `device_health.device_id` 更新 `_device_to_edge[device_id] = edge_device_id`
- **THEN** 映射 SHALL 允许 device 在不同 Edge 间迁移（新 Heartbeat 覆盖旧映射）

#### Scenario: Edge 断连时清理 device 映射

- **WHEN** Edge 的 gRPC bidi stream 断开（`_deregister_stream`）且该 edge 未被同名新连接替代（非 displaced）
- **THEN** 云端 SHALL 清理该 edge_device_id 拥有的所有 device 映射条目
- **WHEN** 同一 edge 重连（displaced 旧流）
- **THEN** 映射 SHALL 保留（新连接会通过后续 Heartbeat 刷新）

#### Scenario: DialCommand 动态路由

- **WHEN** `RtcTelephonyClient.dial()` 执行且 `_legacy_edge_device_id` 为空字符串（动态路由模式）
- **THEN** SHALL 调用 `grpc_server.resolve_edge_for_device(state.device_id)` 获取目标 edge
- **THEN** SHALL 用返回的 edge_device_id 调用 `send_to_edge(target_edge, Cloud2Edge(dial=dial_cmd))`
- **WHEN** `resolve_edge_for_device` 找不到映射
- **THEN** SHALL 抛 `EdgeNotConnected`，走既有断连处理路径

#### Scenario: 向后兼容 — legacy 单 Edge 模式

- **WHEN** `ISALES_ENGINE_EDGE_DEVICE_ID` 环境变量非空
- **THEN** `RtcTelephonyClient` SHALL 使用该值作为所有 DialCommand 的目标 edge（行为与本 change 之前完全一致）
- **WHEN** `ISALES_ENGINE_EDGE_DEVICE_ID` 为空字符串
- **THEN** SHALL 启用动态路由模式；Engine 启动时 MUST NOT 因该值为空而报错退出

#### Scenario: hangup 使用路由结果

- **WHEN** 通话进行中需要 hangup（barge-in / admin 手动挂断）
- **THEN** SHALL 使用 dial 阶段路由确定的 `state.edge_device_id` 发送 `CancelCommand`，MUST NOT 重新路由（避免 device 在通话期间被其他 Edge 注册导致 cancel 发错目标）