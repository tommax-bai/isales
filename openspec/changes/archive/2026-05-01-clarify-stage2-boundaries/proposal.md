## Why

阶段 2（isales-telephony + isales-api）正要进入实施 propose，但 explore 阶段发现几条跨服务边界在现有 spec 里有模糊点或自相矛盾：`device-hardware` 的 `/devices/select` 算法引用了 `last_call_at` 字段，但 `data-model` 没列；`campaign_device` 归属 telephony，但现有 `service-communication` 又规定"写操作由归属服务承担"——而 isales-api 在 Campaign 嵌套配置里需要写这张表，归属本身就归错了；telephony-api 的鉴权范围（与 isales-api 是否同体系、是否对前端开放）也未约定。这些点如果留到 impl change 里再边写边讨论，两条并行实施线必然反复协调。先用一个纯 spec change 把这几个点拍死，再开 impl-telephony / impl-api 两个独立实施 change。

## What Changes

- 在 `data-model` spec 中增加 `device.last_call_at` 字段（用于 `/devices/select` 负载均衡）
- 在 `data-model` spec 中把 `campaign_device` 表的归属服务从 `telephony` 改为 `api`（campaign_device 的 lifecycle 跟随 campaign，不跟随 device；该调整使 isales-api 在 Campaign 嵌套写入时直写 campaign_device 不再违反 `service-communication` 的"归属即写入"约束）
- 在 `device-hardware` spec 中显式引用 `device.last_call_at` 用于 select 负载均衡；约定 `POST /devices/select` 的请求/响应 schema（`DeviceSelectRequest` / `DeviceSelectResponse`）由 isales-common 集中提供
- 在 `architecture` spec 中新增 Requirement：telephony-api 与 isales-api 共享同一套 JWT 鉴权体系——isales-api 为唯一签发方，telephony-api 仅验证；HMAC 签名密钥由环境变量分发；isales-web SHOULD 直连 telephony-api（不经 isales-api 转发）
- 不引入新表、新字段（除 `last_call_at`）、新 capability；不动代码；不动 Pydantic 实现（schema 落地由后续 impl change 承担）

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `data-model`: 在 `device` 表字段清单中增加 `last_call_at`；调整 `campaign_device` 表的归属服务为 `api`
- `device-hardware`: 显式引用 `last_call_at` 用于 select 排序；新增 Requirement 约定 `/devices/select` 的请求/响应 schema 由 isales-common 提供
- `architecture`: 新增 Requirement 约定 telephony-api 与 isales-api 的 JWT 共享鉴权体系（签发/验证/密钥分发）与 web 直连策略

## Impact

- **spec 文件**：修改 `openspec/specs/{data-model,device-hardware,architecture}/spec.md` 三个 spec
- **isales-common 增量需求**：本 change 不动 isales-common 仓库；`device.last_call_at` 列 + `DeviceSelectRequest/Response` schema + alembic 增量随后续 `impl-telephony` change 启动时一并发布为 v0.1.2
- **isales-common v0.1.1 兼容性**：v0.1.1 已发版本身不回滚；任何下游 impl change 启动前 SHALL bump 依赖到 v0.1.2
- **解锁**：`impl-telephony` 与 `impl-api` 两个 impl change 可在本 change archive 后并行 propose
- **不影响**：`service-communication` 通道矩阵、其他 capability、其他表的归属
