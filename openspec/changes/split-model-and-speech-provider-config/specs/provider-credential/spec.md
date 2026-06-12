## MODIFIED Requirements

### Requirement: provider_credential 表结构

`provider_credential` 表 SHALL 含以下列（参见 data-model spec 全表清
单）：`id` (BIGSERIAL PK) / `provider_id` (VARCHAR(32))，应用层枚举与
`isales-engine.providers.factory.KNOWN_*_PROVIDERS` 对齐 / `field_name`
(VARCHAR(32))，应用层枚举 `app_key | api_key | app_token | tts_resource_id |
endpoint | default_model | enabled` / `cipher_text` (Text NOT NULL, urlsafe base64 Fernet cipher) / `updated_by`
(VARCHAR(64) nullable, 存 JWT `sub` claim / username — 项目当前无独立
`user` 表，故不设 FK) / `updated_at` (TIMESTAMPTZ NOT NULL DEFAULT now())。
SHALL 含 UNIQUE 索引 `(provider_id, field_name)` 与普通索引 `provider_id`。

`provider_id` 应用层枚举 SHALL 按真实产品线区分 **LLM 类**与**语音类**，
一个 provider_id 只承载单一产品线的密钥，MUST NOT 把不同产品线（LLM vs
语音）的密钥混入同一 provider_id：

- **LLM provider**（`KNOWN_LLM_PROVIDERS`）：`volcengine`（火山方舟 / 豆包大
  模型 Ark）、`dashscope`（阿里通义千问）。火山方舟 LLM SHALL 用独立的 ark
  API Key，持 `api_key`（ark key）+ `endpoint` + `default_model`。
- **语音 provider**（`KNOWN_ASR_PROVIDERS` / `KNOWN_TTS_PROVIDERS`）：
  `volcengine_speech`（豆包语音 / bytedance openspeech，ASR + TTS），持
  `app_key` + `app_token` + `tts_resource_id`（+ 新版控制台单 `api_key`
  X-Api-Key 模式）。

engine `factory.build_llm("volcengine")` SHALL 读 `volcengine` provider 的
`api_key`（ark key），MUST NOT 读 `app_token`（语音 token）；
`build_asr` / `build_tts` SHALL 读 `volcengine_speech` provider 的凭据。

#### Scenario: 每字段一行

- **WHEN** UI 写某 provider 的多个字段（如 `volcengine_speech` 的 app_key +
  app_token + tts_resource_id + enabled）
- **THEN** SHALL upsert 多行（同 provider_id 不同 field_name），每行独立
  updated_by / updated_at；MUST NOT 把多字段塞进单 cipher_text

#### Scenario: LLM 与语音密钥分属不同 provider_id

- **WHEN** 配置火山方舟豆包大模型 + 豆包语音
- **THEN** ark LLM key SHALL 写入 `provider_id='volcengine'` 的 `api_key`
  字段；语音 `app_key`/`app_token`/`tts_resource_id` SHALL 写入
  `provider_id='volcengine_speech'`；二者 MUST NOT 共用同一 provider_id 或
  同一字段
- **AND** engine `build_llm("volcengine")` SHALL 用 `volcengine.api_key`
  构建 ark LLM client；`build_asr`/`build_tts` SHALL 用 `volcengine_speech`
  的凭据，互不读取对方字段

#### Scenario: provider_id 未知拒绝

- **WHEN** 客户端 POST 一个 `provider_id` 不在 isales-engine
  `KNOWN_*_PROVIDERS` 集合（含新增的 `volcengine_speech`）
- **THEN** isales-api SHALL 返回 422，message 含合法 provider_id 集合；
  MUST NOT 把未知 provider 写入 DB
