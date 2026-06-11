## Context

引擎当前为**整个进程**构建一个全局 LLM client:`main.py:206` `providers.llm = build_llm(settings.engine_llm_provider, store=credentials)`,且不传 model(用 credential 的 default_model)。`run_loop.py` / `orchestrator.py` 里所有 `PipelineStream` 都把这同一个 `providers.llm` 同时当 `main_llm` 和 `referee_llm` 传入;`_generate_core` 的 `chat_stream` 只透传 temperature/top_p。

数据契约:`isales_common.models.RoleConfig` 有 `model`(String 列)+ `ext_params`(JSONB),**无 `provider` 列**。前端 `PromptTierEditor` 把用户选的 provider 写进 `ext_params.provider`(`PromptTierEditor.vue:286` 读 / `:355` 写),model 写进 `role_config.model` 列。`isales_common.schemas.pipeline._SlotSpec` 只有 `model`(默认 `"mock"`)+ temperature,**无 `provider`**。`runtime_config._spec_for` 把 `rc.model` 放进 spec,但忽略 `ext_params.provider`,且没人把 spec.model thread 进 LLM 实例。

restructure:引擎已完整支持(`_restructure_spec` 取首条 `kind=restructure`,decider degrade,`run_restructure_stream` 可跑),但前端无创建/编辑入口(`RoleConfigDialog` 在未挂载的孤儿 `RoleConfigTab` 里);API `routing_validation._LABELLED_KINDS` 含 `RESTRUCTURE`,要求其带 label,而引擎用 singleton + 内建路由不靠 label。

## Goals / Non-Goals

**Goals:**
- 每个 LLM slot(main / referee / persona / extractor / restructure)按其 role_config 的 `provider`(= `ext_params.provider`)+ `model`(= `role_config.model` 列)选用对应 LLM,运营在卡上选的厂商+模型真实生效。
- restructure 的 prompt/provider/model 可在场景配置页编辑(单条 singleton 卡)。
- 全链路保持**单一**回落语义:slot 未配 provider/model 时回落到一个全局默认 client,不堆叠多层兜底。

**Non-Goals:**
- 不改 restructure 的触发条件 / decider / 路由语义(引擎已支持)。
- 不动 ASR / TTS 的 provider 选择机制(本 change 只针对 LLM slot)。
- 不为 provider 新增数据库列(沿用既有 `ext_params.provider`,无 alembic 迁移)。
- 不清理 RoutingRulesTab 里的"重组(旧)"legacy action-type(removal-tracked shim,留后续)。

## Decisions

### D1. provider 的 SSOT = `ext_params.provider`,不新增列
**选择**:provider 继续存在 `role_config.ext_params["provider"]`(前端已这么写),model 继续用 `role_config.model` 列。两者一起 thread 进 `_SlotSpec`(给 `_SlotSpec` 新增 `provider: str | None` 字段)。
**理由**:前端早已把 provider 写进 ext_params;新增专用列要 alembic 迁移 + 双写迁移期,收益只是"语义更正式",不值当。`ext_params` 本就是 JSONB 自由位。
**Alternative(否决)**:给 RoleConfig 加 `provider` 列 → 需迁移 + 回填 + 前端改写入位置,范围和风险都更大,无对应收益。

### D2. 引擎按 `(provider, model)` 解析并**缓存** LLM client,而非给 `chat_stream` 加 model 参数
**选择**:引擎持有一个轻量 LLM client 注册表(registry),`get(provider, model)` 惰性 `build_llm(provider, store=credentials, model=model)` 并按 `(provider, model)` 缓存复用。`run_loop` / `orchestrator` 在构造某个 slot 的 `PipelineStream` 前,用该 slot 的 spec 解析出 client 传入(`PipelineStream` 签名仍收一个 llm,改的是"谁来传")。
**理由**:不同 provider 的 client 不只是 model 不同——base_url / auth / 协议都不同,光给 `chat_stream` 加 `model=` 参数解决不了跨 provider;按 `(provider, model)` 缓存 client 才是正解。缓存避免每轮重建 HTTP client。
**Alternative(否决)**:① 改 `LLMProvider.chat/chat_stream` ABC 增加 `model` 参数 → 只能切 model 不能切 provider,且污染所有 provider 实现;② 每个 slot 每轮新建 client → 浪费连接。

### D3. 单一全局默认,不堆叠兜底
**选择**:registry 在 `provider` 为空(role 没配)或该 provider 无可用 credential 时,回落到**唯一**的全局默认 `engine_llm_provider` client(进程启动时构建一次)。该回落带注释写明触发场景(role 未配 provider / credential 缺失)与移除条件(当 provider 成为 role_config 必填且 UI 强制选择后可移除回落分支)。
**理由**:符合 CLAUDE.md「多层兜底是问题味道」——只保留**一层**默认解析,且默认本身是合理的"未配置即用引擎默认模型"产品语义,不是 just-in-case 补丁。
**Alternative(否决)**:per-provider + per-slot 各自独立 fallback 链 → 多层兜底,违反硬约束。

### D4. restructure 归一为 singleton,API 放宽 label
**选择**:前端 restructure 卡用 `singleton`(镜像 extractor);API 从 `routing_validation._LABELLED_KINDS` 移除 `RESTRUCTURE`,restructure role_config 不再强制 label。引擎不变(已是 `_first` + 内建路由)。
**理由**:引擎按首条取 + 路由走内建 `restructure`(不靠 label),要求 label 是 vestigial。用户也确认 restructure 是单条。
**Alternative(否决)**:沿用 referee 那种 labeled 卡 → label 字段对 restructure 永远没用,留下 vestigial 必填项。

### D5. restructure 卡复用既有 PromptTierEditor,零新组件
**选择**:`CampaignDetail.vue` 加 `<PromptTierEditor kind="restructure" singleton .../>`,文案 + 图标 + badge-color 按既有四卡风格补。即时保存链路(role_config + prompt_version upsert)PromptTierEditor 已内建,无需新 API。
**理由**:PromptTierEditor 已是 kind 参数化通用卡(含 prompt 正文 + provider/model + temp/top_p + singleton 形态),restructure 是纯增量实例化。

## Risks / Trade-offs

- [运营既有 campaign 的 model 选择从"被忽略"变"生效",可能悄悄换掉实际模型] → 发布说明提示运营核对各角色 provider/model;D3 的全局默认确保"未配 provider"的角色行为不变(仍走 engine 默认)。
- [运营给 referee 误选了慢/贵的大模型,门控延迟上升] → 超出本 change 范围(配置自由的固有代价);可在 UI hint 提示 referee 宜用小模型,但不强制。
- [所选 provider 在 provider_credential 表里没凭据 → 运行期取不到 client] → registry 回落到全局默认 client 并 WARN 日志,绝不 crash 通话(fail-open)。
- [_SlotSpec 加 `provider` 字段 = isales-common 契约变更] → bump 版本 + 更新六个消费仓的 pin;字段可空,旧数据/旧消费方不破。
- [缓存的 client 持有 HTTP 连接,长寿进程内 (provider,model) 组合膨胀] → 组合数受 campaign 配置约束(每 campaign ≤5 角色 × 有限 provider/model),实际很小;按需可加 LRU 上限,本期不必。

## Migration Plan

1. **isales-common**:`_SlotSpec` 加 `provider: str | None`;bump 版本;`pip install -e` 各消费仓更新 pin。
2. **isales-engine**:加 LLM registry(按 (provider,model) 缓存 + 全局默认回落);`_spec_for` 读 `ext_params.provider` → spec.provider;`run_loop`/`orchestrator` 按 slot spec 解析 client 传入 PipelineStream。**无 alembic**。
3. **isales-api**:`routing_validation` 移除 `RESTRUCTURE` ∈ `_LABELLED_KINDS`;确认 campaign 嵌套写接受 `kind=restructure`。
4. **isales-web**:`CampaignDetail.vue` 加 restructure 卡。
5. 部署顺序:common → engine(scp 覆盖 + `systemctl restart isales-engine`,按 `feedback_ecs_deploy_scp`)→ api → web 构建发布。**Rollback**:重部署前一版;因无迁移、新字段可空,回滚无数据风险。
6. 真机抽验:配一个非默认 provider/model 的角色 + 一个 restructure 角色,mac dev e2e 验证各 slot 用对模型 + restructure 路由真触发。

## Open Questions

- provider 是否最终提升为 role_config 正式列?(本期否决,`ext_params.provider` 为 SSOT;若未来要做 provider 维度的查询/约束再议。)
- 是否在 API 保存时校验所选 provider 有可用 credential(早失败而非运行期回落)?(可作为软校验后续加,本期靠运行期 WARN + 回落。)
