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
