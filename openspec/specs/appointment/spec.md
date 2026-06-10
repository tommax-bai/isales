# appointment Specification

## Purpose
TBD - created by archiving change web-admin-ui-redesign. Update Purpose after archive.
## Requirements
### Requirement: 预约能力已下线

预约（appointment）能力已于 `admin-prune-vestigial-features` 整体下线。系统 MUST NOT 提供 `appointment` 表、`Appointment` ORM model、`/appointments` API、预约管理 view、`CreateAppointmentDialog` 创建入口，或 `LeadStatus.APPOINTED` / `VISITED` 状态。原“到店预约”为纯手工台账（仅外呼记录手动入口写入），无任何运行时生产或消费方，已彻底移除。`goal_type="appointment"`（goal-achievement 分类标签）属另一能力，保留不变。

#### Scenario: 无 appointment 运行时制品

- **WHEN** 检查任一 iSales 服务或前端
- **THEN** MUST NOT 存在 `appointment` 表、`Appointment` model、`/appointments` 路由或预约管理 view；lead 状态枚举 MUST NOT 含 `appointed` / `visited`（`lost` 保留）

