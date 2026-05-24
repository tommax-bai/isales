## Context

iSales v1.0 凭据现状：
- `deploy/cloud/env/{api,engine,worker,scheduler}.env` 持有运行时密钥
  (`ISALES_VOLCENGINE_APP_KEY` / `_APP_TOKEN` / `ISALES_OPENAI_API_KEY`)。
- `isales-engine.settings.Settings`（pydantic-settings）从 env 读，传给
  `providers/factory.py::build_*` 用。
- `isales-web/views/Config/ModelProviderConfig.vue` 把同样的字段写
  浏览器 localStorage（key `model-providers-v3`），**与 engine 实际使用
  无关**——只是 UI 上不丢值。
- `callback_config.signing_secret` 字段在表中已存在但**未加密**（明文
  varchar），与 `webhook-callback` spec § "HMAC 签名机制" 声明的"加密
  存储"对不齐。

约束：
- v1.0 部署是 IP-direct 单 ECS，无 KMS 服务；密钥保护只能靠 env 文件
  权限 + DB 行加密。
- engine 启动期是 cold path，可以多一次 DB query；运行期不能加任何
  解密开销（factory 已 cache 在 LLMProvider 实例里）。
- 用户明确拒绝"DB 加密但 engine 还从 env 读"中间档（见 memory
  [[feedback-no-half-baked-designs]]）—— 必须是真 SSOT 切换，env 不再
  持有密钥。
- 不引入新外部服务（HashiCorp Vault / 阿里 KMS 等）；用 Python
  `cryptography.fernet` 内置库。

## Goals / Non-Goals

**Goals:**
- DB（`provider_credential` 表）成为所有 LLM / ASR / TTS provider 凭据
  的唯一事实来源；env 不再持有任何密钥字段（除 Fernet 主密钥本身）。
- UI 写 / 改密钥 → DB → engine 重启后立即生效；无需 ssh 改 env。
- 凭据加密静止存储（Fernet 对称加密），DB 泄漏不直接等于密钥泄漏。
- `callback_config.signing_secret` 走同一加密 fabric，spec 文字与实装
  齐口径。
- 提供一次性迁移脚本：从现有 env 文件读密钥 → 加密写 DB → 清 env。
- 提供凭据轮换 recipe（新增 Fernet 主密钥 / 旋转单条 provider key）
  写进 `deploy/RUNBOOK-cloud.md`。

**Non-Goals:**
- **不**实装"live reload"——engine 启动期一次读 DB，UI 改后必须重启
  engine 才生效（重启 ≤ 5 秒、acceptable）。live reload 留为后续 change。
- **不**做多租户凭据隔离（v1.0 单 ECS 单组凭据）。
- **不**引入 KMS / Vault；Fernet 主密钥仍在 env，靠 ECS 文件权限保护。
- **不**实装"API key 明文回显"——UI 只看掩码 preview，改 key = 整段
  替换。
- **不**做凭据版本历史（audit who/when 已够；版本 diff 留后续 change）。
- **不**改 ARTC RTC AppKey 存放方式（`ISALES_RTC_APP_KEY` 保留在
  engine.env，因为它是 ARTC token 签发用，不属"模型凭据"概念；范围内
  仅 LLM / ASR / TTS / webhook signing）。

## Decisions

### D1：对称加密用 Fernet（cryptography 库），主密钥在 env

`cryptography.fernet.Fernet` 是 Python 标准对称加密 recipe（AES-128-CBC
+ HMAC-SHA256，自动 IV，url-safe base64 输出）。主密钥 32 字节 url-safe
base64，放 env 变量 `ISALES_FERNET_KEY`，所有 4 个 cloud 服务
（api / engine / worker / scheduler）共享同一 key（worker 解 callback
signing_secret 也用它）。

**Alternatives:**
- ① 不加密、明文 DB 存——拒绝。DB 备份 / pg_dump / 误日志直接漏 key。
- ② asymmetric (RSA / age)——key 分发更复杂、用户场景不需要、性能差。
- ③ HashiCorp Vault / Aliyun KMS——v1.0 不引入新基础设施；Fernet 够
  当前安全需求（DB 泄漏不漏 key + env 权限 0640 保护主密钥）。

### D2：表 schema —— 行级 per `(provider_id, field_name)`

```sql
CREATE TABLE provider_credential (
    id           BIGSERIAL PRIMARY KEY,
    provider_id  VARCHAR(32) NOT NULL,    -- 'volcengine' / 'openai' / 'dashscope'
    field_name   VARCHAR(32) NOT NULL,    -- 'app_key' / 'api_key' / 'app_token' /
                                          -- 'endpoint' / 'default_model' / 'enabled'
    cipher_text  TEXT NOT NULL,           -- urlsafe base64 Fernet cipher (复用
                                          --  isales_common.utils.crypto.encrypt
                                          --  的返回类型 str)；'enabled' / 'endpoint'
                                          --  等非密字段也走 Fernet 统一处理
                                          --  （避免 cleartext + cipher 两套 fetch）
    updated_by   VARCHAR(64),               -- JWT sub claim (username)；项目无 user 表故无 FK
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (provider_id, field_name)
);
CREATE INDEX ix_provider_credential_provider_id ON provider_credential(provider_id);
```

**Alternatives:**
- ① 单 JSON 列 (`payload JSONB`)，一行一 provider——拒绝。整列 cipher
  blob 改单字段需 decrypt 整 blob 再 reencrypt，partial-update 复杂；
  审计 `updated_by` 也粒度过粗。
- ② 每 provider 一张表 (`volcengine_cred` / `openai_cred`)——schema 膨胀
  + 加新 provider 要建表。否决。

`enabled` 字段虽非密但同样走 Fernet 加密——避免 application 层分两条
code path 处理"加密字段 vs 明文字段"。Performance 可忽略（Fernet 1 KB
load 在 < 1ms / Python 进程一次启动只跑 ~10 次）。

### D3：`isales_common.credentials` 公共加解密模块

新建 `isales_common/credentials.py`：
- `class CredentialStore`：持有 `Fernet` 实例 + 内存 dict
  `{provider_id: {field_name: plaintext}}`
- `CredentialStore.load(session)`：async 查 `provider_credential` 全表
  + 解密 + 返回 dict
- `CredentialStore.get(provider_id, field_name) -> str | None`
- `CredentialStore.encrypt(plaintext: str) -> bytes` /
  `decrypt(cipher: bytes) -> str`（封装 Fernet 调用 + 错误处理）
- `CredentialStore.mask(plaintext: str) -> str`：返回 `"xxxx****yyyy"`
  形式给 UI

api / engine / worker 启动时各持一份 `CredentialStore` 实例（不共享，因
进程隔离）。

### D4：engine 启动期加载凭据，运行期不再读 DB

`isales-engine.main`：
```python
async def startup():
    settings = Settings()  # 不再含 provider keys
    if settings.credentials_required:
        store = await CredentialStore.from_db(db)
        provider_factory.set_credential_store(store)
    else:
        provider_factory.set_credential_store(MockCredentialStore())
    ...
```

`Settings.credentials_required: bool = True` 默认硬要求；
`ISALES_CREDENTIALS_REQUIRED=false` 用于 dev / CI（走 mock providers）。

`providers/factory.py::build_llm/asr/tts`：从 `_credential_store.get(name,
"app_key")` / `"api_key"` 取值；找不到时 `raise NotImplementedError(
"provider <X> credentials not configured in DB")`。

**Live reload**：v1.0 不做。UI 改 key 后用户必须 `systemctl restart
isales-engine`（≤ 5 s）。Live reload 后续 change：加 Redis pub/sub
通道 `isales:credentials:reload`，engine 订阅后 `await store.load()`。

### D5：webhook callback `signing_secret` 共用 Fernet fabric

`callback_config.signing_secret` 列当前已是 `Text` 类型（既有 schema）；
本 change **不改类型**，仅约束语义：值 SHALL 是 `isales_common.utils.
crypto.encrypt()` 输出的 urlsafe base64 字符串（Fernet cipher）。
`isales-worker` 发 webhook 时 `secret = store.decrypt(row.signing_secret)`
→ HMAC 签名。

**Migration**：若现有数据库已有 `callback_config` 行且 `signing_secret`
存的是明文，alembic upgrade 时跑一次性加密脚本 (`UPDATE callback_config
SET signing_secret = <encrypted>`)；预期 v1.0 部署 callback_config 表
通常为空，几乎无 row 需迁移。

`POST /api/callback-configs/{id}/rotate-secret` 端点：生成新 secret →
Fernet 加密 → 写 cipher 列；返回**明文 once-only**（用户必须立即填入
对端系统配置）。

### D6：一次性迁移脚本 `isales-cred-migrate`

`isales-common` 加 CLI 入口（pyproject `[project.scripts]`）：

```bash
isales-cred-migrate --env-file /etc/isales/env/api.env --apply
```

读 env 里的 `ISALES_VOLCENGINE_APP_KEY` / `_APP_TOKEN` /
`ISALES_OPENAI_API_KEY` 等字段 → 加密写 DB（upsert by
`(provider_id, field_name)`）。`--dry-run` 默认；`--apply` 真写。

部署 sequence 严格：
1. 生成 Fernet 主密钥写 env
2. alembic upgrade（建表 + 改 callback_config 列类型）
3. `isales-cred-migrate --apply`（env → DB）
4. 部署新版 isales-api / engine / worker
5. UI 验证 / 拨测
6. **清 env 旧字段** + systemd reload
7. 重启 engine（凭据 startup 读路径已生效）

### D7：UI 仅看掩码，改 key 整段替换

`ModelProviderConfig.vue`：
- GET list：API 返回 `{provider_id, field_name, masked_value:
  "xxxx****yyyy", updated_by, updated_at}`——**永不**返回明文。
- PATCH：用户填新值整段替换；空值表示"保持不变"（不发请求）。
- 删除 key：DELETE 该 `(provider_id, field_name)` 行。

掩码格式：前 4 后 4，中间 `*`×8 固定（不暴露真实长度）。

## Risks / Trade-offs

- **[Risk] Fernet 主密钥丢失 / 损坏** → 所有加密凭据不可解，engine 起
  不来。**Mitigation**：① RUNBOOK 加"Fernet key 备份"小节，建议存
  password manager 离线副本；② 部署生成 key 时同时存到 `deploy/cloud/
  env/SECRETS.md`（gitignored）作二级备份；③ engine startup
  `cred-decryption-failed` 错误明确指向 RUNBOOK 恢复流程。
- **[Risk] env 字段清理早于服务重启 → engine 用旧 Settings 进程仍读
  env，重启后才切到 DB；这中间窗口里 UI 改 key 在 engine 不生效** →
  **Mitigation**：部署 sequence D6 严格化，env 字段清理后 `systemctl
  restart isales-engine` 是原子步骤；RUNBOOK 标注"清 env 后必须立即
  restart"。
- **[Risk] DB 备份泄漏 + Fernet 主密钥泄漏 = 凭据明文**——双重泄漏才
  漏，**与 env 文件持有明文 + ECS 文件泄漏 = 漏的威胁模型相同**。
  Fernet 没降低真实安全性，但加了一层 attacker 必须同时拿到 DB +
  env 的成本。
- **[Risk] callback_config 已有行的 signing_secret 明文遗留** → 历史
  schema 已是 Text，但若数据库已有几行 callback_config 持明文 secret，
  alembic upgrade 必须把它加密。**Mitigation**：migration 跑一次性
  `UPDATE callback_config SET signing_secret = encrypt(signing_secret)
  WHERE signing_secret NOT LIKE 'gAAAA%'` (Fernet token 固定 'gAAAA' 前缀
  可用作 idempotent 判别)。预期 v1.0 部署该表为空。
- **[Trade-off] 加密 enabled / endpoint 这种非密字段** → 性能轻微浪
  费（每个字段一次 Fernet decrypt），但避免代码两套路径，net positive。
- **[Trade-off] engine 无 live reload，UI 改 key 必须重启** → 用户体
  验略差，但避免引入 Redis pub/sub 订阅复杂度。"重启 ≤ 5 秒、运维
  接受" 是 v1.0 trade-off；live reload 后续 change 补。

## Migration Plan

1. **dev box**：本地 alembic 跑通新 migration，pytest 全绿（含
   `isales-common::test_credentials` + `isales-api::test_provider_
   credentials_router` + `isales-engine::test_factory_db_credentials`
   + `isales-worker::test_callback_signing_decrypt`）。
2. **dev box smoke**：本机起 isales-api + isales-engine，UI 改一个
   key → 重启 engine → check engine 用新 key 调豆包 LLM 通。
3. **ECS 部署**：
   1. 生成 Fernet 主密钥（python `Fernet.generate_key()`），写进
      `/etc/isales/env/api.env` + `engine.env` + `worker.env` +
      `scheduler.env` 的 `ISALES_FERNET_KEY`。备份到
      `deploy/cloud/env/SECRETS.md`（gitignored）+ password manager。
   2. ECS git bundle scp（per [[reference-ecs-github-egress]]）→
      alembic upgrade head（建 `provider_credential` 表 + alter
      `callback_config.signing_secret` 类型）。
   3. `isales-cred-migrate --env-file /etc/isales/env/api.env --apply`
      读旧 env 密钥 → 加密写 DB。
   4. `pip install -e isales-common`（如 common 0.3.x → 0.4.0）。
   5. 重启 4 服务（systemctl restart isales-{api,engine,worker,
      scheduler}）→ journalctl 看 startup 含 `credentials_loaded
      count=N`。
   6. UI 验证：访问 `/operations/voice-models` → 改一个音色 sample
      预览（间接验 ASR/TTS 配置）；模型厂商页改一个 endpoint URL →
      重启 engine → 拨测一通。
   7. **清 env 旧字段**：`sed -i '/^ISALES_VOLCENGINE_APP_KEY=\|^ISALES_
      VOLCENGINE_APP_TOKEN=\|^ISALES_OPENAI_API_KEY=\|^ISALES_OPENAI_
      BASE_URL=/d' /etc/isales/env/*.env`；diff 确认。再 `systemctl
      restart isales-engine` 验证启动不报 KeyError（如报，说明
      `Settings.field` 没清干净）。
   8. 更新 `deploy/cloud/STATE.md` 凭据来源段落（env → DB） + alembic
      head bump。
4. **rollback**：
   - 如 4-6 步内任意失败：`git revert` engine + api commit + 还原
     env 旧字段 + alembic downgrade（migration 提供 `downgrade` 路径，
     `provider_credential` 表 DROP，`signing_secret` 改回 VARCHAR + 解
     密回明文）。
   - 7 步之后失败需手工 restore env：`isales-cred-export
     --env-file /tmp/restored.env --apply` 反向把 DB 凭据解密回 env。

## Open Questions

1. **Fernet 主密钥跨服务同步**：4 个服务的 env 文件都要写同一个 key；
   写漏一处 = 该服务起不来。**RESOLVED**：deploy script 改一处统一
   渲染 4 个 env 文件（已有 `deploy/common/_lib.sh::render_env` 抽象，
   把 `ISALES_FERNET_KEY` 加到 shared 段）。
2. **Cloud-edge edge 侧需不需要 Fernet 主密钥**：edge (isales-telephony)
   不直接调 LLM / ASR / TTS provider（云端 engine 做），所以 **不需要**。
   edge 仍持有 `ISALES_EDGE_DEVICE_TOKEN`（JWT，签发逻辑与本 change 无
   关）+ `ISALES_RTC_APP_KEY`（ARTC，不在 scope）。**RESOLVED**：edge
   env 不动。
3. **callback signing_secret 旋转明文回显次数**：API 是否允许多次拿明
   文（如果用户忘了首次 once-only 提示）？**RESOLVED**：不允许。
   `rotate-secret` 端点只在 POST 那一次响应里返回明文；后续 GET 永远
   只返回 mask preview。用户忘了 = 再 rotate 一次（不能"找回旧 secret"）。
4. **新 provider 的 schema 兼容**：未来加 anthropic / azure / aws-
   bedrock 时，`provider_credential.provider_id` 是字符串足以容纳，
   无需 schema 改动。`field_name` 也是开放枚举（应用层校验白名单）。
   **RESOLVED**：design ok，加 provider = isales-engine factory + UI
   PROVIDERS 数组 + DB 上写新 row，无 migration。
