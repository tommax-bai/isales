## Context

`isales-common` 是 7 仓库架构的基石（见 `architecture` spec § Requirement: isales-common 共享库）。`data-model` spec 已确立 19 张表 + 单 PG 实例 + 单一 alembic 来源；`service-communication` spec 已确立 Redis 队列 / Pub/Sub / 计数器的通道矩阵；`ai-pipeline` spec 已确立 Provider 必须支持 JSON Mode。本设计把这些已成形的契约落地为 Python 代码与可执行迁移。

约束：
- Python 3.11+（asyncio + match 语法 + 现代类型注解）
- SQLAlchemy 2.x（async session）+ Pydantic 2.x + asyncpg
- 必须可以被其他仓库 `pip install -e ../isales-common` 成功导入
- 不引入业务逻辑（架构 spec § Requirement: isales-common 共享库 § Scenario "不放在 isales-common 的内容"）

## Goals / Non-Goals

**Goals:**
- 给所有下游服务一个可立即依赖的、稳定的 Python 包
- 19 张表的 ORM 模型 + Pydantic Schemas 全量到位
- ASR / TTS / LLM 三套 Provider ABC 接口签名稳定（本次定义后，后续半年内不轻易破坏性修改）
- **跨服务 Redis 消息体 schema 全量到位**（覆盖 service-communication spec 的全部跨服务通道），所有 producer / consumer 引用同一份模型
- alembic 初始迁移可在空数据库 `upgrade head` 成功
- 提供 Provider ABC 的契约测试基础（mock 实现 + pytest fixture）

**Non-Goals:**
- 不实现任何 Provider 的真实供应商接入（留给 `isales-engine` 的后续 change）
- 不写任何业务逻辑（如调度、状态机、回调匹配）
- 不实现 Redis 队列 / Pub/Sub 的高层封装（各服务自己写消费者；common 只提供 client factory）
- 不做 CLI 工具 / 管理脚本（属于具体服务）

## Decisions

### 1. 包管理：hatchling + pyproject.toml（不用 setuptools）

- **选择**：`pyproject.toml` + `hatchling` 后端
- **理由**：现代 PEP 621 标准；hatchling 配置最简、无 setup.py 历史包袱
- **替代方案**：poetry（额外锁文件管理对内部库过重）；setuptools（遗留）

### 2. 依赖分发：本地 `pip install -e .`，不发布到 PyPI

- **选择**：v1 通过相对路径 `pip install -e ../isales-common` 引用；CI 通过 git submodule 或 git+ssh URL 装入
- **理由**：内部库无需公开 PyPI；避免搭建私服；多仓库本地开发友好
- **替代方案**：内部 PyPI 服务（未来可选，v1 不必要）；monorepo（已被 `architecture` spec 排除）

### 3. SQLAlchemy 模型：单一 Base + 模块化文件

- **选择**：`isales_common/models/base.py` 定义 `class Base(DeclarativeBase)`；按业务域拆分文件（`campaign.py` / `lead.py` / `call.py` / `device.py` / `agent.py` / `prompt.py` / `callback.py`）
- **理由**：单一 Base 让 alembic autogenerate 能扫描全部 metadata；按域拆分文件控制单文件大小（每个 < 300 行）
- **替代方案**：每张表一文件（过碎，import 链路繁琐）；单文件全部塞（违反单文件规模约束）

### 4. 模型文件分批顺序（避免循环依赖）

按外键依赖链分 3 批：
1. **批次 A（无外键）**：`enums.py`、`base.py`、`agent.py`、`voice_model.py`、`holiday.py`、`device.py`、`sim_card.py`
2. **批次 B（依赖 A）**：`campaign.py`（→voice_model）、`prompt.py`（prompt_version 自引用）、`role_config.py`（→campaign, →prompt_version）、`filler_set.py`、`filler_phrase.py`（→filler_set）、`device_sim_binding.py`、`campaign_device.py`、`callback_config.py`（→campaign）
3. **批次 C（依赖 B）**：`lead.py`（→campaign）、`call_record.py`（→lead, →campaign）、`call_summary.py`（→call_record）、`pipeline_trace.py`（→call_record）、`handoff_task.py`（→call_record, →agent）、`callback_log.py`（→callback_config, →call_record）

### 5. Pydantic Schemas：与 ORM 模型一一对应，分 Create / Update / Read

- **选择**：每个资源出 3 个 schema：`CampaignCreate` / `CampaignUpdate` / `CampaignRead`
  - `Create`：必填字段；不含 `id` / `created_at`
  - `Update`：所有字段 Optional（PATCH 语义）
  - `Read`：完整字段 + 时间戳；`from_attributes=True`（直接由 ORM 转）
- **理由**：明确 API 输入边界；避免"什么都能传"的安全风险
- **替代方案**：单一 Schema 全做（边界模糊）；自动生成（v1 不引入额外工具）

### 6. JSONB 字段的 Pydantic 类型

- **选择**：JSONB 字段在 ORM 用 `Mapped[dict]` / `Mapped[list]`；Schema 用嵌套 Pydantic 模型显式描述（如 `TimeWindow`、`RetryPolicy`、`CallbackTrigger`）
- **理由**：满足 `data-model` spec § Requirement "JSONB 字段需附 schema 文档"——schema 类本身就是文档
- **替代方案**：纯 `dict`（无类型校验，违反 spec）

### 7. Provider ABC：纯异步接口 + Pydantic 输入输出模型

- **选择**：`isales_common/providers/asr.py` / `tts.py` / `llm.py` 各定义一个 ABC
  - `ASRProvider`：`async def stream_recognize(audio_chunks: AsyncIterator[bytes]) -> AsyncIterator[ASRResult]`
  - `TTSProvider`：`async def synthesize_stream(text: str, voice_id: str) -> AsyncIterator[bytes]`
  - `LLMProvider`：`async def chat(messages: list[Message], json_mode: bool, temperature: float, ...) -> LLMResponse`
- **理由**：实时通话场景必然异步流式；JSON Mode 必须作为一等参数（`ai-pipeline` spec 要求强制）
- **替代方案**：同步接口 + executor（性能与连接池管理复杂）；OpenAI 兼容包裹（绑定一家 SDK，违反"切换供应商不改业务代码"目标）

### 8. Redis 消息体 schema 集中在 isales-common

- **选择**：建立 `isales_common/schemas/messages/` 模块，按通道分文件：`dial.py`（DialRequest）、`call_lifecycle.py`（CallEnded）、`engine_control.py`（手动挂断 / 转人工指令）、`engine_event.py`（状态变更 / ASR 文本推送）、`campaign_control.py`（启停）。每个消息类继承 `BaseMessage`（带 `schema_version: int = 1` + `message_id: UUID` + `created_at` 字段）
- **理由**：`service-communication` spec 已经定义了"通道矩阵"（谁发给谁、用 Queue 还是 Pub/Sub），但缺"消息体形状"。如果让各服务自己 dict-stringify，合入第 2 个服务时就会发现字段名不一致 / 类型漂移；最迟在端到端联调时爆。集中到 common 后，编译期（mypy）就能挡住绝大部分 drift。
- **替代方案**：
  - 各服务自己定义消息体 → 几乎必然 drift，已被否决
  - 用 protobuf / msgpack → 序列化复杂、调试不便，v1 用 Pydantic `.model_dump_json()` 足够；后续如有性能需求再换
  - 用 OpenAPI / AsyncAPI 描述消息体 → 多一个工具链层，对单语言项目过重

### 9. utils 模块的边界

- **包含**：号码归一化（E.164）、加解密（Fernet 对称，密钥从环境变量）、Redis client factory（`aioredis.from_url`）、音频格式工具（仅常量与轻量校验，重处理留给 modem-controller）
- **不包含**：HTTP client 包装（各服务用 `httpx` 自己写）、日志格式化（用标准 `logging` + 各服务自配）、配置加载（用 `pydantic-settings`，各服务自己配）

### 10. alembic 初始迁移策略

- **选择**：v1 用一条迁移把 19 张表全部建好（`alembic revision --autogenerate -m "initial schema"` 后人工 review）；后续每次 schema change 走单独的 alembic revision
- **理由**：避免 v1 拆 12+ 个空迁移的历史噪音；初始 schema 一次性 review 更稳
- **替代方案**：分批迁移（与代码 PR 顺序对齐，但增加迁移文件数量与 review 成本）

### 11. 测试策略

- **单元测试**：Provider ABC 契约测试（用内存 mock 实现验证 ABC 不能被遗漏方法实例化）
- **schema 测试**：每个 Pydantic Schema 的边界值（空值、超长、JSONB 嵌套校验）
- **消息 schema 测试**：每个消息类的 round-trip 序列化（`model_dump_json()` → `model_validate_json()` 还原后等值）+ `schema_version` 必填
- **alembic 测试**：CI 中跑 `alembic upgrade head` + `alembic downgrade base` 往返一次
- **不写**：模型间关系测试（留给消费它的服务的集成测试）

## Risks / Trade-offs

| 风险 | 缓解 |
|---|---|
| Provider ABC 设计不当，半年内必须破坏性修改 | 先写 1 个真实供应商的 PoC（如 OpenAI LLM）验证接口足够再合并；ABC 增加 `version` 类常量便于未来检测 |
| 19 张表一次性建模，字段定义错误难发现 | 严格按照 `data-model` spec 表清单 review；每张表对照 spec 表的字段列；CI 跑 schema diff 防止漂移 |
| `pip install -e ../isales-common` 路径硬编码 | 各服务的 `pyproject.toml` 用 `[tool.uv.sources]` 或环境变量解析，文档明确开发环境配置 |
| alembic autogenerate 漏字段 / 误判类型 | 强制 PR 中附 `alembic upgrade head` + 实际 PG schema diff 截图；设 review checklist |
| JSONB 字段的 Pydantic 嵌套模型与 spec 漂移 | 把 Pydantic 模型作为 spec § JSONB 字段约束 的事实文档来源；spec 中只描述结构，schema 类负责强制约束 |
| asyncpg / SQLAlchemy 2 异步 session 的 transaction 边界容易出错 | common 不提供 session 上下文，由各服务自己写 `async_sessionmaker` + DI；提供示例代码 |
| 消息 schema 演进时 producer / consumer 不同步升级导致解析失败 | 每个消息类带 `schema_version` 字段；消息消费者 SHALL 校验版本；破坏性变更 MUST 走 OpenSpec change 并升号；non-breaking 字段加可选 + 默认值 |

## Migration Plan

本次 change 是新建仓库，不涉及现有系统迁移。

部署步骤：
1. 在远端创建 `isales-common` git 仓库
2. 本地 `cd ..; git init isales-common; cp -r ...`，按 tasks.md 顺序提交
3. 推到远端，打 tag `v0.1.0`
4. 后续服务的 `pyproject.toml` 添加依赖：`isales-common = { git = "ssh://...", tag = "v0.1.0" }`

回滚：删除远端仓库 / 撤回 tag；下游服务尚未引入，无连带影响。

## Open Questions

1. **Provider ABC 的错误模型**：每个 Provider 是否定义统一的 `ProviderError` 异常基类？还是各自抛 SDK 原生异常？倾向定义基类便于上层统一处理超时 / 限流。
2. **加解密密钥管理**：v1 用环境变量足够，是否需要为 v2 预留 KMS 接入接口？
3. **是否需要 enum 同步到 PG enum 类型**：v1 倾向用 PG `VARCHAR` + 应用层校验（迁移更简单），v2 再决定是否升级到 PG enum。
