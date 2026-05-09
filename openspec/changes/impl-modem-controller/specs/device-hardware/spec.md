## ADDED Requirements

### Requirement: modem-controller 心跳与失联探测

modem-controller SHALL 每 30s 向 isales-api 发送一次心跳；isales-worker SHALL 每 30s 跑一次 watchdog，把超过 120s 没有心跳的 device 状态置为 `offline`。这把 § device 状态机 中"USB 拔出 → offline"的兜底链路从"udev 必到位"扩到"心跳兜底"，覆盖 modem-controller 进程崩溃 / 主机网络分区 / udev 漏报等场景。

#### Scenario: modem-controller 心跳格式与频率

- **WHEN** modem-controller 进程运行中（任意 device 状态）
- **THEN** 进程 SHALL 每 30s 对每个已注册 device 发一次 `PATCH /devices/{id}/heartbeat`；请求体 `{signal_strength: <0-31, AT+CSQ 实测, optional>}`；MUST NOT 同时更新其他字段（status / last_call_at 等不在心跳路径中维护）

#### Scenario: 心跳端点不修改其他字段

- **WHEN** telephony-api 收到 `PATCH /devices/{id}/heartbeat`
- **THEN** 服务端 MUST 仅更新 `device.last_seen_at = now()`；MUST NOT 修改 `status` / `last_call_at` / `imei` / `signal_strength` 等字段（signal_strength 按 data-model spec 在 sim_card 表，v1 心跳路径暂不级联回写，留给 v2）；MUST 校验当前用户身份（admin JWT 或 service-account JWT 任一）

#### Scenario: watchdog 失联探测

- **WHEN** isales-worker 每 30s 运行 watchdog
- **THEN** 工作 SHALL 把所有 `last_seen_at IS NOT NULL AND last_seen_at < now() - INTERVAL '120 seconds' AND status NOT IN ('offline')` 的 device 行 status 置为 `offline`；同一行二次跑 MUST 幂等（已是 offline 不再写）

#### Scenario: 心跳与 udev 拔出竞态

- **WHEN** USB 设备拔出（udev remove）与 watchdog 失联探测同时检测到同一 device
- **THEN** udev 走 `PATCH /devices/{id}` 直接置 status=offline；watchdog UPDATE 用 `WHERE status != 'offline'` 守卫；DB 行级锁保证最多一次写入；任一路径完成后 status 等于 offline、不会重复触发

#### Scenario: 心跳缺失到恢复

- **WHEN** modem-controller 进程崩溃 → device.status 经 watchdog 置 offline → 进程恢复后第一次心跳到达
- **THEN** 心跳本身 MUST 仅更 last_seen_at；恢复 status=idle 由独立的"udev 注册路径"或者运维显式 `PATCH /devices/{id} status=idle` 触发；MUST NOT 由心跳隐式翻转 status（避免半坏的进程心跳还在但实际不能拨打）
