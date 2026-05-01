## Context

阶段 2 explore 阶段（见 conversation 5/01）发现现有 spec 三处边界模糊：

1. `device-hardware` § 选 device 算法 引用 `last_call_at`，但 `data-model` § device 表清单未列该字段
2. `data-model` § campaign_device 归属 telephony，但其 lifecycle 跟随 campaign；与 `service-communication` § "写操作 SHALL 由表的归属服务承担" 形成矛盾——api 在 Campaign 嵌套写入时无法直写 campaign_device
3. telephony-api 的鉴权范围（与 isales-api 是否同体系、是否对前端开放）未约定

本 change 是 spec-only：只调整 spec 文字，不动代码。目的是阶段 2 的两个 impl change（impl-telephony / impl-api）能在干净的边界上并行 propose、并行 apply、独立 archive。

约束：
- 现有 16 份 spec 中只动 3 份（data-model / device-hardware / architecture）
- 不引入新 capability、新表、新通道
- 不动 isales-common 仓库（v0.1.1 已发版）；本 change 仅约定 v0.1.2 的接口形状

## Goals / Non-Goals

**Goals:**

- 让 `data-model` 表清单与 `device-hardware` § 选 device 算法 自洽（last_call_at 在两处一致出现）
- 把 campaign_device 归属调整到 api，消除与 service-communication 的矛盾
- 约定 telephony-api 与 isales-api 的 JWT 共享体系到 Scenario 级别（签发方 / 验证方 / 密钥分发 / web 直连 / 内部调用 / isales-common 边界）
- 顺手把 last_call_at 的写时机定下来（避免并发选号选中同一台）

**Non-Goals:**

- 不实现 isales-common v0.1.2（schema、迁移、模型字段都留给 impl-telephony change）
- 不修改 service-communication / human-handoff / 其他 spec
- 不引入服务发现、服务网格、mTLS 等运维基础设施（v2 候选）
- 不约束 web 怎么实现（仅 SHOULD 直连，具体路径阶段 7 自己定）

## Decisions

### 1. campaign_device 归属：telephony → api（不开"互斥写入"例外）

- **选择**：把 `data-model` 表清单中 `campaign_device` 的归属服务从 `telephony` 改为 `api`
- **理由**：
  - 该表的 lifecycle 跟随 campaign（campaign 启停时增删关联），不跟随 device（设备插拔时不动 campaign 关联）
  - service-communication 的"归属即写入"是简洁原则，不应为 campaign_device 单开例外；改归属比开例外干净
  - device-hardware capability 仍可引用该表（capability 引用 ≠ 归属服务）
- **替代**：
  - 给 service-communication 加"中间表/关联表例外" → 例外多了规则就崩
  - 让 api 调 telephony-api `POST /campaigns/{id}/devices` 转发 → telephony-api 反向耦合 campaign 概念，更糟

### 2. last_call_at 的写时机：选号同步写，不等拨号结果

- **选择**：在 `device-hardware` § 选 device API 增加 Scenario "选号成功后回写 last_call_at"——telephony-api 在响应返回前更新 `last_call_at = now()`
- **理由**：
  - 若等拨号成功后再写，并发的两次 `/devices/select` 可能选中同一台 idle device（last_call_at 还没更新）
  - 选号同步写在最坏情况是"选了但没真拨成"——last_call_at 偏新一点点，下一轮该 device 排序略靠后，对负载均衡无显著伤害
  - 写动作放在 telephony-api 而非 modem-controller，是因为 modem-controller 收到 dial 指令时已经过了选号窗口
- **替代**：拨号成功后由 modem-controller 写 → 选号竞态；阶段 2 mock 还没 dial 实现，写不了

### 3. NULL last_call_at 视为最早

- **选择**：`last_call_at IS NULL`（从未拨打）SHALL 视为最早，优先选中
- **理由**：新接入的设备应优先用一次（验证可用性 + 均衡负载）；这是排序语义的自然延伸，spec 应显式写出避免实现各做各的

### 4. JWT 颗粒度：约定到签发方/验证方/密钥分发，不到具体算法

- **选择**：在 `architecture` 增加 6 个 Scenario，覆盖：唯一签发方、仅验证、密钥分发渠道、web 直连、内部调用、isales-common 边界
- **理由**：
  - 不约到 Scenario 级别 → impl 阶段两个仓库会就密钥怎么共享反复讨论
  - 但具体的 JWT 算法（HS256 还是 RS256）、过期时间、刷新策略 → 属于 impl 决策，不上升到 spec
- **替代**：写成单条 "共享 JWT" 不展开 → 不明确，回到 explore 时的状态

### 5. 内部调用（scheduler → telephony-api）v1 免 JWT，靠网络隔离

- **选择**：v1 单主机部署下 scheduler 调 `/devices/select` MAY 免 JWT；要求 telephony-api 仅监听 loopback 或内部网段
- **理由**：单主机内不存在外部访问；引入服务账号 JWT 增加运维负担，对 v1 ≤8 路并发收益为零
- **替代**：要求服务账号 JWT → 需要在 isales-common 或某处定义服务账号体系，超出阶段 2 范围；列入 v2

### 6. isales-common MUST NOT 提供 JWT 签发函数

- **选择**：`architecture` 中显式声明 isales-common MUST NOT 提供签发函数，MAY 提供验证工具
- **理由**：isales-common 是无业务的共享库；签发函数依赖密钥来源，绑定后会让 isales-common 退化为密钥分发渠道，违反 "isales-common 共享库" Requirement 的精神
- **替代**：完全禁止 JWT 工具进 isales-common → 验证函数明显是稳定接口，禁止反而碎片化

## Risks / Trade-offs

| 风险 | 缓解 |
|---|---|
| campaign_device 归属调整后，已发的 isales-common v0.1.1 schema 不变（不影响），但 device-hardware capability 文档继续引用该表，读者需要从 data-model 表清单确认归属——可能引起"归属在哪"的疑惑 | data-model spec 是表归属的单一来源；device-hardware 仅引用功能不重复声明归属；本 change 在 Requirement 描述中加"归属决定 schema 演进与 PR 主导权" 一句澄清 |
| 选号同步写 last_call_at 与"真实拨号失败 → device 应排队靠前"理想模型不一致 | 接受偏差；v1 ≤8 路并发，最坏情况某 device 被错过一轮，下一轮就会被选中；阶段 6 接真实硬件后若发现影响均衡，再 propose 改用"拨号成功事件回写" |
| JWT 共享密钥经环境变量分发，部署时多服务要保证密钥一致 | 部署文档（impl-telephony / impl-api 的 tasks 中）明确密钥来源；CI 部署脚本统一注入 |
| service-communication spec 没有同步修改 | 不需要修改：service-communication 的"归属即写入"原则保持不变，只是 campaign_device 的归属变了；该 spec 的 Scenario 仍然成立 |

## Migration Plan

不适用——spec-only change，无运行时迁移。

archive 时序：
1. proposal / design / specs delta / tasks 全部 ready
2. 评审通过后 `openspec apply clarify-stage2-boundaries` 把 delta merge 进 `openspec/specs/` 主体
3. archive change，进入归档目录
4. 解锁 impl-telephony 与 impl-api 两个 impl change 的 propose

## Open Questions

无（explore 阶段已收敛；上述 6 项决策直接对应 specs delta 的内容）。
