## Why

每个 AI 角色(`role_config`)在管理后台都能填 provider / model / prompt,但其中两件事是**断的**:

1. **per-slot provider/model 全程不生效**:引擎为整个进程构建**单一**全局 LLM client(`isales-engine main.py:206` `build_llm(settings.engine_llm_provider)`),所有 slot(main / referee / persona / extractor / restructure)的 `PipelineStream` 都复用它,`chat_stream` 只透传 temperature/top_p、**从不读** `spec.model` / `ext_params.provider`。结果:运营在卡上选的模型/厂商是**摆设**,全部角色实际都跑同一个 env 里写死的全局模型。

2. **restructure(重组)在 UI 里没有配置入口**:`CampaignDetail.vue` 只挂了 main/persona/referee/extractor 四张 `PromptTierEditor` 卡;唯一能建 restructure 角色的 `RoleConfigDialog` 在未挂载的孤儿组件 `RoleConfigTab` 里。引擎其实已完全支持 restructure(`_restructure_spec` 取首条 `kind=restructure` role_config,decider 在无 slot 时 degrade 成 continue),所以重组现在是"门控路由能选、运行时永远空转"的半成品——**缺的只是前端创建/编辑入口**。

这两件事合起来,是同一个根因的两面:**role_config 配置没有端到端生效**。本 change 把这条链路接通。

## What Changes

- **引擎按 role_config 的 provider + model 选用 LLM**:`provider`(SSOT = `role_config.ext_params.provider`)+ `model`(`role_config.model` 列)thread 进 `_SlotSpec`,引擎按 `(provider, model)` 解析对应 credential 并实例化/复用对应 LLM client,每个 slot 用自己配的厂商+模型。保留一个**单一**全局兜底(角色未配 provider/model 时回落到 `engine_llm_provider`),不堆叠多层。
- **前端新增 restructure 配置卡**:`CampaignDetail.vue` 增加一张 `PromptTierEditor` 卡(`kind="restructure"`,`singleton`,镜像 extractor 卡:单条、prompt 正文 + provider/model + temperature/top_p),接进既有 role_config 即时保存链路。
- **restructure 契约归一为 singleton**:引擎走首条 + 内建路由 `restructure`(不靠 label 路由),故 API 放宽 restructure 的 label 必填要求(从 `_LABELLED_KINDS` 移除 `RESTRUCTURE`),与"单条、无需标识"对齐。
- **不改 restructure 的触发/decider/路由语义**:引擎已支持,本 change 只让它"可配 + 选到对应模型"。

## Capabilities

### New Capabilities
<!-- 无新增 capability;均为既有能力的修订 -->

### Modified Capabilities
- `ai-pipeline`: 每个 LLM slot SHALL 按其 role_config 的 provider + model 选用对应 LLM(取代"所有 slot 共用单一全局 engine LLM");restructure slot 明确为 singleton(引擎取首条 `kind=restructure`)。
- `web-admin-ui`: 场景配置页 SHALL 提供 restructure 的 prompt/provider/model 配置卡(单条、无需 label);使既有 spec「restructure 与 main/referee/extractor 并列可配」从声明落到实现。
- `provider-credential`: 引擎 SHALL 按 slot 的 provider 从已装载的凭据 store 解析对应 LLM client(而非只用单一 `engine_llm_provider`);provider 未配或 credential 缺失时回落到全局默认 provider。

<!-- role-prompt 未列入:restructure prompt 内容规范(已存在)不变;per-role provider/model 的运行时遵循属 ai-pipeline 行为,非 prompt 内容语义。 -->


## Impact

- **isales-engine**: `main.py`(LLM 构建)、`runtime_config.py`(`_spec_for` 读取 provider/model 进 spec)、`pipeline/orchestrator.py` + `run_loop.py`(`PipelineStream` 按 slot 选 LLM)、`providers/factory.py`(按 provider 构建/缓存 client)。**无 alembic 迁移**(provider 复用既有 `ext_params` JSONB,model 列已存在)。
- **isales-common**: `schemas/pipeline.py` `_SlotSpec` 增加 `provider` 字段(承载各 slot 的厂商);版本号 bump + 消费方 pin。
- **isales-api**: `routing_validation.py` 从 `_LABELLED_KINDS` 移除 `RESTRUCTURE`;确认 campaign 嵌套写接受 `kind=restructure` role_config。
- **isales-web**: `CampaignDetail.vue` 增加 restructure 卡;`PromptTierEditor.vue` 复用(已支持 provider/model/prompt + singleton)。
- **运营可见行为变化**:角色卡上选的 provider/model 从此真实生效(此前被忽略)——属于行为修正,需在发布说明中提示运营核对既有 campaign 的角色模型选择。
- **Non-Goals**: 不动 restructure 触发/路由语义;不动 ASR/TTS 的 provider 选择;不清理"重组(旧)"legacy action-type(removal-tracked shim,留后续)。
