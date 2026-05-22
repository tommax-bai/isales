## ADDED Requirements

### Requirement: Appointment 数据模型

系统 SHALL 引入 `appointment` 表持久化"到店预约"事实。每条 appointment SHALL 关联一个 `lead`（必填外键）与可选的 `call_record`（创建该预约的通话）。`appointment` 表的归属服务 SHALL 为 `api`，模型与 alembic 迁移 SHALL 由 `isales-common` 统一管理。

#### Scenario: 表结构

- **WHEN** appointment 表被创建
- **THEN** 表 SHALL 至少包含字段：`id`（PK）、`lead_id`（FK → `lead.id`, NOT NULL）、`created_from_call_id`（FK → `call_record.id`, NULL 允许）、`appointment_time`（TIMESTAMPTZ, NOT NULL）、`status`（enum: pending/confirmed/completed/cancelled, NOT NULL, default pending）、`store_address`（TEXT, NOT NULL）、`directions`（TEXT, NOT NULL）、`notes`（TEXT, NULL 允许）、`created_at`、`updated_at`

#### Scenario: 客户与电话冗余

- **WHEN** 预约创建
- **THEN** appointment 表 MUST NOT 重复存储 lead 的 name / phone（避免数据漂移），UI 展示客户姓名与电话 SHALL 通过 join 或 API 层拼接 `lead.name` / `lead.phone`

### Requirement: Appointment 状态机

`appointment.status` SHALL 遵循以下状态转移规则：

```
pending ──confirm──> confirmed ──complete──> completed
   │                     │
   └───cancel────┐       └───cancel────┐
                 │                      │
                 └──> cancelled <───────┘
```

任何 `completed` 或 `cancelled` 的 appointment SHALL 视为 terminal，MUST NOT 再被转移到其他状态。

#### Scenario: 合法状态转移

- **WHEN** 用户对 status=pending 的 appointment 触发"确认"动作
- **THEN** status SHALL 变为 confirmed；updated_at SHALL 刷新

#### Scenario: 完成动作的级联

- **WHEN** 用户对 status=confirmed 的 appointment 触发"标记完成"动作
- **THEN** appointment.status SHALL 变为 completed；同时其关联 lead 的 `lead.status` SHALL 被推进到 `visited`

#### Scenario: 拒绝非法转移

- **WHEN** 任何客户端对 status ∈ {completed, cancelled} 的 appointment 提交 status 变更请求
- **THEN** API SHALL 返回 4xx 错误（HTTP 409 Conflict），数据库状态 MUST NOT 改变

#### Scenario: 取消可从任意非 terminal 状态出发

- **WHEN** 用户对 status ∈ {pending, confirmed} 的 appointment 触发"取消"动作
- **THEN** status SHALL 变为 cancelled

### Requirement: Appointment 与 Lead 的状态联动

创建 appointment SHALL 将关联 lead 推进到 `appointed` 状态；完成 appointment SHALL 将关联 lead 推进到 `visited` 状态。取消 appointment MUST NOT 自动回退 lead 状态（避免误清除运营人员的人工标注）。

#### Scenario: 创建时推进 lead

- **WHEN** 用户从外呼记录 view 创建一条 appointment（POST /api/appointments）
- **THEN** 服务端 SHALL 在同一事务中将该 lead.status 更新为 `appointed`（若当前不为 visited 或 lost）

#### Scenario: 完成时推进 lead

- **WHEN** appointment status 转移到 completed
- **THEN** 服务端 SHALL 在同一事务中将该 lead.status 更新为 `visited`

#### Scenario: 取消不回退 lead

- **WHEN** appointment status 转移到 cancelled
- **THEN** 关联 lead.status MUST 保持不变；运营人员若需调整 SHALL 在 leads view 手动修改

### Requirement: Appointment 管理 API

`isales-api` SHALL 暴露以下 admin 端点用于 appointment CRUD 与状态变更：

- `GET /api/appointments` — 列表查询，支持按 status、appointment_time 范围、lead_id 过滤
- `POST /api/appointments` — 创建，请求体含 lead_id / appointment_time / store_address / directions / created_from_call_id（可选）/ notes（可选）
- `GET /api/appointments/{id}` — 单条详情
- `PATCH /api/appointments/{id}` — 编辑非状态字段（appointment_time / store_address / directions / notes）
- `PATCH /api/appointments/{id}/status` — 状态变更，请求体 `{ "action": "confirm" | "complete" | "cancel" }`
- `DELETE /api/appointments/{id}` — 硬删除（仅 admin role，且 status 必须为 pending 或 cancelled）

#### Scenario: 鉴权

- **WHEN** 任一 `/api/appointments` 端点被调用
- **THEN** SHALL 强制 JWT bearer token 校验，与现有 admin API 一致；未认证 SHALL 返回 401

#### Scenario: 状态变更使用 action 而非 status

- **WHEN** 客户端变更 appointment 状态
- **THEN** SHALL 使用 `PATCH .../status` + `action` 字段（confirm/complete/cancel），服务端 SHALL 根据 action 计算目标状态；MUST NOT 接受客户端直接指定 status 值

### Requirement: Appointment view 展示

`isales-web` 的预约管理 view（`/appointments`）SHALL 将 appointment 分为两组展示：

- "即将到店"：status ∈ {pending, confirmed}，按 appointment_time 升序排列
- "历史预约"：status ∈ {completed, cancelled}，按 appointment_time 倒序排列

每条 appointment 卡片 SHALL 显示客户姓名、电话、预约时间（中文长格式 `YYYY年MM月DD日 HH:mm`）、门店地址、到店指引、备注（若有）、当前状态徽标。

#### Scenario: 操作按钮按状态变化

- **WHEN** 渲染一条 status=pending 的 appointment
- **THEN** 卡片底部 SHALL 显示"确认预约"主按钮 + "取消"次按钮

- **WHEN** 渲染一条 status=confirmed 的 appointment
- **THEN** 卡片底部 SHALL 显示"标记完成"主按钮 + "取消"次按钮

- **WHEN** 渲染一条 status ∈ {completed, cancelled} 的 appointment
- **THEN** 卡片 SHALL 仅显示信息，无操作按钮，且整卡片 SHALL 以减淡（opacity 0.75）样式呈现

#### Scenario: 空状态

- **WHEN** 即将到店分组无数据
- **THEN** SHALL 显示"暂无即将到店的预约"占位文案；历史预约分组无数据 SHALL 隐藏整个区块（不显示空标题）
