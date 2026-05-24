# Acceptance — impl-provider-credential-db-ssot

**Verified (local):** 2026-05-24, on the Windows dev rig
(`C:\Users\tianx\codes\isales*`, Python 3.11/3.14, Node 20).
**Verified (cloud):** 2026-05-24 09:32 CST — ECS `121.89.85.150` 全栈
部署完成；4 服务 active + `credentials_loaded count=2 providers=['volcengine']`
+ 0 error/fail in 60s log scan + HTTP smoke 47/47 endpoints OK / 0 DEAD。
**Browser UX smoke:** 仍欠 (用户在 UI「模型厂商」改 key + 保存 + mask
preview 验证流程)，与既往 deploy 形态一致。

## What this change shipped

把 LLM/ASR/TTS provider 凭据从 env 文件切到 **DB SSOT**：新建
`provider_credential` 表 (PK `id` + UNIQUE `(provider_id, field_name)`)，
存 Fernet urlsafe-base64 cipher。`isales-engine` startup 一次性从 DB
装载 `CredentialStore` 缓存到内存，运行期不再读 env。env 文件 (4 服务
共享) 仅持 `ISALES_FERNET_KEY` 主密钥本身 + `ISALES_CREDENTIALS_REQUIRED`
boolean，**MUST NOT** 包含任何 provider 密钥字段。

UI「模型厂商」view 重写：从 `useLocalConfigStash` 浏览器暂存换成
`/api/provider-credentials` 真持久化 CRUD；UI 永远只显示掩码
（`xxxx********yyyy`），改 key = 整段替换。webhook `callback_config.signing_secret`
共用同一 Fernet fabric。

凭据轮换 / Fernet 主密钥旋转 / 一次性 env→DB 迁移工具
(`isales-cred-migrate`) 全套落地：`deploy/RUNBOOK-cloud.md §9.5` +
`deploy/cloud/env/SECRETS.md.example` 灾难恢复 SOP 3 case
(ECS 全毁 / Fernet 泄漏 / 单 provider 泄漏)。

## Code path

- **isales-common 0.4.0** (BREAKING — common bump):
  - `credentials.py` (**new**): `CredentialStore` 类——in-memory dict
    `{provider_id: {field_name: plaintext}}` cache；`from_db(session)`
    批量装载 + Fernet 解密；`get` / `has` / `fields` / `providers` /
    `row_count` 访问器；`encrypt` / `decrypt` / `mask` 静态包装
    (透传 `utils/crypto`)。
  - `models/provider_credential.py` (**new**): `ProviderCredential` ORM
    (BigInteger id PK, VARCHAR(32) provider_id with idx, VARCHAR(32)
    field_name, Text cipher_text, VARCHAR(64) updated_by JWT-sub,
    UNIQUE `(provider_id, field_name)`)。
  - `schemas/provider_credential.py` (**new**): `ProviderCredentialUpsert`
    (含 plaintext_value) + `ProviderCredentialRead` (masked_value +
    audit meta)。
  - `alembic/versions/b2c3d4e5f6a7_add_provider_credential.py` (**new**):
    CREATE TABLE + indexes；upgrade 含一次性加密 `callback_config.signing_secret`
    旧明文行 (Fernet token prefix `gAAAA` idempotent guard，缺
    ISALES_FERNET_KEY 时静默 skip)；downgrade 反向解密 best-effort。
  - `cli/cred_migrate.py` (**new** + pyproject `[project.scripts]`):
    `isales-cred-migrate import-env / export-env` 子命令，`ENV_KEY_MAP`
    覆盖 volcengine/openai/dashscope 三家 11 个字段；pg INSERT...ON
    CONFLICT DO UPDATE upsert；dry-run 默认仅打 masked plan，`--apply`
    真写。
  - Tests: `tests/test_credentials.py` (10) + `tests/test_cli_cred_migrate.py`
    (12)；全量 151 passed 0 fail。
  - `pyproject.toml` 0.3.2 → 0.4.0；加 `[project.scripts] isales-cred-migrate`。

- **isales-api** (pin >=0.3.0,<0.4 → >=0.4.0,<0.5):
  - `routers/provider_credentials.py` (**new**): GET / list (masked) +
    GET /{provider_id} + POST upsert + DELETE + POST /reload-hint；
    JWT 鉴权；`ALLOWED_PROVIDER_IDS = {volcengine, openai, dashscope, mock}`
    + `ALLOWED_FIELD_NAMES = {api_key, app_key, app_token, endpoint,
    asr_endpoint, tts_endpoint, default_model, enabled}` 白名单校验未
    知 422。
  - `main.py`: include_router(provider_credentials)。
  - `tests/conftest.py`: autouse 注入 `ISALES_FERNET_KEY=Fernet.generate_key()`；
    TRUNCATE 加 provider_credential。
  - `tests/test_provider_credentials.py` (**new**, 11): CRUD + 422 +
    masked 不漏明文 + idempotent + audit updated_by。
  - 非 DB 测试 10/10 通过 (`test_openapi_documents_all_routes` 覆盖 router
    mount 链路)。

- **isales-engine** (pin >=0.3.0,<0.4 → >=0.4.0,<0.5):
  - `settings.py`: 删 7 个 provider 密钥字段 (`volcengine_app_key` /
    `volcengine_app_token` / `volcengine_llm_model` / `volcengine_asr_endpoint`
    / `openai_api_key` / `openai_base_url` / `openai_llm_model`)；保留
    `volcengine_tts_voice_id_default` (非密)；加 `credentials_required: bool
    = True` (env: `ISALES_CREDENTIALS_REQUIRED`)。
  - `providers/factory.py`: `build_llm` / `build_asr` / `build_tts` 签名
    `(name, *, store: CredentialStore | None = None, model=None)`；
    `KNOWN_LLM_PROVIDERS` 加 `dashscope` (OpenAI 兼容 Qwen)；
    `_DEFAULT_ENDPOINT` / `_DEFAULT_MODEL` fallback map。
  - `main.py`: `_load_credentials(sessionmaker, settings)` 三分支
    (装载成功 → log credentials_loaded count=N；CryptoError + required=True
    → SystemExit；required=False → 空 store warn)。`_make_runner` 加
    `credentials` 参数；build_* 透传 `store=credentials`。
  - Tests: `tests/test_providers.py` + `test_provider_errors.py` +
    `test_tts_volcengine.py` + `test_main_rtc_wireup.py` 全切
    CredentialStore 接口；240 passed / 25 skipped (live + Windows
    pre-existing `test_real_telephony.py` 排除，`asyncio.start_unix_server`
    Linux-only)。

- **isales-worker** (pin only):
  - `callbacks.py` 已用 `utils/crypto.decrypt()` (line 213) 解 cipher
    signing_secret + HMAC-SHA256 签名 — 本 change 无需改 worker 代码，
    Fernet fabric 已就位；只升 pin。
  - 18 passed / 27 skipped (live API tests gated)。

- **isales-scheduler** (pin only):
  - 不直接读 provider 凭据；仅 pin bump 保持 4 服务一致。
  - 本机 Windows pytest collection 受 tzdata 环境问题阻断 (pre-existing)；
    ECS Linux 跑没问题。

- **isales-web**:
  - `src/api/providerCredentials.ts` (**new**): list / listByProvider /
    upsert / remove / reloadHint 5 个端点。
  - `src/types/providerCredential.ts` (**new**): Read + Upsert。
  - `src/views/Config/ModelProviderConfig.vue`: 删 `useLocalConfigStash`；
    onMounted → `providerCredentialsApi.list()` 装载 `serverMasked`；UI
    placeholder 显 masked 或 default；onSave 仅 upsert 非空 input；保存
    后 `reloadHint()` emit 服务端 log + 提示用户重启 engine；banner 重写
    "凭据已 DB 落库 (Fernet 加密)"；volcengine 双密钥 UI: `api_key_input`
    → DB `field_name=app_token`, `app_key_input` → DB `field_name=app_key`。
  - 一次性 cleanup: `localStorage.removeItem` 旧 keys
    `model-providers-v1/v2/v3` 全清。
  - check:routes 干净 (22 定义 0 错配)；check:api 47/47 OK / 0 DEAD。

- **deploy/cloud/env** (BREAKING — env schema 变):
  - `engine.env`: 删 `ISALES_VOLCENGINE_APP_KEY` / `_APP_TOKEN` /
    `_LLM_MODEL` 注释；加 `ISALES_FERNET_KEY=Yt-e_Tg...` (4 env 同值)
    + `ISALES_CREDENTIALS_REQUIRED=true`。
  - `api.env` / `scheduler.env`: 加 `ISALES_FERNET_KEY` (同值)。
  - `worker.env`: 注释扩展 (强调 4 env 同值 + 兼供 provider_credential 装载)。
  - 4 个 `.env.example` 同步。
  - `README.md` 加 § "Provider 凭据走 DB SSOT"；layout 增 SECRETS.md
    / SECRETS.md.example 两行。
  - `SECRETS.md.example` (**new**): 5 段 secret 备份模板 + 3 case
    灾难恢复 SOP。
  - 顶层 `.gitignore` 加 `deploy/cloud/env/SECRETS.md` (whitelist 4
    个 .env 不动)。
  - `deploy/RUNBOOK-cloud.md` §3 首次部署: sudoedit 块加 FERNET_KEY
    生成 + `isales-cred-migrate import-env --apply` 步骤；新增 §9.5
    凭据轮换 4 子节 (单 provider 旋转 / Fernet 主密钥旋转含 PYEOF
    rotate 脚本 / 主密钥丢失 SOP / 一次性迁移)。

## Spec deltas

- **`provider-credential`** (**new** capability): 6 个 Requirement
  (SSOT / Fernet 加密 fabric / 表结构 / Admin CRUD / signing_secret
  共用 / 迁移工具 / 轮换 RUNBOOK)。
- `data-model` MODIFIED: 全表清单加 `provider_credential` 行；
  `callback_config.signing_secret` 类型注释更新 (Text + Fernet cipher)。
- `web-admin-ui` MODIFIED: "已 spec 能力的 UI 暴露" 内"AI 服务商凭据
  管理" bullet 改写为 DB 落库 + 新增 2 个 Scenario (DB 写入 / mask preview)。
- `webhook-callback` MODIFIED: "HMAC 签名机制" Requirement 改写 + 加
  2 个 Scenario (创建一次性回显 / rotate)。

## Verified — local

| Surface | Check | Result |
|---|---|---|
| openspec change | `openspec validate impl-provider-credential-db-ssot --strict` | ✅ valid |
| openspec totals | `openspec validate --specs && --changes` (21 specs + 5 changes) | ✅ all pass |
| isales-common pytest | 151 / 151 (含 22 new for credentials + cli) | ✅ |
| isales-api 非 DB pytest | 10 / 10 (test_auth + test_openapi_documents_all_routes 验证 router mount) | ✅ |
| isales-api DB pytest | 本机无 PG 全 skip；ECS PG 跑 (留 §8.x ECS 跑 88+ tests) | ⚠ deferred to ECS |
| isales-engine pytest | 240 / 240 (25 skipped = live + Windows test_real_telephony) | ✅ |
| isales-worker pytest | 18 / 18 (27 skipped = live gated) | ✅ |
| isales-scheduler pytest | Windows tzdata 环境问题 (pre-existing); ECS Linux 跑没问题 | ⚠ pre-existing |
| isales-web check:routes | 22 定义 / 0 错配 | ✅ |
| isales-web check:api (post-deploy) | 47 / 0 DEAD | ✅ |
| isales-web build + npm test | `vue-tsc + vite build` clean + vitest 全绿 | ✅ |
| residue grep | settings provider 字段 / localStorage<model-providers> | ✅ 0 hits |

## Verified — cloud (2026-05-24 09:32 CST)

| Step | Result |
|---|---|
| 5 bundle scp → ECS git fetch + merge --ff-only | ✅ common 6edbd8c / api b14d834 / engine 0f6023b / worker 134c371 / scheduler 78c4c54 |
| `pip install -e isales-common` (0.3.2 → 0.4.0) + 4 service refresh | ✅ pip check clean |
| backup `/etc/isales/env/engine.env` → `/tmp/engine.env.pre-cred-migrate` | ✅ |
| `alembic upgrade head` (a1b2c3d4e5f6 → b2c3d4e5f6a7) | ✅ CREATE TABLE provider_credential + UNIQUE + idx |
| `isales-cred-migrate import-env --apply` | ✅ 2 rows (volcengine.app_key + volcengine.app_token); masked plan `api-********5338` / `8298********2c49` |
| scp 4 new env → `install -m 0640 -o root -g isales /etc/isales/env/*.env` | ✅ engine.env 无 VOLCENGINE_APP_KEY/APP_TOKEN + 含 FERNET_KEY + CREDENTIALS_REQUIRED=true |
| `systemctl restart isales-{api,engine,worker,scheduler}` | ✅ 4 active |
| journalctl `credentials_loaded count=2 providers=['volcengine']` | ✅ |
| 60s error scan (error/fail/traceback) | ✅ 0 hits |
| HTTP smoke `/api/provider-credentials` | ✅ 401 (mount + auth) |
| `check_api_reachability --endpoint=http://121.89.85.150/api` | ✅ 47 / 0 DEAD |

## Deferred — explicit follow-up

1. **Browser UX smoke**: 用户在 UI「模型厂商」改 key + 保存 + 验证 mask
   preview 流程 + 重启 engine 后凭据生效。HTTP layer + journalctl + DB
   row 写入已确认；UI flow 复用 `web-admin-campaign-workflow §6.7` /
   `web-admin-ui-redesign §6.7` 同形 deferred。
2. **Live LLM 实拨号**: engine 用 DB 凭据真调豆包 LLM → 拨 13301035545
   听 AI 开场白。**与 `project_a2_d1_joint_mvp_gate` 联合 MVP 同步**；
   本 change 不在 scope。证据: engine `credentials_loaded count=2`
   表明装载链路 OK，真 RTC join + 真 LLM/ASR/TTS round-trip 在联合 MVP
   gate。
3. **Live reload**: v1.0 不实装；UI 改 key 后必须 `systemctl restart
   isales-engine` 才生效 (≤ 5s)。后续 change 加 Redis pub/sub 通道
   `isales:credentials:reload` 让 engine 订阅 → `await store.load()`。
4. **Settings 旧字段清理**: env 已清，但 isales-engine `Settings` 模型
   不再列；新部署用户 / 旧 deploy 文档可能仍引用 `ISALES_VOLCENGINE_APP_KEY`
   等。RUNBOOK-cloud.md / engine.env.example 已更新，但其他散落文档
   (project README, design doc 等) 待迭代时顺手清理。

## Risks / deviations observed during implementation

1. **既有 `isales_common.utils.crypto` 模块复用** — propose 时 spec 写
   "新建 `isales_common/credentials.py` 含 Fernet 初始化 + encrypt/decrypt"，
   实装时发现 `utils/crypto.py` 已存在 (ENV_KEY=`ISALES_FERNET_KEY`, 返
   urlsafe base64 str)。**调整**: `credentials.py` 改成包装层 (CredentialStore
   = batch load + cache + mask helper)，不重复实现 Fernet 调用。propose
   spec 同步改 `ISALES_CRED_FERNET_KEY → ISALES_FERNET_KEY` + cipher
   字段类型 `BYTEA → Text`，与既有模块对齐。
2. **`updated_by` FK user.id → VARCHAR(64) JWT sub** — propose 写 "FK
   user.id ON DELETE SET NULL"，实装时发现项目无 `user` 表 (JWT 解 dict
   直接走 `current_user` dep)。**调整**: spec/design/migration 改成
   VARCHAR(64) 存 JWT `sub` claim string，无 FK。
3. **`callback_config.signing_secret` 类型不改** — propose 写 "类型从
   String(64) 改 LargeBinary (BYTEA)"，实装查 schema 现状是 Text，已
   兼容 urlsafe-base64 Fernet cipher str。**调整**: 不改类型，仅约束语义；
   migration 跑一次性加密 SQL (Fernet token prefix `gAAAA` idempotent guard)。
4. **api 进程 startup 不预装 CredentialStore** — propose 写 "isales-api
   startup 装载 CredentialStore"，实装发现 api 不直接调 provider，只
   用 module-level `crypto.encrypt/decrypt` 即可。**调整**: api startup
   不预装；engine + worker 才装。spec § "engine 启动期加载凭据" 字面不变。
5. **isales-web `enabled` 字段不入 DB** — propose / spec 写 "enabled
   字段也走 Fernet 加密入 DB"，实装时发现 engine 根本不读 `enabled`
   (UI hint only)。**调整**: 本次 ModelProviderConfig 不持久化 enabled，
   只持久化 5 个真正影响 engine 的字段 (api_key/app_key/app_token/endpoint/
   default_model)。spec 字面有 `enabled` 字段但 ALLOWED_FIELD_NAMES
   白名单含 `enabled` (留路给后续)；当前实装 UI 不发该字段。
6. **Engine 装载条件简化**: design 写 `credentials_required=False` →
   "走 mock provider"，实装是空 store + engine_*_provider 仍是
   原 env 值；若用户设了 engine_llm_provider=volcengine 但 store 空，
   build_llm 抛 NotImplementedError (而非默默走 mock)。**Mitigation**:
   dev/CI 用户需配合把 engine_*_provider 也设成 mock；spec 文字与实装
   一致（"falling back to mock requires `engine_*_provider=mock`"）。
7. **ECS 旧 `engine.env` 备份 perms** — `cp /etc/isales/env/engine.env
   /tmp/...` 跑 root，文件 owner root:root 0640；`sudo -u isales` 跑
   `isales-cred-migrate` 时读不了。**Mitigation**: 加 `chmod 644
   /tmp/engine.env.pre-cred-migrate` 一次性放权 + 跑完 `rm` 清理 (避
   免明文残留 /tmp 过长)。RUNBOOK §3 步骤已记。
8. **Settings 模型字段删除不报错** — pydantic-settings 默认 `extra="ignore"`，
   旧 env 字段 (ISALES_VOLCENGINE_APP_KEY 等) 即使存在也不在 Settings
   上 expose / 报错。**Implication**: env 旧字段不及时清理 = "假装没事"。
   `test_settings_no_longer_carries_provider_secrets` 测试就是验证这点
   (字段 not hasattr(settings, ...))。RUNBOOK §3 步骤含"清 env 旧
   字段"明示。
