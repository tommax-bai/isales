## Why

模型厂商 API key（volcengine `app_key/app_token`、openai `api_key`、未来
dashscope `api_key`）当前散布在两处：UI 暂存浏览器 localStorage、生产
运行实际从 `/etc/isales/env/*.env` 文件读取。这造成三个真问题：①
**改 key 必须改 env + systemctl restart 服务**，不是产品化操作；②
**UI 输入没有真正落地**，刷新保留只是浏览器层错觉；③ **没有审计 / 轮换
痕迹**——env 改了没有 who/when 记录。`webhook-callback` spec § "HMAC
签名" 也声明 `signing_secret` 加密存储，但同样没实装。

把 provider 密钥的单一事实来源（SSOT）切到 DB，UI 写 → DB → engine 启
动时读，env 不再持有任何密钥字段。

## What Changes

- **NEW**：`provider_credential` 表（in `isales-common`）—— 持有所有
  provider 凭据，Fernet 对称加密。schema 含 `provider_id`（fk-like enum
  `volcengine / openai / dashscope / ...`）+ `field_name`（`app_key /
  api_key / app_token`）+ `cipher_text`（Fernet 加密的 urlsafe base64 str，复用既有 isales_common.utils.crypto）+
  `endpoint` + `default_model` + `enabled` + `updated_by` + `updated_at`。
  唯一索引 `(provider_id, field_name)`。
- **NEW**：`isales-api` 新增 `/api/provider-credentials` CRUD router——
  JWT 鉴权 / GET list & get / POST upsert / DELETE / GET `/decrypted`
  仅返回掩码 preview（不暴露明文 API key）。
- **NEW**：`isales_common.credentials` 模块——provider_credential 行的
  装载 + 解密公共函数 `load_credentials(session) ->
  dict[ProviderId, ProviderCreds]`；engine 启动时调用一次预热到内存。
- **MODIFIED**：`isales-engine.providers.factory` —— `build_llm /
  build_asr / build_tts` 不再从 `Settings` 读密钥，改从 `load_credentials()`
  返回的字典读。`Settings` 上的 `volcengine_app_key` /
  `volcengine_app_token` / `openai_api_key` 字段全部删除。
- **MODIFIED**：`isales-engine` 启动顺序——startup 阶段查 DB 装载凭据，
  失败时按 `ISALES_CREDENTIALS_REQUIRED=true|false` 决定 hard-fail 还是
  warn-and-mock（默认 hard-fail；CI / dev box 用 false 走 mock provider）。
- **MODIFIED**：`isales-web` `ModelProviderConfig.vue` 从 `useLocalConfigStash`
  切到 `providerCredentialsApi` ——读 DB / 改 DB。banner 文案更新。
- **BREAKING**：`deploy/cloud/env/*.env` 移除以下字段：
  `ISALES_VOLCENGINE_APP_KEY`、`ISALES_VOLCENGINE_APP_TOKEN`、
  `ISALES_OPENAI_API_KEY`、`ISALES_OPENAI_BASE_URL`、
  `ISALES_VOLCENGINE_*_ENDPOINT` 等。**新增一个**：
  `ISALES_FERNET_KEY`（32-byte url-safe base64，用于解密 DB 行）。
  现有 deployment 部署本 change 时必须：①生成 fernet key → ②写 env →
  ③一次性把现 env 里的密钥从 UI 灌进 DB → ④清 env 旧字段 → ⑤重启
  engine。`deploy/RUNBOOK-cloud.md` § "凭据轮换" 增补迁移 recipe。
- **MODIFIED**：`webhook-callback` 的 `signing_secret` 加密路径
  打通——`callback_config.signing_secret` 改为 Fernet 加密存储（同一个
  `ISALES_FERNET_KEY`），与 spec § "HMAC-SHA256 签名机制" 的"加密
  存储" 字面对齐（spec 之前只声明未落实）。

## Capabilities

### New Capabilities

- `provider-credential`：admin-managed encrypted credential storage for
  LLM / ASR / TTS / webhook providers，Fernet 对称加密，启动期一次性
  装载，UI CRUD + DB-as-SSOT。覆盖 schema / API / engine startup / 加解
  密语义 / 凭据轮换。

### Modified Capabilities

- `data-model`：增 `provider_credential` 表（schema-level 行为新增）。
- `web-admin-ui`：删除"3 个圆配置按钮"残留之一描述（模型厂商 view 的
  localStorage 兜底语义改写）；已 spec'd 能力的 UI 暴露增"密钥 DB
  落库 + 审计 + 轮换"。
- `webhook-callback`：`signing_secret` 字段语义从"加密存储（待实装）"
  改为"通过 provider-credential 加密 fabric 加密存储"，spec § "HMAC
  签名机制" 字面更新。

## Impact

- **affected repos**：
  - `isales-common`（中）：`provider_credential` 表 + migration + Pydantic
    schema + `credentials.py` 装载/解密公共模块；callback_config.signing_secret
    字段类型 / 加密语义调整 + migration。
  - `isales-api`（中）：`provider_credentials` router + ModelProvider
    KS-style endpoint；callback signing_secret create/rotate 路径接 fernet。
  - `isales-engine`（重）：`factory.py` 重写凭据装载源；`Settings` 模型
    瘦身；startup 顺序加 `load_credentials()`；mock fallback 路径。
  - `isales-worker`：webhook 发送时 signing_secret 解密 + HMAC 签名走
    新 fernet fabric。
  - `isales-web`（轻）：`ModelProviderConfig.vue` 改对接 API；删
    `useLocalConfigStash` 在此 view 的用法；banner 文案；删
    `model-providers-v3` localStorage key 清理。
- **affected specs**：`provider-credential`（新）+ `data-model` +
  `web-admin-ui` + `webhook-callback` 各一个 delta。
- **BREAKING**：① env 文件删字段（部署侧迁移步骤必跑）；②
  `callback_config` 表 `signing_secret` 字段加密化（一次性 migration
  脚本读旧明文 → 写 cipher_text）；③ `isales-common` 0.3.x → 0.4.0
  (model + 加密语义改动，consumer 重新 pin)。
- **依赖**：本 change 落地前先确认 ECS Python 3.11 venv 装 `cryptography`
  包（Fernet 由它提供；isales-common 已间接依赖，不需要新加 dep）。
- **不变**：service-communication / call-state-machine / ai-pipeline /
  realtime engine 数据面 / cloud-edge gRPC；ARTC RTC 通路；模型厂商
  view 视觉 layout。
