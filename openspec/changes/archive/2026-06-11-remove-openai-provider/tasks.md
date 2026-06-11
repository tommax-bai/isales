# Tasks — remove-openai-provider

<!-- Implemented + verified 2026-06-11. Sub-repo commits:
     web 1e5981b / api a5ec948 / engine a17b253 / common faef51b.
     Verify: web tsc clean + vitest 88/88, engine 404 passed, common 181/181,
     api 110 passed (provider-credential 11/11). 3 full-suite reds are
     pre-existing + stash-confirmed unrelated (engine gate flakiness + api
     redis-steal by _isales legacy daemons). openspec validate --strict ok. -->

## 1. Frontend (isales-web) — 1e5981b

- [x] 1.1 `src/types/llmProviders.ts`：`LLM_PROVIDER_IDS` 去 openai；删 `PROVIDER_OPTIONS_WITH_MOCK` / `PromptTierProviderId`(下拉改用 `LLM_PROVIDER_IDS`)；`BACKEND_IMPLEMENTED` = {volcengine, dashscope}；`LABEL` / `DEFAULT_MODEL` / `DEFAULT_ENDPOINT` 删 openai + mock；更新头部 SSOT 注释
- [x] 1.2 `src/views/Config/ModelProviderConfig.vue`：`PROVIDER_PRESENTATION` 删 openai 条 + dashscope 去「占位」措辞；banner 改「已对接 volcengine + dashscope」；ProviderForm 注释去 openai
- [x] 1.3 `src/components/Campaign/PromptTierEditor.vue`：import 改 `LLM_PROVIDER_IDS` / `LLMProviderId`；`PROVIDERS = LLM_PROVIDER_IDS`；两处 `as PromptTierProviderId` → `as LLMProviderId`；更新注释

## 2. Backend (engine a17b253 / api a5ec948 / common faef51b)

- [x] 2.1 `isales-engine/providers/factory.py`：`KNOWN_LLM_PROVIDERS` 去 openai；`_DEFAULT_ENDPOINT` / `_DEFAULT_MODEL` 删 openai；删 `build_llm` openai 分支；docstring 去 openai
- [x] 2.2 `isales-engine/providers/llm_openai_compatible.py`：docstring 示例去掉 openai.com（保留类名 = OpenAI-兼容协议名，volcengine/dashscope 共用）
- [x] 2.3 `isales-engine/settings.py`：模块 docstring 注释 openai → dashscope
- [x] 2.4 `isales-api/routers/provider_credentials.py`：`ALLOWED_PROVIDER_IDS` 去 openai（保留 mock 与 engine 同步）；字段注释去 openai
- [x] 2.5 `isales-common/cli/cred_migrate.py`：`ENV_KEY_MAP` 删 3 个 `ISALES_OPENAI_*`
- [x] 2.6 `isales-common/providers/_errors.py`：docstring `e.g. "openai"` → `"volcengine"`

## 3. Tests

- [x] 3.1 `isales-engine/tests/test_providers.py`：openai→dashscope；删冗余 `test_factory_builds_openai_llm_from_store`（与 dashscope 版同路径）
- [x] 3.2 `isales-engine/tests/test_provider_errors.py`：factory 段 openai→dashscope(`test_build_llm_dashscope_with_credentials`, model override qwen-max, require-cred match)；error-mapper / `_stream_provider` 共享协议类标签保留
- [x] 3.3 `isales-engine/tests/test_llm_registry.py`：fake-builder 标签 openai/gpt-4o → volcengine/doubao-pro
- [x] 3.4 `isales-engine/tests/test_skeleton.py`：`ISALES_ENGINE_LLM_PROVIDER` openai→dashscope
- [x] 3.5 `isales-common/tests/test_credentials.py`：populated store + providers() 集合 openai→dashscope
- [x] 3.6 `isales-common/tests/test_cli_cred_migrate.py`：删 `test_openai_keys_present`
- [x] 3.7 `isales-api/tests/test_provider_credentials.py`：openai→dashscope(idempotent / list-filter / delete)

## 4. Deploy docs (meta-repo)

- [x] 4.1 `deploy/cloud/env/engine.env.example`：Known providers 去 openai
- [x] 4.2 `deploy/RUNBOOK-cloud.md` / `deploy/cloud/env/README.md` / `deploy/cloud/env/SECRETS.md.example`：prose 列举去 openai（RUNBOOK 迁移段删 ISALES_OPENAI_* sed 保留，作 legacy 清理）

## 5. Spec deltas (meta-repo)

- [x] 5.1 `specs/web-admin-ui/spec.md`：MODIFIED「已 spec 能力的 UI 暴露」provider 选项 scenario（volcengine/dashscope + mock 不暴露）
- [x] 5.2 `specs/provider-credential/spec.md`：MODIFIED「凭据 DB 是单一事实来源」env 示例 + build_openai → build_dashscope

## 6. Verify + archive

- [x] 6.1 test 全绿(web tsc+vitest / engine / api / common pytest 本 change 触及范围) + straggler grep CLEAN + `make deploy-check`(失败=pre-existing modem-controller env drift，与本 change 无关)
- [x] 6.2 `openspec validate remove-openai-provider --strict` → valid
- [ ] 6.3 archive(合并 deltas → specs/，验证目录已 move)
- [ ] 6.4 commit + push(4 sub-repo done + meta pending)
