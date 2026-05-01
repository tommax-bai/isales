## 1. 仓库与包骨架

- [x] 1.1 在 `~/codes/` 下 `git init isales-common`，添加 `.gitignore`（Python + venv + .env）
- [x] 1.2 创建目录结构：`isales_common/{models,schemas,providers,utils}/__init__.py` + `tests/`
- [x] 1.3 写 `pyproject.toml`：hatchling 后端，requires-python ">=3.11"，依赖 `sqlalchemy[asyncio]>=2.0`、`pydantic>=2.0`、`asyncpg`、`alembic`、`redis>=5.0`、`cryptography`、`phonenumbers`
- [x] 1.4 写 `pyproject.toml` 的 dev 依赖：`pytest`、`pytest-asyncio`、`mypy`、`ruff`
- [x] 1.5 配 `pre-commit-config.yaml`：ruff format + ruff check + mypy
- [x] 1.6 添加 README.md（一句话说明 + 安装/测试命令）
- [x] 1.7 配 GitHub Actions CI：跑 ruff / mypy / pytest（含 alembic upgrade/downgrade 往返）

## 2. enums 与 utils（无外部依赖）

- [x] 2.1 写 `isales_common/enums.py`：`CallStatus`、`RoleKind`（role/judge/polish）、`TransferStatus`、`TransferTriggerType`、`DeviceStatus`、`AgentStatus`、`HandoffStatus`、`LeadStatus`、`CallbackStatus`、`GenerationStatus`
- [x] 2.2 写 `utils/phone.py`：用 `phonenumbers` 做 E.164 归一化与校验
- [x] 2.3 写 `utils/crypto.py`：Fernet 对称加解密，密钥从 `ISALES_FERNET_KEY` 环境变量读取
- [x] 2.4 写 `utils/redis.py`：`get_redis(url) -> Redis` 异步 client factory
- [x] 2.5 写 `utils/audio.py`：常量（PCM 8k/16k/24k 采样率枚举）+ 简单格式校验函数
- [x] 2.6 单元测试覆盖 utils 各函数（边界值 + 异常）

## 3. SQLAlchemy 模型 - 批次 A（无外键）

- [x] 3.1 写 `models/base.py`：`Base = DeclarativeBase`，统一时间戳 mixin（created_at/updated_at）
- [x] 3.2 写 `models/agent.py`：agent 表（name, login_user, status）
- [x] 3.3 写 `models/voice_model.py`：voice_model 表（name, provider, voice_id, sample_url）
- [x] 3.4 写 `models/holiday.py`：holiday 表（date, name, region）
- [x] 3.5 写 `models/device.py`：device 表（name, usb_port, modem_model, imei, status, last_seen_at）
- [x] 3.6 写 `models/sim_card.py`：sim_card 表（iccid, imsi, phone_number, carrier, plan, balance, signal_strength, status, last_checked_at）

## 4. SQLAlchemy 模型 - 批次 B（依赖 A）

- [x] 4.1 写 `models/campaign.py`：campaign 表全字段（按 data-model spec 表清单）
- [x] 4.2 写 `models/prompt.py`：prompt_version 表（scope_type, scope_id, content, created_by, is_active）
- [x] 4.3 写 `models/role_config.py`：role_config 表（campaign_id, kind, model, current_prompt_version_id, temperature, top_p, ext_params, enabled）
- [x] 4.4 写 `models/filler.py`：filler_set + filler_phrase 两张表
- [x] 4.5 写 `models/device_relations.py`：device_sim_binding + campaign_device 两张表
- [x] 4.6 写 `models/callback_config.py`：callback_config 表（含 trigger / payload_template / signing_secret 加密存储）

## 5. SQLAlchemy 模型 - 批次 C（依赖 B）

- [x] 5.1 写 `models/lead.py`：lead 表（含 retry_count / follow_up_count / next_call_at / last_hangup_cause）
- [x] 5.2 写 `models/call_record.py`：call_record 表（含 transcript JSONB / transfer_status / wrap_up_started_at / prompt_versions JSONB）
- [x] 5.3 写 `models/call_summary.py`：call_summary 表
- [x] 5.4 写 `models/pipeline_trace.py`：pipeline_trace 表（按 transcript spec 字段）
- [x] 5.5 写 `models/handoff_task.py`：handoff_task 表
- [x] 5.6 写 `models/callback_log.py`：callback_log 表

## 6. Pydantic Schemas

- [x] 6.1 写 `schemas/_base.py`：通用基类（BaseModel + ConfigDict(from_attributes=True)）
- [x] 6.2 写 `schemas/jsonb/`：JSONB 字段的嵌套模型（TimeWindow、RetryPolicy、CallbackTrigger、ExtractionField、PipelineTraceEntry、TranscriptEvent 等）
- [x] 6.3 写 `schemas/campaign.py`：CampaignCreate / Update / Read（含嵌套 role_config / filler_set 引用）
- [x] 6.4 写 `schemas/lead.py`、`schemas/voice_model.py`、`schemas/role_config.py`、`schemas/prompt.py`
- [x] 6.5 写 `schemas/call.py`：CallRecordRead（含 transcript / pipeline_trace 嵌套）
- [x] 6.6 写 `schemas/device.py`、`schemas/sim_card.py`、`schemas/agent.py`、`schemas/handoff.py`
- [x] 6.7 写 `schemas/callback.py`：CallbackConfig 三态 + CallbackLogRead
- [x] 6.8 schema 单元测试：边界值 + JSONB 嵌套校验 + ORM ↔ Schema 互转

## 7. Provider ABC

- [x] 7.1 写 `providers/_errors.py`：`ProviderError` 基类 + `ProviderTimeout` / `ProviderRateLimited` / `ProviderInvalidRequest` / `ProviderServerError`
- [x] 7.2 写 `providers/_models.py`：`ASRResult`、`Message`、`LLMResponse` 等 Pydantic 模型
- [x] 7.3 写 `providers/asr.py`：`ASRProvider` ABC（`stream_recognize` 异步方法）
- [x] 7.4 写 `providers/tts.py`：`TTSProvider` ABC（`synthesize_stream` 异步方法）
- [x] 7.5 写 `providers/llm.py`：`LLMProvider` ABC（`chat` 方法，含 `json_mode` 参数）
- [x] 7.6 写 `providers/testing/`：`MockASRProvider` / `MockTTSProvider` / `MockLLMProvider` + pytest fixture
- [x] 7.7 契约测试：验证 ABC 不可被遗漏方法实例化；mock 实现可正常调用

## 8. 跨服务消息 Schemas

- [x] 8.1 写 `schemas/messages/_base.py`：`BaseMessage` 基类（`schema_version: int = 1` + `message_id: UUID4 = Field(default_factory=uuid4)` + `created_at: datetime = Field(default_factory=utc_now)` + `__str__`）
- [x] 8.2 写 `schemas/messages/dial.py`：`DialRequest`（lead 信息子模型 + 历史摘要列表 + prompt_versions 快照 dict + caller_id + device_id）
- [x] 8.3 写 `schemas/messages/call_lifecycle.py`：`CallEnded`（call_record_id + 终止原因 enum + ended_at）
- [x] 8.4 写 `schemas/messages/engine_control.py`：`EngineControl` discriminated union（`ManualHangup` / `TransferCommand` / 预留扩展）
- [x] 8.5 写 `schemas/messages/engine_event.py`：`EngineEvent` discriminated union（`StatusChanged` / `ASRPartial` / `ASRFinal` / `TranscriptAppended` / `CallStarted` / `CallEndedEvent`）
- [x] 8.6 写 `schemas/messages/campaign_control.py`：`CampaignControl` discriminated union（`StartCampaign` / `PauseCampaign` / `ResumeCampaign`）
- [x] 8.7 round-trip 序列化测试：每个消息类 `model_dump_json()` → `model_validate_json()` 等值
- [x] 8.8 schema_version 校验测试：篡改版本号后 consumer 应识别并按 dead letter 处理（用辅助函数模拟）

## 9. Alembic 迁移

- [x] 9.1 `alembic init -t async alembic`
- [x] 9.2 配 `alembic/env.py`：异步引擎 + 从 `isales_common.models` 导入 `Base.metadata`
- [x] 9.3 配 `alembic.ini`：sqlalchemy.url 走环境变量
- [x] 9.4 跑 `alembic revision --autogenerate -m "initial schema"`，人工 review 生成的迁移
- [x] 9.5 在本地空 PG 上跑 `alembic upgrade head` 验证；再跑 `alembic downgrade base` 验证可逆
- [x] 9.6 把生成的迁移加入 CI 测试

## 10. 文档与发布准备

- [x] 10.1 README.md 完善：模块概览 + 安装方式（本地 -e + git URL）+ 各服务的引用样例
- [x] 10.2 在仓库根加 CHANGELOG.md，记录 v0.1.0 内容
- [x] 10.3 打 tag `v0.1.0`，推送到远端（同步发了 v0.1.1 修复 pytest 硬依赖与 mypy 1.8 严格模式）
- [x] 10.4 在主仓库（isales）的 IMPLEMENTATION_PLAN.md 里把"阶段 1：isales-common"标记为完成（或迁移到 OpenSpec）

## 11. 收尾

- [x] 11.1 在另一个空 venv 里 `pip install -e ../isales-common` 验证 import 全通（暴露并修复了 pytest 硬依赖 bug）
- [x] 11.2 跑全量 pytest 通过（97 passed）
- [x] 11.3 pre-commit + ruff + mypy 全绿
- [x] 11.4 回到本仓库执行 `openspec archive init-isales-common` 归档
