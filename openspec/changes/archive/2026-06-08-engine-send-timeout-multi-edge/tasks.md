# Tasks

> 代码已于 engine `cf59640`（2026-06-08）实装并部署到 ECS，boot logs clean。本 tasks.md 为归档补全（该 change 此前缺 proposal/tasks，仅有 design.md）。

## 1. gRPC 出站队列超时保护
- [x] 1.1 `settings.py` 新增 `engine_grpc_send_timeout_s: float = 5.0`（env `ISALES_ENGINE_GRPC_SEND_TIMEOUT_S`）
- [x] 1.2 `transport/grpc_server.py` `_ServerStream.send()` 用 `asyncio.wait_for` 包裹 `put()`，超时抛 `EdgeNotConnected`
- [x] 1.3 `main.py` 构造 `CloudEdgeGrpcServer` 时链式传入超时值

## 2. 多 Edge 动态路由
- [x] 2.1 `CloudEdgeGrpcServer._device_to_edge: dict[int, str]` 映射 + Heartbeat 注册 + 断连清理
- [x] 2.2 `resolve_edge_for_device(device_id) -> str`，未命中抛 `EdgeNotConnected`
- [x] 2.3 `rtc_telephony.py` `_edge_device_id` → `_legacy_edge_device_id`，`dial()` 按空/非空切换 legacy/动态路由
- [x] 2.4 `_CallState` 新增 `edge_device_id` 字段供 hangup 使用

## 3. 向后兼容 + 部署
- [x] 3.1 `ISALES_ENGINE_EDGE_DEVICE_ID` 非空走 legacy；现有测试（edge-1）继续通过
- [x] 3.2 部署到 ECS（cf59640，2026-06-08），boot logs clean
