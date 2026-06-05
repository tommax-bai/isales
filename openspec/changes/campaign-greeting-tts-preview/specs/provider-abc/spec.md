## MODIFIED Requirements

### Requirement: Provider ABC 集中定义在 isales-common

ASR / TTS / LLM 三类外部服务的接口契约 SHALL 以抽象基类（ABC）形式集中定义在 `isales-common/providers/` 模块。供应商的真实实现 MUST 继承这些 ABC；其代码 MAY 位于 `isales-engine/providers/`（仅 engine 使用时），但当某真实实现需被一个以上服务（如 isales-engine 与 isales-api）共用时，该实现 SHALL 下沉到 `isales-common/providers/`，由各服务从共享 `CredentialStore` 统一构建，MUST NOT 在消费方各自复制一份 vendor 协议实现。

#### Scenario: 切换供应商不改业务代码

- **WHEN** 需要从供应商 A 切到供应商 B
- **THEN** 仅替换继承 ABC 的真实实现类；任何依赖 ABC 的业务代码（编排、状态机、tools）MUST 不需修改

#### Scenario: 实现类必须继承 ABC

- **WHEN** 引入新的真实供应商实现
- **THEN** 该实现 MUST 继承对应的 ABC 并实现全部抽象方法；MUST NOT 自定义平行接口绕过 ABC

#### Scenario: 跨服务共用的实现下沉 common

- **WHEN** 一个真实供应商实现需被多个服务（如 engine 合成播音 + api 试听合成）调用
- **THEN** 该实现 SHALL 位于 `isales-common/providers/`，各服务从 `isales_common.credentials.CredentialStore` 构建同一实现；MUST NOT 在某一服务内复制等价的 vendor 客户端
