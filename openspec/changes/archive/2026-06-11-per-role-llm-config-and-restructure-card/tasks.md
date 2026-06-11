## 1. isales-common — `_SlotSpec.provider` 契约

- [x] 1.1 `schemas/pipeline.py`：给 `_SlotSpec` 增加 `provider: str | None = None` 字段（子类自动继承）。<!-- 同时把 RestructureSpec.label 改为可选 str|None=None（D4 restructure 不需 label）-->
- [x] 1.2 bump `isales-common` 0.8.8 → 0.8.9（pyproject）。<!-- consumers pin >=0.8.8,<0.9 已覆盖 0.8.9，无需改 pin；editable install 源即生效 -->
- [x] 1.3 common schema 测试通过（`-k "pipeline or spec or slot"` 10 passed）+ sanity：MainSpec(provider=...) / RestructureSpec(无 label) 构造 OK

## 2. isales-engine — per-(provider, model) LLM 选用 + 单层回落

- [x] 2.1 新增 `providers/llm_registry.py` `LLMRegistry`：`resolve(provider,model)` 惰性 `build_llm(...,model=model)` + 按 `(provider,model)` 缓存；provider 空/缺凭据 → 唯一全局默认回落（注释含触发场景 + 移除条件）；`resolve_spec` + `aclose_all`（per-call 释放）
- [x] 2.2 `main.py`：`default_llm` 复用为 registry fallback，构建 `LLMRegistry(store=credentials, default_provider=engine_llm_provider, default_client=default_llm)` 进 `Providers`；finally 改 `registry.aclose_all()`（关 default + 全部缓存 client）
- [x] 2.3 `runtime_config.py:_spec_for`：读 `rc.ext_params["provider"]` → 4-tuple `(provider,model,prompt,pv_id)`，5 个 builder 均透传 `provider=`
- [x] 2.4 `run_loop` Providers 加 `llm_registry` 字段 + `llm_for(spec)` helper；6 调用点（main/persona/winner/wrap-up/restructure/greeting）传 `llm_registry=providers.llm_registry`；`orchestrator.PipelineStream` 加 `llm_registry` kwarg：构造时按 main/restructure slot 解析 `_main_llm`，`start()` 里 **per-referee** 解析。transfer-LLM(:663) 仍用全局默认（Non-Goal）
- [x] 2.5 缺凭据/未知 provider → registry WARN `llm_slot_provider_fallback` + 回落，不中断（已含在 2.1，测试覆盖）
- [x] 2.6 common pin 无需改（engine/api `>=0.8.8,<0.9` 已覆盖 0.8.9，editable 源即生效）
- [x] 2.7 `tests/test_llm_registry.py` 8 测：①provider/model 用对 client ②未配→默认 ③缺凭据→回落+WARN ④缓存命中不重建 ⑤resolve_spec + aclose_all。<!-- runtime_config provider-threading 靠 import sanity + 真机 e2e(5.2)，现有测试全 mock load_runtime_config 无 DB fixture，一行 ep.get 不值当建 DB 测 --> restructure 取首条由既有测试覆盖
- [x] 2.8 `pytest -q` 全套：**405 passed, 1 failed**；唯一失败 `test_gating::test_gate_fails_open_to_main_on_referee_timeout` 经 `git stash` 甄别为 **pre-existing**（与本 change 无关，registry=None 时 no-op）

## 3. isales-api — restructure label 契约放宽

- [x] 3.1 `routing_validation.py`：`_LABELLED_KINDS` 去掉 `RESTRUCTURE`（→ `{REFEREE, PERSONA}`）；更新顶部 docstring + `validate_role_labels` docstring + `_label_namespace`（"referee_restructure" → "referee"）
- [x] 3.2 确认 `schemas.py` `RoleConfigNestedWrite.label` 为 `str | None = None`（可空）→ kind=restructure 无 label 通过 schema + 不再被 `validate_role_labels` 拦
- [x] 3.3 新增 `test_restructure_without_label_accepted`；referee/persona 无 label 仍 422。routing 子集 **20 passed**。<!-- 全套 109 passed / 2 failed = test_campaign_start_pause（git stash 甄别为 pre-existing 的 api redis-steal，与本 change 无关）-->

## 4. isales-web — restructure 配置卡

- [x] 4.1 `CampaignDetail.vue`：referee 卡后新增 `<PromptTierEditor kind="restructure" singleton title="重组 (restructure)" badge-color="gray" :icon="RefreshCw" plain-icon />` + 导入 `RefreshCw`
- [x] 4.2 确认 PromptTierEditor `kind="restructure"` + `singleton` 行为：`solo`(:298) 无配置自动补一行、provider 写 `ext_params.provider`(:355)、非 labeled 不写顶层 label、save 用 `props.kind`。RoleKind 类型含 restructure
- [x] 4.3 `tests/promptTierEditor.test.ts` 新增 restructure 测试（保存 kind=restructure + ext_params.provider=dashscope + 不带 label）；该文件 14 passed，全套 **88 passed (17 files)**，`vue-tsc --noEmit` CLEAN
- [~] 4.4 浏览器点验（best-effort）→ 并入 Task 5 真机部署验收（需 web 起服务）

## 5. 部署 + 真机验收

- [x] 5.1 全栈部署 ECS（scp editable 源码，engine+api 共用 venv / common editable 一处两端）：common pipeline.py + engine 5 文件(含新 llm_registry.py) + api routing_validation.py → ast-parse + import smoke(`LLMRegistry` OK + `_SlotSpec.provider=True`) → restart engine+api（`credentials_loaded count=5 providers=['dashscope','volcengine']`+`isales_engine_started` clean、api active）。web build(entry `index-BlidkFk7.js`) → scp dist → nginx `/`→200。`deploy/cloud/STATE.md` 已更新（本条提交）
- [~] 5.2 真机抽验 per-slot provider — **DEFERRED（用户决定 2026-06-11）**：服务级已验（import smoke + 服务 active + 单测 8 绿）；真机拨测（配非默认 provider → dial → 看 `llm_slot_provider_fallback`/resolution 日志）延后到未来 mac dial session，走 `[[project-session-2026-06-10-mac-call-test]]` 流程
- [~] 5.3 真机抽验 restructure — **DEFERRED（用户决定 2026-06-11）**：引擎逻辑已由既有测试 + decider degrade 覆盖；真机（新卡建 restructure 角色 + 路由规则 → barge-in 验重组真触发）延后

## 6. 收口

- [x] 6.1 各仓 pytest/vitest 全绿（common 10 / engine 405 / api routing 20 / web 88）；3 个失败全 `git stash` 甄别为 pre-existing（engine gate ×1 + api redis-steal ×2），与本 change 无关
- [x] 6.2 `openspec validate per-role-llm-config-and-restructure-card --strict` 通过
- [x] 6.3 root doc-sync：DESIGN.md/README 未 pin「所有 slot 共用全局 LLM」（属 engine 内部实现，root 只索引 ai-pipeline spec）→ 无 root 漂移；spec 变更随 archive 合入
- [x] 6.4 4 sub-repo commit+push origin/main：common `0c48d5a` / engine `87cc26f` / api `5523f7b` / web `cc516ba`；meta tasks.md + STATE.md 回写（本条提交）。**archive 待 5.2/5.3 真机验收后做**
