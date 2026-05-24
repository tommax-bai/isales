# provider-credential Specification

## Purpose
TBD - created by archiving change impl-provider-credential-db-ssot. Update Purpose after archive.
## Requirements
### Requirement: 凭据 DB 是单一事实来源

provider 密钥与配置 SHALL 全部持久化在 `provider_credential` 表，且
DB SHALL 是运行时凭据的唯一事实来源。覆盖字段含 `api_key` / `app_key` /
`app_token` / `endpoint` / `default_model` / `enabled`。env 文件 MUST NOT
持有任何 provider 密钥字段；唯一允许在 env 中的密钥相关字段是
`ISALES_FERNET_KEY` 对称加密主密钥本身。`isales-engine` /
`isales-worker` / `isales-api` 进程 SHALL 在启动期一次性从
`provider_credential` 表装载凭据；运行期 MUST NOT 再读 env 取 provider
密钥。

#### Scenario: 部署后 env 文件不再含 provider 密钥

- **WHEN** 一次 fresh deploy 完成
- **THEN** `/etc/isales/env/{api,engine,worker,scheduler}.env` MUST NOT
  包含 `ISALES_VOLCENGINE_APP_KEY` / `ISALES_VOLCENGINE_APP_TOKEN` /
  `ISALES_OPENAI_API_KEY` / `ISALES_OPENAI_BASE_URL` /
  `ISALES_VOLCENGINE_*_ENDPOINT` 等字段；4 个 env 文件 SHALL 仅持有
  `ISALES_FERNET_KEY`（同一值，4 处一致）以及非凭据配置（数据库
  URL / Redis URL / JWT secret / ARTC AppId/AppKey 等）

#### Scenario: engine 启动从 DB 装载

- **WHEN** `isales-engine` startup 阶段
- **THEN** SHALL 调用 `CredentialStore.from_db(session)` 一次性查询
  `provider_credential` 全表 + Fernet 解密 + 缓存到进程内存；装载完成
  SHALL emit log line `credentials_loaded provider_ids=[...]`，count
  与 DB 行数一致

#### Scenario: 装载失败时硬失败

- **WHEN** engine startup 装载凭据时 ① DB 不可达 / ② Fernet
  解密失败（密钥不匹配 / cipher 损坏）
- **THEN** 默认配置 (`ISALES_CREDENTIALS_REQUIRED=true`) 下 engine SHALL
  退出（exit code != 0）并 log `cred_load_failed reason=<...>`；指明指向
  RUNBOOK "凭据恢复" 流程

#### Scenario: dev / CI mock fallback

- **WHEN** `ISALES_CREDENTIALS_REQUIRED=false`（仅 dev / CI 使用）且
  `provider_credential` 表为空或解密失败
- **THEN** engine SHALL 跳过装载 + 强制 `factory.build_*` 走 mock
  provider 分支；运行时调用 build_volcengine / build_openai 等真 provider
  SHALL 抛 `NotImplementedError` 明示原因

### Requirement: Fernet 对称加密 fabric

所有 `provider_credential.cipher_text` 字段 SHALL 由
`cryptography.fernet.Fernet` 用 `ISALES_FERNET_KEY` 加密 / 解密；
主密钥 SHALL 是 32 byte url-safe base64 字符串（标准 Fernet key 格式）。
`isales_common.credentials` 模块 SHALL 提供统一的 `CredentialStore` 类，
封装 `encrypt(str) -> bytes` / `decrypt(bytes) -> str` / `mask(str) -> str`
三个方法，所有持久化 / UI 暴露 SHALL 通过本模块，MUST NOT 在 application
代码里直接 import `Fernet`。

#### Scenario: 主密钥格式校验

- **WHEN** 进程读取 `ISALES_FERNET_KEY` env
- **THEN** SHALL 用 `Fernet(key.encode())` 初始化；若 key 不合法
  Fernet SHALL 抛 `ValueError`，进程启动失败并 log 错误指向 RUNBOOK
  "Fernet 主密钥生成"

#### Scenario: 加密字段一致性

- **WHEN** 任何字段（含 `enabled` / `endpoint` 等非密字段）写入
  `provider_credential.cipher_text`
- **THEN** SHALL 走同一 `CredentialStore.encrypt` 路径；MUST NOT 区分
  "密字段 / 非密字段" 两套存储路径

#### Scenario: 掩码格式

- **WHEN** API 返回任意凭据值给前端
- **THEN** SHALL 用 `CredentialStore.mask(plaintext)` 转换为 `<前 4
  字符>********<后 4 字符>` 形式（中间 `*` 固定 8 个，不暴露真实长度）；
  长度小于 8 的字符串 SHALL mask 为 `********`

### Requirement: provider_credential 表结构

`provider_credential` 表 SHALL 含以下列（参见 data-model spec 全表清
单）：`id` (BIGSERIAL PK) / `provider_id` (VARCHAR(32))，应用层枚举与
`isales-engine.providers.factory.KNOWN_*_PROVIDERS` 对齐 / `field_name`
(VARCHAR(32))，应用层枚举 `app_key | api_key | app_token | endpoint |
default_model | enabled` / `cipher_text` (Text NOT NULL, urlsafe base64 Fernet cipher) / `updated_by`
(VARCHAR(64) nullable, 存 JWT `sub` claim / username — 项目当前无独立
`user` 表，故不设 FK) / `updated_at` (TIMESTAMPTZ NOT NULL DEFAULT now())。
SHALL 含 UNIQUE 索引 `(provider_id, field_name)` 与普通索引 `provider_id`。

#### Scenario: 每字段一行

- **WHEN** UI 写 volcengine 的 app_key + app_token + endpoint + enabled
- **THEN** SHALL upsert 4 行（同 provider_id='volcengine' 不同
  field_name），每行独立 updated_by / updated_at；MUST NOT 把多字段塞进
  单 cipher_text

#### Scenario: provider_id 未知拒绝

- **WHEN** 客户端 POST 一个 `provider_id` 不在 isales-engine
  `KNOWN_*_PROVIDERS` 集合
- **THEN** isales-api SHALL 返回 422，message 含合法 provider_id 集合；
  MUST NOT 把未知 provider 写入 DB

### Requirement: Admin CRUD HTTP 端点

`isales-api` SHALL 在 `/api/provider-credentials` 暴露 JWT 鉴权的 CRUD：

- `GET /` 列出所有行的 `(provider_id, field_name, masked_value,
  updated_by, updated_at)`；MUST NOT 返回明文 cipher / plaintext
- `GET /{provider_id}` 列出该 provider 的全字段（同上 masked）
- `POST /` body `{provider_id, field_name, plaintext_value}` —— upsert
  by `(provider_id, field_name)`；服务端 Fernet 加密后写入；返回行的
  masked 结构
- `DELETE /{id}` 删除一条字段配置
- `POST /reload-hint` —— 仅 emit `cred_reload_required` log 提示运维
  重启 engine；v1.0 不实装 live reload

#### Scenario: 鉴权强制

- **WHEN** 任意 `/api/provider-credentials/*` 请求未带有效 JWT
- **THEN** SHALL 返回 401

#### Scenario: 上传明文加密落库

- **WHEN** POST `/api/provider-credentials` body
  `{provider_id: "volcengine", field_name: "app_key", plaintext_value: "vc-xxx"}`
- **THEN** isales-api SHALL `CredentialStore.encrypt("vc-xxx")` 得 cipher_text
  → upsert 行 → 返回 `{provider_id, field_name, masked_value: "vc-x****-xxx",
  updated_at}`；response body MUST NOT 含 plaintext_value 或 cipher_text raw

#### Scenario: 写入触发审计

- **WHEN** 任一 POST / DELETE 成功
- **THEN** 行的 `updated_by` SHALL 设为请求 JWT 的 `sub` claim
  (username 字符串)；`updated_at` SHALL 用 now()

### Requirement: webhook callback signing_secret 共用 fabric

`callback_config.signing_secret` 字段 (现已是 Text 列) SHALL 存 urlsafe
base64 Fernet cipher，由同一 `ISALES_FERNET_KEY` 加密。`isales-worker` 发 webhook
HTTP 时 SHALL `CredentialStore.decrypt(row.signing_secret)` 取明文 →
HMAC-SHA256 计算签名（与 webhook-callback spec § "HMAC-SHA256 签名机制"
对齐）。

#### Scenario: 创建 callback_config 时加密

- **WHEN** 用户 POST `/api/callback-configs` 不带 `signing_secret`
  或带空值
- **THEN** API SHALL 服务端生成 32 字节 url-safe random secret →
  Fernet 加密写入 → response 一次性返回明文（once-only retrieval，后续
  GET MUST NOT 返回明文）

#### Scenario: rotate-secret 一次性回显

- **WHEN** 用户 POST `/api/callback-configs/{id}/rotate-secret`
- **THEN** API SHALL 生成新 secret → Fernet 加密写入 → response 返回新
  secret 明文一次；后续 GET 该 config 永远只返回 mask preview；用户忘
  了 = 再 rotate 一次

#### Scenario: worker 解密签名

- **WHEN** worker 从 `callback_log.pending_retry` 取出一行准备发 webhook
- **THEN** SHALL `CredentialStore.decrypt(callback_config.signing_secret)`
  得明文 → HMAC-SHA256(`<timestamp>.<body>`) → request 头加
  `X-Isales-Signature: sha256=<hex_digest>`

### Requirement: 一次性迁移工具 isales-cred-migrate

`isales-common` SHALL 提供 CLI 入口 `isales-cred-migrate`（PyProject
`[project.scripts]`），支持以下子命令：

- `isales-cred-migrate import-env --env-file <path> [--apply]` —— 读
  env 文件里的 provider 密钥字段 → 加密 upsert 到 `provider_credential`
  表。默认 dry-run，`--apply` 真写
- `isales-cred-migrate export-env --env-file <path> [--apply]` —— **仅
  rollback 用**——从 DB 解密 → 写出 env 兼容格式

CLI MUST 用 ISALES_FERNET_KEY 当前 env 值；缺失即拒绝运行。

#### Scenario: dry-run 不写库

- **WHEN** `isales-cred-migrate import-env --env-file api.env`（不带
  --apply）
- **THEN** SHALL 打印将要执行的 upsert 计划（含字段名 + masked value），
  MUST NOT 写库

#### Scenario: import 后再 apply 是 idempotent

- **WHEN** 重复跑 `isales-cred-migrate import-env --env-file api.env
  --apply` 两次
- **THEN** 第二次 SHALL 走 `ON CONFLICT (provider_id, field_name) DO
  UPDATE` 路径，行数不增；DB 状态等价于一次跑

### Requirement: 凭据轮换 recipe 落 RUNBOOK

`deploy/RUNBOOK-cloud.md` SHALL 增 "§ 凭据轮换" 小节，覆盖：① Fernet
主密钥轮换（旧 key 解密 → 新 key 加密，停机窗口必要）；② 单 provider
密钥旋转（UI 改 / 或 `psql -c "UPDATE provider_credential SET cipher_text
= ..."`）；③ rollback 路径（`isales-cred-migrate export-env`）。

#### Scenario: 主密钥备份提醒

- **WHEN** 部署生成新的 `ISALES_FERNET_KEY`
- **THEN** RUNBOOK SHALL 明示运维：① 把 key 同时写入 password manager
  离线副本；② 写入 `deploy/cloud/env/SECRETS.md`（gitignored 二级备份）；
  ③ 主密钥丢失 = 所有凭据不可恢复

