## Why

火山(volcengine/字节)有**两条独立产品线、两套独立密钥**,却被硬塞进同一个 `volcengine` provider_id,导致主 LLM 走 volcengine 时每轮 401、AI 只能播兜底词。实测确认:

- **火山方舟 Ark**(豆包大模型 LLM)需要**独立的 ark API Key**(UUID,实测 `82989d4d-…` 能过 ark 认证);
- **豆包语音 / bytedance openspeech**(ASR/TTS)需要 `app_key + app_token`(+ `tts_resource_id`),与 ark key 完全不同。

`per-role-llm-config`(让 `role_config.ext_params.provider` 真正生效)上线后,LLM 第一次真走 volcengine,踩到三个潜伏 bug:
1. **engine** `providers/factory.py` `build_llm("volcengine")` 把语音的 `app_token` 当 ark LLM key 读 → 必然 401「format incorrect」;
2. **web** `ModelProviderConfig.vue` 把 LLM key 与语音 token 混进同一组 `app_key`/`app_token` 字段(注释误称「app_key+app_token 同时供 LLM/ASR/TTS」),「app token」框名不副实地承载 LLM key,且**没有独立的 ark LLM key 字段**;
3. **DB** `provider_credential` 里 `volcengine` 一个 provider_id 混放 `api_key`/`app_key`/`app_token`/`tts_resource_id`,LLM 与 ASR/TTS 字段语义重叠不清。

根治办法:**按真实产品线把后台凭据配置拆成「模型配置(LLM)」+「语音服务配置(ASR/TTS)」两块**,各 provider 只持有自己的密钥。

## What Changes

- **[isales-common]** `provider_credential` 凭据模型把 volcengine 拆成两个 provider_id:保留 **`volcengine`** = 火山方舟 LLM(持 ark `api_key` + `endpoint` + `default_model`),新增 **`volcengine_speech`** = 豆包语音 ASR/TTS(持 `app_key` + `app_token` + `tts_resource_id` + `endpoint`)。`KNOWN_LLM_PROVIDERS` / `KNOWN_ASR_PROVIDERS` / `KNOWN_TTS_PROVIDERS` 与 `ENV_KEY_MAP` 同步;`tts_resource_id` 纳入 field_name 枚举(此前 DB 有、spec 漏)。
- **[isales-common]** 一次性存量凭据**数据迁移**:把现有 `volcengine` 的语音三件套(app_key/app_token/tts_resource_id)行迁到 `volcengine_speech` provider_id;`volcengine` 仅留 LLM 字段。**无 alembic / 无表结构变更**(纯 `provider_credential` 行 provider_id 改写)。
- **[isales-engine]** `factory.build_llm("volcengine")` 改读 **`api_key`**(ark key)而非 `app_token`(**修掉误读 bug**);`build_asr`/`build_tts` 改读 `volcengine_speech` 的凭据。ASR/TTS provider 解析(`engine_asr_provider`/`engine_tts_provider`)指向 `volcengine_speech`。
- **[isales-web]** `ModelProviderConfig.vue` 拆成两块:**模型配置**(火山方舟[ark api_key + endpoint + 模型ID] 与 阿里通义 DashScope[api_key + endpoint] 并列)+ **语音服务配置**(豆包语音[app_key + app_token + tts_resource_id]),字段各归各位、不再复用同一组输入框。
- **[isales-api]** `/provider-credentials` 的 provider_id 白名单/校验同步新增 `volcengine_speech`;掩码/CRUD 行为不变。

注:本 change 与 `fix-goal-achievement-pipeline`(目标达成,已活体验证、可独立 archive)正交。模型 ID 校验细节(ark 裸名 `doubao-pro-32k` 会 404、需带版本ID或接入点 `ep-xxx`)由「模型配置」卡的 `default_model` 字段承载,创建者自填正确 ID。

## Capabilities

### New Capabilities
<!-- 无新增 capability -->

### Modified Capabilities
- `provider-credential`: 修订「provider_credential 表结构」requirement —— provider_id 应用层枚举区分 LLM 类(`volcengine`/`dashscope`)与语音类(`volcengine_speech`),field_name 枚举补 `tts_resource_id`;新增 scenario 明确 LLM provider 持 ark `api_key`、语音 provider 持 `app_key`/`app_token`,engine `build_llm` 读 LLM provider 的 `api_key`(非 `app_token`)、`build_asr`/`build_tts` 读语音 provider 凭据。
- `web-admin-ui`: 修订模型厂商配置相关 requirement —— 后台拆「模型配置」(LLM provider 卡:火山方舟 + DashScope,各含自己的 key/endpoint/模型ID 字段)与「语音服务配置」(豆包语音卡:app_key/app_token/tts_resource_id),字段不再跨 LLM/语音复用。

## Impact

- **isales-common**: `credentials.py`(CredentialStore / ENV_KEY_MAP)、`providers/` 凭据 field 约定、迁移 CLI(`isales-cred-migrate` 或一次性脚本)。若 bump 版本号则需更 consumer pin(engine/api/worker/scheduler,当前 `>=0.8.x,<0.9`)。
- **isales-engine**: `providers/factory.py`(`build_llm` 读 api_key 修 bug、`build_asr`/`build_tts` 读 `volcengine_speech`)、`KNOWN_*_PROVIDERS`、ASR/TTS provider 解析。
- **isales-web**: `src/views/Config/ModelProviderConfig.vue`(拆两块)、`src/types/llmProviders.ts`、语音 provider 的类型/字段定义。
- **isales-api**: provider-credential router 的 provider_id 白名单/校验。
- **数据 / 部署(prod DB)**: `provider_credential` 行迁移(volcengine 语音字段 → volcengine_speech);把有效 ark key `82989d4d-…` 落到 `volcengine.api_key`;camp1 main 角色 `model` 改为有效 ark 模型ID/接入点。**无 alembic / 无表结构变更**。
- **spec**: provider-credential + web-admin-ui delta;data-model 的 provider_credential 字段/provider_id 枚举若有明文枚举需同步。
