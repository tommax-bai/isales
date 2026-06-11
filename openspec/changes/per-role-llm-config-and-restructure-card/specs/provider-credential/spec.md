## ADDED Requirements

### Requirement: 引擎按 slot provider 解析 LLM 凭据

`isales-engine` 启动期已从 `provider_credential` 全表装载多 provider 凭据到进程内 store（见 Requirement「凭据 DB 是单一事实来源」）。在此基础上，engine SHALL 在为每个 LLM slot 选用 LLM client 时，按该 slot 的 provider 从 store 解析对应凭据（`api_key` / `app_key` / `endpoint` / `default_model` 等），而非只为单一 `engine_llm_provider` 解析。slot 的 model 缺省（空 / 占位）时 SHALL 用该 provider 凭据的 `default_model`。所选 provider 在 store 中无可用（缺失或 disabled）凭据时，engine SHALL 回落到全局默认 provider 的 client 并写 WARN 日志，MUST NOT crash 通话。

#### Scenario: 多 provider 凭据按 slot 解析

- **WHEN** 一通通话里 main slot 配 provider=`volcengine`、referee slot 配 provider=`dashscope`，两者在 `provider_credential` 均有 enabled 凭据
- **THEN** engine SHALL 分别用各自 provider 的凭据构建 / 复用对应 LLM client，各 slot 互不影响

#### Scenario: slot model 缺省用 provider default_model

- **WHEN** 某 slot 配了 provider 但 model 为空 / 占位
- **THEN** engine SHALL 用该 provider 凭据的 `default_model` 作为该 slot 的 model

#### Scenario: 所选 provider 凭据缺失回落

- **WHEN** slot 配的 provider 在 store 中无 enabled 凭据
- **THEN** engine SHALL 回落到全局默认 provider client 并写 WARN（标明 slot + 缺失 provider）
- **AND** MUST NOT 抛错中断通话
