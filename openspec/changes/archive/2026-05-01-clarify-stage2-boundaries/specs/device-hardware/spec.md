## MODIFIED Requirements

### Requirement: 选 device API

`telephony-api` SHALL 暴露 `POST /devices/select` 给 scheduler 在拨号前调用。请求与响应 schema MUST 由 isales-common 集中提供（见 ADDED Requirement: 选号 API schema 出处）；调用方 MUST 引用同一份 Pydantic 模型。

#### Scenario: 选 device 入参与出参

- **WHEN** scheduler 调用 `POST /devices/select`
- **THEN** 请求体 = `{ campaign_id }`；响应体 = `{ device_id, phone_number }`

#### Scenario: 选 device 算法

- **WHEN** telephony-api 处理选号请求
- **THEN** SHALL：
  1. 取该 Campaign 关联的 device（通过 `campaign_device` 中间表）
  2. 过滤 `device.status=idle` 且 `device_sim_binding.is_active=true`
  3. 选 `device.last_call_at` 最早的（保持负载均衡）；`last_call_at IS NULL`（从未拨打）SHALL 视为最早，优先选中
  4. 没有空闲设备 → 返回 `503 no_idle_device`

#### Scenario: 选号成功后回写 last_call_at

- **WHEN** telephony-api 选中某 device 返回给 scheduler
- **THEN** SHALL 在响应返回前更新 `device.last_call_at = now()`；MUST NOT 等待真实拨号成功后再写；SHALL 保证并发 `/devices/select` 调用不会选中同一台 idle device（实现 MAY 用事务 + `SELECT ... FOR UPDATE`、行级锁或乐观锁，由 impl-telephony 决定具体策略）

## ADDED Requirements

### Requirement: 选号 API schema 出处

`POST /devices/select` 的请求与响应 Pydantic 模型 SHALL 集中定义在 `isales-common`；telephony-api（响应方）与 scheduler（请求方）MUST 引用同一份模型，MUST NOT 各自维护独立 schema。

#### Scenario: schema 在 isales-common 的位置

- **WHEN** isales-common 落地阶段 2 增量
- **THEN** SHALL 在 `isales_common/schemas/device.py` 增加 `DeviceSelectRequest`（字段：`campaign_id: int`）与 `DeviceSelectResponse`（字段：`device_id: int`、`phone_number: str`）

#### Scenario: scheduler 引用而非复制

- **WHEN** scheduler（impl 阶段 3）实现选号调用
- **THEN** scheduler 代码 MUST 通过 `from isales_common.schemas.device import DeviceSelectRequest, DeviceSelectResponse` 引用；MUST NOT 在 scheduler 仓库内重新定义同名模型

#### Scenario: schema 演进通过 isales-common bump

- **WHEN** select API 的字段需要增减
- **THEN** SHALL 走 isales-common 版本 bump 流程；调用方与响应方 MUST 同步升级；MUST NOT 一方先改造成 schema 不一致
