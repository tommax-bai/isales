## Why

`isales-common` 是 7 仓库微服务架构里被其他 6 个服务共同依赖的共享库（已在 `architecture` spec 中确立其职责）。当前还是空仓库，所有下游服务（api / engine / scheduler / worker / telephony / web）都无法启动开发——必须先把模型、Schema、Provider 接口、迁移落地，才能解锁后续阶段。

## What Changes

- 新建 `isales-common` Python 包仓库（独立 git，pyproject.toml + hatchling，可被其他仓库 `pip install -e .` 装入）
- 落地 `data-model` spec 中列出的全部 19 张表（campaign / holiday / agent / handoff_task / role_config / prompt_version / pipeline_trace / lead / call_record / call_summary / voice_model / filler_set / filler_phrase / callback_config / callback_log / device / sim_card / device_sim_binding / campaign_device）的 SQLAlchemy 2.x ORM 模型
- 落地全部 Pydantic v2 请求/响应 Schemas（按资源拆分 campaign.py / lead.py / call.py / device.py …）
- 定义 ASR / TTS / LLM 三套 Provider ABC（含异步 session 抽象），`isales-engine` 后续提供具体实现
- **定义 Redis 消息体 Pydantic schemas**：覆盖 `service-communication` spec 通道矩阵中的全部跨服务消息（DialRequest / CallEnded / EngineControl / EngineEvent / CampaignControl），所有 producer / consumer MUST 通过 isales-common 引用同一份模型，杜绝裸 dict
- 定义全局 enums（CallStatus / RoleKind / TransferStatus / DeviceStatus 等）
- utils：号码归一化、音频格式工具、加解密（用于 SIM 密码 / signing_secret）、Redis client factory
- alembic 初始迁移：12+ 张表全部建好，作为后续所有 schema 演进的起点

## Capabilities

### New Capabilities

- `provider-abc`: ASR / TTS / LLM Provider 接口契约。定义 `isales-engine` 与所有外部 AI 供应商之间的稳定接口，是"切换供应商不改业务代码"的边界。
- `message-contract`: 跨服务 Redis 消息体的契约规则。定义"消息形状的单一来源"——所有跨服务消息体 MUST 用 isales-common 的 Pydantic 模型，附版本字段，禁止裸 dict / 散落定义。

### Modified Capabilities

无。本次 change 是对 `data-model` / `architecture` / `service-communication` 等已有 spec 的**首次实施**，不修改任何已有 spec 的 requirement（`message-contract` 与 `service-communication` 是互补：后者定义通道，前者定义通道里跑的消息形状）。

## Impact

- **新仓库**：`isales-common`（独立 git 历史，本仓库下不放代码）
- **依赖链**：阻塞所有其他 6 个服务的实施 change（init-isales-api、init-isales-engine 等）
- **跨服务一致性**：本次定义的 ORM 模型字段与 enum 取值一旦合入，后续修改 MUST 通过 alembic 迁移 + 新 change proposal
- **不影响**：现有 16 份 spec 不变；不引入任何新的运行时服务
