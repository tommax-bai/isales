## MODIFIED Requirements

### Requirement: HMAC-SHA256 签名机制

每个 callback_config SHALL 在创建时由系统生成 `signing_secret`，secret SHALL 通过 `provider-credential` capability 定义的 Fernet 加密 fabric（同一 `ISALES_FERNET_KEY` 主密钥）加密后存储于 `callback_config.signing_secret` Text 列（urlsafe base64 cipher）；MUST NOT 明文存储。明文 secret SHALL 仅在创建或显式 `rotate-secret` 时通过 API 一次性返回给客户端，后续 GET 该 config SHALL 永远只返回 mask preview。每次 HTTP 请求 MUST 添加签名相关头部。

#### Scenario: 请求头格式

- **WHEN** worker 发送 webhook HTTP 请求
- **THEN** 请求头 MUST 包含：
  - `X-Isales-Signature: sha256=<hex_digest>`
  - `X-Isales-Timestamp: <unix_seconds>`
  - `Content-Type: application/json`

#### Scenario: 签名内容

- **WHEN** 计算 HMAC
- **THEN** worker SHALL `CredentialStore.decrypt(callback_config.signing_secret)` 得明文 secret；签名内容 MUST 为 `<timestamp> + "." + <body_bytes>`，使用 HMAC-SHA256 算法 + 解密后的 secret

#### Scenario: 接收方验证（推荐）

- **WHEN** 业务侧实现签名校验
- **THEN** 应：① 检查 `X-Isales-Timestamp` 与当前时间偏差 < 5 分钟（防重放）；② 重算 HMAC 并常量时间比对

#### Scenario: 创建时一次性回显明文

- **WHEN** 用户 POST `/api/callback-configs` 创建新配置（未传 signing_secret 或传空）
- **THEN** API SHALL 服务端生成 32 字节 url-safe random secret → Fernet 加密写 `signing_secret` 列 → response body 含 `signing_secret_plaintext` 字段一次性返回；后续 GET / list 该 config SHALL 永远不返回该字段，只返回 `signing_secret_masked`

#### Scenario: 用户主动旋转

- **WHEN** 用户 POST `/api/callback-configs/{id}/rotate-secret`
- **THEN** API SHALL 生成新 secret → Fernet 加密覆盖原列 → response 一次性返回新明文；旧 secret 永久失效（攻击者拿到旧 cipher 也无法用于伪造下次请求）；用户忘了 = 再 rotate 一次（不存在"找回旧 secret"流程）
