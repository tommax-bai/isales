# engine-send-timeout-multi-edge

## Why

cloud-edge 控制面有两个生产缺陷：

1. `_ServerStream.send()` 的出站队列 `asyncio.Queue(maxsize=64)` 的 `put()` 无超时。Edge「半连接」（stream 存在但不消费）时 `put` 永久阻塞，session 僵死占满并发槽，call_record 卡在 `init` 永不结束。
2. `RtcTelephonyClient._edge_device_id` 是单值，所有 DialCommand 只能发给一个 Edge，无法支持多 Edge 并行处理 leads。

## What Changes

- `_ServerStream.send()` 用 `asyncio.wait_for(..., timeout=ISALES_ENGINE_GRPC_SEND_TIMEOUT_S)`（默认 5.0s）包裹，超时抛 `EdgeNotConnected`；上层 `dial()` 已有清理逻辑。
- 新增 `device_id → edge_device_id` 动态路由：`CloudEdgeGrpcServer._device_to_edge` 映射，Edge Heartbeat 的 `devices[]` 注册，断连时清理，`resolve_edge_for_device()` 解析。
- 向后兼容：`ISALES_ENGINE_EDGE_DEVICE_ID` 非空 → legacy 单 Edge 模式（行为不变）；为空 → 动态路由模式。
- protobuf schema 不变，scheduler 选 device 逻辑不变。

## Impact

- Spec: `service-communication`（cloud-edge gRPC 控制面 send 超时 + 多 Edge 路由）。
- Code: `isales-engine` settings.py / transport/grpc_server.py / realtime/rtc_telephony.py / main.py。
- 已实装并部署：engine commit `cf59640`（2026-06-08，随 §11 一同上线，boot logs 验证 clean）。详见 `design.md`。
