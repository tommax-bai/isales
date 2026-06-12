## Context

实测定位(见 `fix-goal-achievement-pipeline` 真机验收):camp1 主 LLM 走 volcengine 每轮 401、AI 只播兜底词。根因是火山两条产品线两套密钥被混进一个 `volcengine` provider_id。当前 DB `provider_credential` 里 `volcengine` 各 field 的**实际用途**:

| field | 当前实际承载 | 谁读 |
|---|---|---|
| `api_key`(36 UUID) | **豆包语音**新版控制台 X-Api-Key | ASR/TTS(`tts_volcengine` `store.get("volcengine","api_key")`) |
| `app_key` | 语音旧版控制台 | ASR 旧模式 |
| `app_token` | 语音旧版控制台 | ASR 旧模式 **+ `build_llm("volcengine")` 误当 ark key 读** |
| `tts_resource_id` | TTS 资源 ID | TTS |

**没有任何 field 放 ark LLM key** —— 而 ark(火山方舟豆包大模型)需要一把独立的 ark API Key(UUID,如 `82989d4d-…`,实测过认证)。

## Goals / Non-Goals

**Goals:**
- 按真实产品线把后台凭据拆成「模型配置(LLM)」+「语音服务配置(ASR/TTS)」,各 provider 只持自己的密钥。
- 给火山方舟 LLM 一个独立的 ark key 字段;修掉 `build_llm("volcengine")` 误读 `app_token` 的 bug。
- 存量凭据无损迁移(语音三件套搬到新 speech provider_id;ark key 落到 LLM provider 的 api_key)。

**Non-Goals:**
- 不改 `provider_credential` 表结构 / 不出 alembic(纯数据行迁移 + 应用层枚举)。
- 不改 Fernet 加密 fabric / 掩码 / CRUD HTTP 契约。
- 不引入新 LLM/语音厂商(仅拆分既有 volcengine)。
- 不在本 change 解决 ark 模型 ID 校验(裸 `doubao-pro-32k` 404 → 创建者在「模型配置」卡 `default_model` 填带版本 ID 或接入点 `ep-xxx`;这是数据填写,非代码)。

## Decisions

**D1 — provider_id 拆分:保留 `volcengine`=火山方舟 LLM,新增 `volcengine_speech`=豆包语音 ASR/TTS。**
保留 `volcengine` 当 LLM id:web LLM SSOT(`llmProviders.ts`)+ role_config.ext_params.provider 已用 `volcengine`,改动面最小;语音单开新 id 语义最清。备选(全部重命名 `volcengine_ark`+`volcengine_speech`)否决——LLM 侧 role_config 存量 provider 值都要迁,代价大、收益小。命名细节见 Open Q1。

**D2 — engine factory 读字段对齐(含修 bug):**
- `build_llm("volcengine")` 读 `store.get("volcengine","api_key")`(ark key),**不再读 `app_token`**。
- `build_asr`/`build_tts` 读 `volcengine_speech` 的 `api_key`(新版 X-Api-Key)/ `app_key`+`app_token`(旧版)/ `tts_resource_id`。
- `KNOWN_LLM_PROVIDERS={mock,volcengine,dashscope}` 不变;`KNOWN_ASR_PROVIDERS`/`KNOWN_TTS_PROVIDERS` 由 `{mock,volcengine}` 改 `{mock,volcengine_speech}`。

**D3 — 存量凭据迁移(关键,无 alembic):**
1. 现 `volcengine.api_key`(语音 UUID)/`app_key`/`app_token`/`tts_resource_id` 四行 → 改 `provider_id='volcengine_speech'`(field_name 不变)。
2. **新写** `volcengine.api_key` = ark key `82989d4d-…`(LLM 用)。
3. `volcengine` 仅留 `api_key`(ark)+`endpoint`+`default_model`(default_model 改为有效 ark 模型ID/接入点)。
迁移走 `isales-cred-migrate`(或一次性 psql + CredentialStore 加密,**不能裸 SQL** —— cipher_text 必须 Fernet 加密)。engine 重启后按新布局装载。

**D4 — web 拆两块卡:** `ModelProviderConfig.vue` 分「模型配置」(火山方舟[ark api_key + endpoint + 模型ID] / DashScope[api_key + endpoint])与「语音服务配置」(豆包语音[app_key + app_token + tts_resource_id])。LLM 卡与语音卡字段各自独立,删掉「app token 框承载 LLM key」的复用逻辑 + 误导注释。

**D5 — 部署顺序:** common(枚举+迁移工具)→ 跑迁移(prod DB 行搬家 + 写 ark key)→ engine factory + 重启 → api 白名单 → web 部署。**common 与 engine 必须先于真机验,否则 ASR/TTS 找不到 `volcengine_speech` 凭据。**

## Risks / Trade-offs

- **[迁移把语音 api_key 当成 ark key 误置]** → D3 明确:现 `volcengine.api_key` 是**语音**键,必须搬到 `volcengine_speech`;ark key 是**新值**写进 `volcengine.api_key`。迁移脚本对这两个 api_key 分别处理,加 dry-run 核对。
- **[ASR/TTS 短暂找不到凭据]** → 迁移 + engine 重启要原子完成(D5 顺序);迁移前备份 `provider_credential` 全表。
- **[role_config.ext_params.provider 存量值]** → 保留 `volcengine` 作 LLM id 即不动存量 LLM provider 值(D1);语音 provider 由 engine_asr/tts_provider 配置切到新 id。
- **[ark 模型 ID 仍需人工填对]** → 非本 change 代码能解决;在 web 模型卡给 `default_model` 加提示(带版本ID/接入点 ep-xxx)。

## Migration Plan

无 alembic。① 备份 `provider_credential`;② common 上线新枚举 + 迁移工具;③ dry-run 迁移核对(语音四行 → volcengine_speech;ark key → volcengine.api_key);④ `--apply` 迁移;⑤ engine factory 上线 + 重启;⑥ api 白名单 + web 部署;⑦ 真机验主 LLM(豆包)能回话 + ASR/TTS 仍正常。回滚:`provider_credential` 行 provider_id 改回 + factory 旧版 scp + 重启。

## Open Questions

1. **新语音 provider_id 命名**:`volcengine_speech` vs `doubao_voice` vs `volcengine_asr_tts`?LLM 侧是否保留 `volcengine`(D1 倾向保留)还是也重命名 `volcengine_ark`?默认 `volcengine`(LLM) + `volcengine_speech`(语音),待用户拍板。
2. **ASR/TTS 新旧控制台双模式**:是否两套(新版 api_key / 旧版 app_key+app_token)都在语音卡暴露,还是只留新版 api_key?默认两套都迁、都支持(行为不变)。
3. **ark `default_model` 填法**:模型卡是否做 ark 模型ID/接入点的格式校验/下拉?默认纯文本 + 提示文案,不做在线校验(account-specific)。
