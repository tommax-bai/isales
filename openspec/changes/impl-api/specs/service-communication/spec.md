## ADDED Requirements

### Requirement: API ↔ 前端 WebSocket 代理

`isales-api` SHALL 提供 `/ws/calls/{campaign_id}` WebSocket endpoint：服务端订阅 Redis Pub/Sub channel `engine:events:campaign:{id}`、反序列化 `EngineEvent`（按 message-contract spec），fan-out 给所有该 campaign 的连接客户端。本 Requirement 把 service-communication § 通信通道矩阵中"engine → api Pub/Sub"的 api 侧落地形态明确为前端可订阅的 WebSocket。

#### Scenario: WebSocket 鉴权

- **WHEN** 客户端连接 `/ws/calls/{campaign_id}?token=<JWT>`
- **THEN** 服务端 SHALL 在 accept 前验证 JWT；验证失败 MUST 立即关闭连接并返回 close code 4401；MUST NOT accept 未鉴权连接占资源

#### Scenario: 多客户端订阅同一 campaign

- **WHEN** 多个前端客户端订阅同一 campaign_id
- **THEN** 服务端 SHALL 共享一个 Redis Pub/Sub 订阅，把每条 EngineEvent fan-out 给所有连接；MUST NOT 为每个 WS 连接独立订阅 Redis（防止 Redis 连接膨胀）

#### Scenario: 客户端断开

- **WHEN** WS 客户端断开（主动或网络异常）
- **THEN** 服务端 SHALL 从该 campaign 的连接集合移除；当某 campaign 无连接时 MAY 保留 Redis 订阅（避免重复订阅成本）或 MAY 关闭订阅（节省资源）——具体策略由 impl 决定

#### Scenario: v1 单实例限制

- **WHEN** v1 部署
- **THEN** isales-api SHALL 单实例运行；MUST NOT 假设跨实例消息广播；多实例扩展（v2）MUST 经 OpenSpec change proposal，候选方案：sticky session 或 Redis Streams + 跨实例转发

#### Scenario: 消息形状由 message-contract spec 约束

- **WHEN** 服务端转发消息给 WS 客户端
- **THEN** SHALL 直接传递 `EngineEvent` JSON（不重新包装）；前端解析时 MUST 按 message-contract spec 的 schema 处理；后端 MUST NOT 在 WS 层做字段裁剪或重命名
