# Remove OpenAI LLM provider + drop mock from UI dropdown

## Why

- **OpenAI 是又死又不可达的能力。** 生产 LLM 实际走 `dashscope`(`deploy/cloud/env/engine.env`: "LLM 用 dashscope")；`api.openai.com` 从国内阿里云 ECS 本就网络不可达。`openai` 作为可配置 provider 一直没人用、也用不了，却散落在前端选择器、凭据配置卡、engine factory、api 白名单、common 迁移工具、多处 spec / deploy 文档里 —— 属典型死代码 + stale 文档。
- **mock 不该出现在客户面选择器。** `mock` 是真测试假 LLM(`KeywordDrivenMockLLM`)，engine 测试 + dev mock 模式(`ISALES_ENGINE_LLM_PROVIDER=mock`)依赖它，但把它摆进 campaign 角色 provider 下拉给管理员选 = footgun(真活动误配成假 LLM)。它在 engine / api 必须保留，但 UI 不该暴露。
- **顺带修一个 stale bug。** `dashscope` 在前端 `BACKEND_IMPLEMENTED` / banner 里仍标「占位·engine 未对接」，但 `factory.build_llm` 早有 dashscope 分支、生产也在用 —— 本 change 一并纠正为「已对接」。

## What Changes

- **前端 SSOT(`isales-web/src/types/llmProviders.ts`)**：`LLM_PROVIDER_IDS` 去掉 `openai` → `[volcengine, dashscope]`；下拉不再含 `mock`(删 `PROVIDER_OPTIONS_WITH_MOCK`)；`BACKEND_IMPLEMENTED` 补 `dashscope`。两个消费方(模型厂商配置 view + campaign 角色选择器)随之同步消失 openai / mock。
- **模型厂商配置 view + 角色 prompt 编辑器**：移除 openai 卡片 / 选项，banner 去掉 openai + dashscope「占位」措辞。
- **后端 engine factory**：`KNOWN_LLM_PROVIDERS` 去掉 `openai`(保留 `mock` + `volcengine` + `dashscope`)；删 `build_llm` 的 openai 分支与 openai 默认 endpoint / model。共享类 `OpenAICompatibleLLMProvider`(volcengine/dashscope 都走它)保留 —— 它是 OpenAI-**兼容协议**实现，不是 openai provider。
- **后端 api 白名单**：`ALLOWED_PROVIDER_IDS` 去掉 `openai`(与 engine `KNOWN_LLM_PROVIDERS` 同步)。
- **common 迁移工具**：`cred_migrate.ENV_KEY_MAP` 删 3 个 `ISALES_OPENAI_*` 映射。
- **测试**：修正会因删分支而真断的 factory / ENV_KEY_MAP 断言(改 dashscope)；relabel 把 openai 当「已知 provider」列举的 registry / settings / CredentialStore 测试。保留纯 OpenAI-兼容协议层(error-mapper / 直构共享类)测试。
- **spec delta**：`web-admin-ui` provider 选项 scenario(provider 列表 + mock 不暴露)、`provider-credential` env / `build_openai` 措辞。
- **deploy 文档**：cloud `engine.env.example` Known-providers 行、RUNBOOK-cloud / cloud README / SECRETS 里把 openai 作为「当前 provider」的列举去掉。

## Impact

- Affected specs: `web-admin-ui`(MODIFIED), `provider-credential`(MODIFIED).
- Affected code: `isales-web`(3 files), `isales-api`(1 router + 1 test), `isales-engine`(factory + 4 tests + settings/class docstrings), `isales-common`(cred_migrate + 3 tests + _errors docstring), `deploy/`(4 docs).
- **No data migration / no alembic.** `provider_credential` 表里若有历史 `openai` 行(生产无)会变成 inert(api 不再接受写、engine 不再读)；不主动删，零风险。
- **mock 在 engine / api 保留** —— 测试 + dev mock 模式不受影响。
- 非破坏性：volcengine / dashscope 两个真 provider 全程不动。
