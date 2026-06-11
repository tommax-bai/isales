## ADDED Requirements

### Requirement: 每个 LLM slot 按 role_config 的 provider + model 选用 LLM

engine SHALL 为每个 LLM slot（main / referee / persona / extractor / restructure）按其 role_config 配置的 **provider**（SSOT = `role_config.ext_params.provider`）+ **model**（`role_config.model` 列）选用对应的 LLM client，而非所有 slot 共用单一进程级全局 LLM。engine SHALL 按 `(provider, model)` 惰性构建并缓存 LLM client（避免每轮 / 每 slot 重建）；凭据由 provider-credential store 按 provider 解析（见 provider-credential spec）。

当某 slot 的 role_config 未配置 provider（`ext_params.provider` 缺失或空）时，engine SHALL 回落到**唯一**的全局默认 LLM（由 `engine_llm_provider` 构建一次）。该回落是单层默认解析，MUST NOT 为单个 slot 叠加多层兜底分支。

`_SlotSpec` SHALL 携带可空 `provider` 字段，由 `runtime_config` 从 `ext_params.provider` 读出并 thread 至 LLM 选用。restructure 为 singleton：engine SHALL 取首条 `kind=restructure` role_config 作为 restructure slot，且该 role_config MUST NOT 被要求填写 label（走内建路由 `restructure`，不按 label 路由）。

#### Scenario: slot 用自己配置的 provider + model

- **WHEN** 某 slot 的 role_config 配了 provider=`P` + model=`M`，且 `provider_credential` 有 `P` 的 enabled 凭据
- **THEN** engine SHALL 用 `(P, M)` 对应的 LLM client 发起该 slot 的 `chat` / `chat_stream`
- **AND** 不同 slot 配不同 provider / model 时各用各的，互不影响

#### Scenario: 未配 provider 回落全局默认（单层）

- **WHEN** 某 slot 的 role_config 没有 `ext_params.provider`（或为空）
- **THEN** engine SHALL 用全局默认 LLM（`engine_llm_provider`）服务该 slot
- **AND** 该回落为唯一一层，MUST NOT 叠加额外兜底分支

#### Scenario: (provider, model) client 缓存复用

- **WHEN** 同一 `(provider, model)` 组合被多个 slot 或多轮调用
- **THEN** engine SHALL 复用已缓存的 LLM client，MUST NOT 每轮 / 每 slot 重建

#### Scenario: restructure 取首条且不需 label

- **WHEN** campaign 配了一条或多条 `kind=restructure` role_config
- **THEN** engine SHALL 取首条作为 restructure slot
- **AND** 该 role_config MUST NOT 被要求填写 label
