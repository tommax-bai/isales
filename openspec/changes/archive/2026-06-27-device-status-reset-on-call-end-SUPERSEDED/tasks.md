## 1. isales-common: DeviceReleased 消息

- [ ] 1.1 在 `isales_common/schemas/messages/` 新增 `DeviceReleased` 消息类（继承消息基类，字段：`device_id: int` 必填、`call_record_id: int`、`ended_at: datetime`；含 `schema_version`）；对齐 `message-contract` spec「消息基类与版本字段」
- [ ] 1.2 把 `DeviceReleased` 导出到 messages 包 `__init__`（与既有 `CallEnded`/`DialRequest` 同处）
- [ ] 1.3 单测：`DeviceReleased` 序列化/反序列化 round-trip + device_id 必填校验
- [ ] 1.4 bump isales-common 版本；记录在 CHANGELOG/版本号（新增类属非破坏，schema_version 不必升）

## 2. isales-engine: finalize 时发 DeviceReleased

- [ ] 2.1 pin 新版 isales-common
- [ ] 2.2 `settings.py` 增 `device_reset_queue` 配置，默认 `isales:device_reset`
- [ ] 2.3 `call_lifecycle.py::finalize_session` 末尾（`_lpush_call_ended` 之后、`_decr_concurrency` 附近）新增向 `isales:device_reset` LPUSH 一条 `DeviceReleased`，`device_id` 取自 `session.device_id`；`CallEnded` 发送侧不动
- [ ] 2.4 核对 device_id 全链路一致：scheduler 选号 `device_selection.py` → `DialRequest.device_id` → `CallSession.device_id` → `DeviceReleased.device_id`（防止发出错的 device_id）
- [ ] 2.5 单测：finalize_session 在各 hangup_cause 下都 LPUSH 一条 DeviceReleased（含异常路径，验证 `_runner_with_finalize` 必然触发）

## 3. isales-scheduler: 消费并复位

- [ ] 3.1 pin 新版 isales-common
- [ ] 3.2 `settings.py` 增 `device_reset_queue` 配置（与 engine 一致 `isales:device_reset`）
- [ ] 3.3 新增 `device_reset.py::reset_device_status(session, device_id)`：执行幂等 `UPDATE device SET status='idle' WHERE id=:device_id AND status IN ('dialing','in_call')`，返回是否命中
- [ ] 3.4 新增 `device_reset_loop`：BLPOP `isales:device_reset` → 解析 `DeviceReleased` → `reset_device_status` → commit；失败重试或留队列，MUST NOT 静默吞掉
- [ ] 3.5 在 `main.py` 的 task group 接线 `device_reset_loop`（与 dispatch_loop 并列）
- [ ] 3.6 单测：消费一条 DeviceReleased 后 device→idle；重复/乱序消息幂等；对已 idle/offline/flagged 的 device 不改动

## 4. 心跳回归 liveness-only（device 复位迁出心跳）

- [ ] 4.1 engine `transport/heartbeat_handler.py`：移除把 `DeviceHealth.status` apply 到 `device.status` 的逻辑（约 line 106-115），心跳只更 `last_seen_at`（对齐 `device-hardware` spec）
- [ ] 4.2 edge `main_windows.py` / `edge/main.py`：`_device_status_provider` 与心跳构造侧相应清理（status 不再驱动 DB）；与 `arch-cloud-edge-split` owner 对齐落地节奏（见 design.md Open Questions）——迁移期可先让事件驱动复位为 authoritative，再删心跳 apply
- [ ] 4.3 回归：确认移除后无其他路径依赖心跳翻 status（grep `DeviceHealth.status` / `mapped_status` 使用点）

## 5. (可选/分期) watchdog engine-crash 兜底

- [ ] 5.1 `isales_worker/device_watchdog.py` 增加分支：`status IN ('dialing','in_call') AND last_call_at < now() - <max_call_duration + margin>` → 置 `idle`（区别于既有 120s stale → `offline`）
- [ ] 5.2 阈值来源决策（campaign `wrap_up_max_seconds` + silence 预算推导，或全局常量）；写注释标明该兜底覆盖的失败域（engine 崩溃）与移除条件
- [ ] 5.3 单测：dialing + stale last_call_at → idle；非 stale 不动；与正常事件驱动复位不冲突

## 6. 端到端验证

- [ ] 6.1 真拨 13301035545 一通完整对话 → 用户挂断 → 秒级内 `SELECT status FROM device WHERE id=3` = `idle`，无需手动 SQL（对照本 change 的触发症状 call_record #157）
- [ ] 6.2 验证连续两通：第一通结束后设备自动 idle → scheduler 自动派第二通（lead 需 eligible），无需中途人工复位
- [ ] 6.3 验证 edge 崩溃场景：通话中 kill daemon → engine finalize 仍发 DeviceReleased → device 复位 idle
- [ ] 6.4 `make test-all`（engine + scheduler + worker + common）全绿
- [ ] 6.5 更新 `isales-telephony/deploy/edge/windows/STATE.md` 把"device 通话后卡 dialing"残留 gap 标记为已修；更新相关 memory
