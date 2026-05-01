## 1. 评审 spec delta

- [x] 1.1 校对 `specs/data-model/spec.md`：device 字段含 `last_call_at`、campaign_device 归属为 api、Requirement 描述里"归属决定 schema 演进与 PR 主导权"措辞清晰
- [x] 1.2 校对 `specs/device-hardware/spec.md`：选 device 算法引用 `device.last_call_at` + NULL 处理、新增"选号成功后回写 last_call_at" Scenario、ADDED Requirement "选号 API schema 出处" 三个 Scenario 完整
- [x] 1.3 校对 `specs/architecture/spec.md`：JWT 6 个 Scenario 覆盖（唯一签发方 / 仅验证 / 密钥分发 / web 直连 / 内部调用 / isales-common 边界）

## 2. 一致性检查

- [x] 2.1 确认 `service-communication` spec 不需修改：campaign_device 归属调整后，"写操作 SHALL 由表的归属服务承担"仍然成立（api 写 api 归属的表）
- [x] 2.2 确认 `human-handoff` spec 中 agent / handoff_task 的归属不受影响
- [x] 2.3 跑 `openspec validate clarify-stage2-boundaries`，无 error

## 3. 归档（含 delta merge）

> OpenSpec 没有独立的 `apply` 命令；`archive` 一并完成 "delta merge 进主 spec + 移动 change 到归档目录"。

- [ ] 3.1 运行 `openspec archive clarify-stage2-boundaries`：自动把 delta merge 进 `openspec/specs/{data-model,device-hardware,architecture}/spec.md`，并移动 change 到 `openspec/changes/archive/`
- [ ] 3.2 git diff 复核合并结果：data-model 表清单两处改动正确（`last_call_at` 加入 device、campaign_device 归属为 api、status 9 种枚举）、device-hardware 新 Scenario 就位、architecture 新 Requirement 在合适位置
- [ ] 3.3 提交 commit

## 4. 解锁下游

- [ ] 4.1 在 IMPLEMENTATION_PLAN.md 阶段 2 章节追加一行注释：isales-common v0.1.2 增量需求由 impl-telephony change 承担（last_call_at 列 + DeviceSelectRequest/Response schema + alembic 迁移）
