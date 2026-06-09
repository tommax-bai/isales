# iSales 系统设计 — 索引

> AI 外呼销售系统。本文档已迁移到 OpenSpec 多文件规范结构。本文件作为索引指向各 capability spec。
>
> 详细规范见 `openspec/specs/` 目录。后续设计变更 MUST 通过 OpenSpec change proposal 流程：`/opsx:propose` → `/opsx:apply` → `/opsx:archive`。

---

## 业务行为规范

| Capability | 文件 | 简介 |
|---|---|---|
| 状态机 | [`call-state-machine`](openspec/specs/call-state-machine/spec.md) | 通话生命周期状态集合与转换规则 |
| AI 管线 | [`ai-pipeline`](openspec/specs/ai-pipeline/spec.md) | 双 LLM 流式：main 流式回复 + referee 门控决策 + post-call extractor |
| 角色 Prompt | [`role-prompt`](openspec/specs/role-prompt/spec.md) | Prompt 组装结构、JSON Mode、版本管理 |
| 目标达成 | [`goal-achievement`](openspec/specs/goal-achievement/spec.md) | 实时判定 + WRAPPING_UP 收尾 |
| 打断判定 | [`interruption-detection`](openspec/specs/interruption-detection/spec.md) | 白名单 + 时长双条件，不可撤销 |
| 垫词 | [`filler`](openspec/specs/filler/spec.md) | 多 set 轮询、集内随机不重复、预生成 |
| 沉默激活 | [`silence-activation`](openspec/specs/silence-activation/spec.md) | 阈值触发 + 上限挂断 |
| 转人工（v1） | [`human-handoff`](openspec/specs/human-handoff/spec.md) | 标记 + 通知，不实时桥接 |

## 输入输出 / 数据流

| Capability | 文件 | 简介 |
|---|---|---|
| Transcript | [`transcript`](openspec/specs/transcript/spec.md) | 事件流 + dialog_history 双集合 + pipeline_trace |
| Webhook 回调 | [`webhook-callback`](openspec/specs/webhook-callback/spec.md) | JsonLogic trigger + Jinja2 payload + HMAC 签名 |
| 消息契约 | [`message-contract`](openspec/specs/message-contract/spec.md) | 跨服务消息体集中定义在 isales-common + 版本字段 + 通道矩阵覆盖 |
| Provider ABC | [`provider-abc`](openspec/specs/provider-abc/spec.md) | ASR/TTS/LLM 异步流式接口抽象，集中定义在 isales-common |
| Provider 凭据 | [`provider-credential`](openspec/specs/provider-credential/spec.md) | 凭据 DB 单一事实来源 + Fernet 加密 + provider_credential 表 |

## 调度与生命周期

| Capability | 文件 | 简介 |
|---|---|---|
| 重试与跟进 | [`retry-followup`](openspec/specs/retry-followup/spec.md) | 指数退避重试 + 固定间隔跟进 + 勿打识别 |
| 时间窗口 | [`time-window`](openspec/specs/time-window/spec.md) | Campaign 多窗口 + 节假日 + 窗外推迟 |
| 预约 | [`appointment`](openspec/specs/appointment/spec.md) | Appointment 数据模型 + 状态机 + 与 Lead 状态联动 |

## 基础设施

| Capability | 文件 | 简介 |
|---|---|---|
| 总体架构 | [`architecture`](openspec/specs/architecture/spec.md) | 7 仓库 + 云-边拆分部署（5 服务上云 + 2 组件留边） |
| 部署拓扑 | [`deployment-topology`](openspec/specs/deployment-topology/spec.md) | 云端 ECS systemd 5 units + 边缘 2 units + 端口 / 环境变量契约 |
| 硬件层 | [`device-hardware`](openspec/specs/device-hardware/spec.md) | USB GSM Modem 自研控制层 + audio-bridge（DingRTC ↔ modem 桥接） |
| 数据模型 | [`data-model`](openspec/specs/data-model/spec.md) | 全表清单 + 归属服务 |
| 服务通信 | [`service-communication`](openspec/specs/service-communication/spec.md) | 通信通道矩阵 + 云-边 gRPC 控制面 |
| Web 管理面 | [`web-admin-ui`](openspec/specs/web-admin-ui/spec.md) | 客户面 / 运营面 view 清单 + 已 spec 能力的 UI 暴露 |

## 实施计划

阶段实施细节见 [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md)。

## OpenSpec 工作流

- 提议变更：`/opsx:propose <change-name>`
- 应用变更：`/opsx:apply <change-name>`（在 PR review 通过后）
- 归档：`/opsx:archive <change-name>`

直接编辑 `openspec/specs/*.md` 已不再是推荐方式。所有变更应通过 change proposal 走完整生命周期，便于后续追溯与审计。

## V1 范围外

以下能力已识别但暂不在 v1 范围内：

- 多语言支持（v1 仅普通话）
- 实时声纹识别（用于打断判定增强）
- 角色 prompt 的 A/B 实验框架
- 通话录音的实时转写流（v1 离线 ASR 后处理）
- engine 多实例 + 多主机扩展的会话亲和与跨机调度
- SMS 收发能力（v1 仅语音）
- 跨时区 / 海外通道
- 多租户、计费、配额管理（SaaS 化能力）
- 商业系统对比识别出的 P1/P2 能力：自动质检、情绪识别触发转人工、监控告警大盘、A/B 测试、沙盒模式
- **转人工实时桥接**：v1 仅做"标记+通知"。v2 候选方案三选一：
  - GSM 呼叫转接（AT+CHLD=4）—— 最贴近原生体验，依赖运营商支持
  - 自研 SIP 软话机集成 —— modem-controller 同时作为 SIP 端点
  - 引入 FreeSWITCH 仅做 bridge —— 局部破例，但增加运维面
- PII 脱敏 / 加密 / 留存策略
