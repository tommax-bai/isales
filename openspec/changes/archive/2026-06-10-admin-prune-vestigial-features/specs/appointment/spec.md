## REMOVED Requirements

### Requirement: Appointment 数据模型

**Reason**: 预约功能整体删除——`appointment` 表无任何运行时生产者/消费者（仅外呼记录手动入口写入），是与 AI 外呼主链路无关的独立手工台账。drop 迁移 `c4d5e6f7a8b9` 删表，模型 / schema 一并删除。

### Requirement: Appointment 状态机

**Reason**: 预约功能整体删除，状态机随之失效。`AppointmentStatus` / `AppointmentAction` 枚举删除。

### Requirement: Appointment 与 Lead 的状态联动

**Reason**: 预约功能整体删除；`LeadStatus.APPOINTED` / `VISITED` 两个仅服务于本联动的成员一并删除（保留 `LOST`）。

### Requirement: Appointment 管理 API

**Reason**: 预约功能整体删除，`isales-api` 的 appointments router 及其注册删除。

### Requirement: Appointment view 展示

**Reason**: 预约功能整体删除，`isales-web` 的预约 view + 外呼记录的 `CreateAppointmentDialog` 创建入口删除。

## ADDED Requirements

### Requirement: 预约能力已下线

预约（appointment）能力已于 `admin-prune-vestigial-features` 整体下线。系统 MUST NOT 提供 `appointment` 表、`Appointment` ORM model、`/appointments` API、预约管理 view、`CreateAppointmentDialog` 创建入口，或 `LeadStatus.APPOINTED` / `VISITED` 状态。原“到店预约”为纯手工台账（仅外呼记录手动入口写入），无任何运行时生产或消费方，已彻底移除。`goal_type="appointment"`（goal-achievement 分类标签）属另一能力，保留不变。

#### Scenario: 无 appointment 运行时制品

- **WHEN** 检查任一 iSales 服务或前端
- **THEN** MUST NOT 存在 `appointment` 表、`Appointment` model、`/appointments` 路由或预约管理 view；lead 状态枚举 MUST NOT 含 `appointed` / `visited`（`lost` 保留）
