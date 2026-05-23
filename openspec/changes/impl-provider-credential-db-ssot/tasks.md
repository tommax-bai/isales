## 1. 前置 / 共享模块（isales-common）

<!-- 2026-05-23 确认 cryptography>=42.0 已在 isales-common deps；无需添加 -->
- [x] 1.1 `cryptography` 包确认在 `isales-common` 依赖图中（应已通过其他间接依赖；如缺，加进 `pyproject.toml::dependencies`）
<!-- 2026-05-23 isales_common/credentials.py 包装现有 utils/crypto.encrypt/decrypt + CredentialStore(in-memory dict cache) + from_db(session) + get/has/fields/providers/row_count + mask 静态方法 -->
- [x] 1.2 新建 `isales_common/credentials.py`：`CredentialStore` 类，封装 `Fernet` 初始化、`encrypt(str) -> bytes`、`decrypt(bytes) -> str`、`mask(str) -> str`、`from_db(session) -> CredentialStore`、`get(provider_id, field_name) -> str | None`
<!-- 2026-05-23 isales_common/models/provider_credential.py + 加入 models/__init__ __all__ -->
- [x] 1.3 新建 `isales_common/models/provider_credential.py`：`ProviderCredential` SQLAlchemy 模型（含 `id` / `provider_id` / `field_name` / `cipher_text` (Text) / `updated_by` (VARCHAR(64), JWT sub claim, no FK) / `updated_at` / UNIQUE `(provider_id, field_name)`）
<!-- 2026-05-23 isales_common/schemas/provider_credential.py: ProviderCredentialUpsert (含 plaintext_value) + ProviderCredentialRead (含 masked_value 由 API 层填) -->
- [x] 1.4 新建 `isales_common/schemas/provider_credential.py`：Pydantic `ProviderCredentialUpsert` / `ProviderCredentialRead`（read 仅返回 masked + meta）
<!-- N/A: signing_secret 已是 Text 列；本 change 不改类型，仅约束语义 (urlsafe base64 Fernet cipher，与 provider_credential.cipher_text 同 format) -->
- [x] 1.5 ~~改 `isales_common/models/callback_config.py`：`signing_secret` 列类型~~ (无需改 — 现状已是 Text)
<!-- 2026-05-23 alembic/versions/b2c3d4e5f6a7_add_provider_credential.py：CREATE TABLE + UNIQUE + ix；upgrade 含一次性加密 callback_config.signing_secret 行 (skip if ISALES_FERNET_KEY 未设)；downgrade 反向 + 解密 best-effort -->
- [x] 1.6 新增 alembic migration `<rev>_add_provider_credential.py`：① `CREATE TABLE provider_credential` (id BIGSERIAL PK, provider_id VARCHAR(32), field_name VARCHAR(32), cipher_text TEXT NOT NULL, updated_by VARCHAR(64) (JWT sub), updated_at TIMESTAMPTZ NOT NULL DEFAULT now()) + UNIQUE 索引 `(provider_id, field_name)` + 普通索引 `provider_id`；② callback_config.signing_secret 一次性加密 (`UPDATE ... WHERE signing_secret IS NOT NULL AND signing_secret NOT LIKE 'gAAAA%'`)；downgrade 反向 (DROP TABLE provider_credential + 解密 callback_config.signing_secret)
<!-- 2026-05-23 isales_common/cli/cred_migrate.py 含 import-env / export-env 双子命令；ENV_KEY_MAP 覆盖 volcengine/openai/dashscope 三家 11 个 ENV key；asyncio.run() + pg INSERT ... ON CONFLICT DO UPDATE 实 upsert；明文不入 stdout，dry-run 打 mask -->
- [x] 1.7 新建 `isales_common/cli/cred_migrate.py` + pyproject `[project.scripts]` `isales-cred-migrate = isales_common.cli.cred_migrate:main`；支持 `import-env --env-file <path> [--apply]` 与 `export-env --env-file <path> [--apply]` 两个子命令；明文不打 stdout，仅 dry-run 打 masked 计划
<!-- 2026-05-23 tests/test_credentials.py (10) + tests/test_cli_cred_migrate.py (12) 全绿；全量 isales-common pytest 151 passed 0 fail。from_db 留集成侧 (api/engine) 覆盖 — 不在 isales-common 装 PG/sqlite session fixture -->
- [x] 1.8 pytest：`tests/test_credentials.py` 覆盖 Fernet 加解密对称性、mask 格式、`CredentialStore.from_db` 装载 / 缺失行为；`tests/test_cred_migrate.py` 覆盖 import-env idempotent + export-env round-trip
<!-- 2026-05-23 pyproject 0.3.2 → 0.4.0，加 [project.scripts] isales-cred-migrate -->
- [x] 1.9 bump `pyproject.toml::version` 0.3.x → 0.4.0（model + cipher 语义改 = breaking）

## 2. 后端 — isales-api router

- [ ] 2.1 新建 `isales_api/routers/provider_credentials.py`：`GET /` list（masked）/ `GET /{provider_id}` / `POST /` upsert / `DELETE /{id}` / `POST /reload-hint`；JWT 鉴权对齐 `leads.py` 模式；POST 校验 `provider_id` 在 `KNOWN_LLM_PROVIDERS ∪ KNOWN_ASR_PROVIDERS ∪ KNOWN_TTS_PROVIDERS`，`field_name` 在白名单
- [ ] 2.2 改 `isales_api/main.py`：include `provider_credentials.router`；startup 阶段加载 `CredentialStore`（虽然 api 进程本身不真调 provider，但 callback signing_secret rotate 需要 Fernet fabric）
- [ ] 2.3 改 `isales_api/routers/callback_configs.py`（如未实装则本 change 不创建，仅占位测试）：`POST /` 路径生成 signing_secret 加密；`POST /{id}/rotate-secret` 端点；GET 返回 masked
- [ ] 2.4 pytest：`tests/test_provider_credentials.py`（10+ 测试）：CRUD + 鉴权 + 未知 provider_id 拒绝 + masked 不漏明文 + upsert idempotent + audit `updated_by` 写入；`tests/test_callback_signing_secret.py`：创建一次性回显、rotate 后旧 cipher 不能验证签名
- [ ] 2.5 改 `pyproject.toml::dependencies`：`isales-common>=0.4.0,<0.5`
- [ ] 2.6 本机 pytest 全绿

## 3. 后端 — isales-engine 凭据装载

- [ ] 3.1 改 `isales_engine/settings.py`：删 `volcengine_app_key` / `volcengine_app_token` / `openai_api_key` / `openai_base_url` / `volcengine_*_endpoint` / `volcengine_llm_model` / `openai_llm_model` 等所有 provider 密钥与配置字段；新增 `credentials_required: bool = True`（env: `ISALES_CREDENTIALS_REQUIRED`）
- [ ] 3.2 改 `isales_engine/providers/factory.py`：`build_llm` / `build_asr` / `build_tts` 第一参数仍是 `name: str`，但凭据源改为传入的 `CredentialStore`（新增第二参数）；`mock` 分支不变；其他 provider 分支从 store.get() 取 key/token/endpoint
- [ ] 3.3 改 `isales_engine/main.py`（或对应 startup 钩子）：startup 阶段查 DB 装载 `CredentialStore.from_db(session)`，缓存到 app.state；`build_*` 时透传给 factory
- [ ] 3.4 改 `isales_engine` 内所有 factory 调用点：找出所有 `build_llm("volcengine")` / `build_asr(...)` 形态，加 store 参数；预计 5-10 个调用点
- [ ] 3.5 startup 装载失败行为：`credentials_required=true` + 失败 = exit；`credentials_required=false` = warn + provider_factory 强制走 mock
- [ ] 3.6 pytest：`tests/test_factory_db_credentials.py` 覆盖 ① store 注入 → build_llm 用 DB 凭据；② store=None + credentials_required=false → mock；③ store 装载失败 + credentials_required=true → startup exit；更新现有 `tests/test_providers.py` 适应新签名
- [ ] 3.7 改 `pyproject.toml::dependencies`：`isales-common>=0.4.0,<0.5`
- [ ] 3.8 本机 pytest 全绿

## 4. 后端 — isales-worker callback 签名

- [ ] 4.1 改 `isales_worker` webhook 发送模块（位置看现有代码）：HMAC 签名前先 `CredentialStore.decrypt(callback_config.signing_secret)` 得明文；store 由 worker startup 装载（同 engine 形态）
- [ ] 4.2 pytest：`tests/test_webhook_signing.py` 覆盖 cipher 解密 + HMAC 签名 + 旧 secret rotate 后失效
- [ ] 4.3 改 `pyproject.toml::dependencies`：`isales-common>=0.4.0,<0.5`
- [ ] 4.4 本机 pytest 全绿

## 5. 前端 — isales-web ModelProviderConfig 切 API

- [ ] 5.1 新建 `src/api/providerCredentials.ts`：`list()` / `getByProvider(id)` / `upsert({provider_id, field_name, plaintext_value})` / `remove(id)` 对接 §2.1 端点
- [ ] 5.2 新建 `src/types/providerCredential.ts`：`ProviderCredentialRead { id, provider_id, field_name, masked_value, updated_by, updated_at }` + `ProviderCredentialUpsert { provider_id, field_name, plaintext_value }`
- [ ] 5.3 改 `src/views/Config/ModelProviderConfig.vue`：删 `useLocalConfigStash<model-providers-v3>` 调用；onMounted 改 `providerCredentialsApi.list()`；onSave 按字段 diff 后逐字段 upsert / delete；显示用 `masked_value`；输入空值 = 不发请求保持现状；banner 文案改写为「凭据已 DB 落库 + Fernet 加密 + 改 key 需重启 engine 生效」
- [ ] 5.4 加一次性 localStorage 清理：app boot 时检查 `localStorage.getItem("model-providers-v3")`，存在则 `removeItem` 并 console.info 提示
- [ ] 5.5 跑 `npm run check:routes` + `npm run check:api`（against ECS 部署后）确保新 `/api/provider-credentials` 端点 401 mount OK
- [ ] 5.6 `npm run build` + `npm test` 全绿

## 6. 部署侧 env / 文档调整

- [ ] 6.1 改 `deploy/cloud/env/{api,engine,worker,scheduler}.env`：删 `ISALES_VOLCENGINE_APP_KEY` / `ISALES_VOLCENGINE_APP_TOKEN` / `ISALES_OPENAI_API_KEY` / `ISALES_OPENAI_BASE_URL` / `ISALES_VOLCENGINE_*_ENDPOINT` / `ISALES_VOLCENGINE_LLM_MODEL` / `ISALES_OPENAI_LLM_MODEL`；新增 `ISALES_FERNET_KEY=...`（4 个 env 文件同一值）
- [ ] 6.2 改 `deploy/cloud/env/README.md`：env 字段清单同步；新增 § "Fernet 主密钥生成与备份"（python `Fernet.generate_key()` + 写 password manager + 写 SECRETS.md）
- [ ] 6.3 改 `deploy/cloud/env/.gitignore`（如未有）：`SECRETS.md` 被 gitignored；保证 Fernet key 不入 git
- [ ] 6.4 新建 `deploy/cloud/env/SECRETS.md.example`：模板「Fernet 主密钥写在这里」+ 警告"不入 git"
- [ ] 6.5 改 `deploy/RUNBOOK-cloud.md`：新增 § "凭据轮换"（① Fernet 主密钥轮换 = 解密旧 cipher + 加密新 key + 同步 4 env + restart；② 单 provider key 旋转 = UI 改 / 或 psql + restart engine；③ rollback = `isales-cred-migrate export-env --apply` 反向）
- [ ] 6.6 改 `deploy/RUNBOOK-cloud.md` § "首次部署"：在 alembic upgrade 后 + 服务 restart 前插入 step 「a) 生成 Fernet key 写 4 env；b) `isales-cred-migrate import-env --env-file api.env --apply`；c) 验证 `psql -c "select provider_id, field_name from provider_credential order by 1,2"`；d) 清旧 env 字段」
- [ ] 6.7 跑 `make deploy-check`（env-template ↔ README 一致性 + shellcheck）

## 7. ECS 部署 + smoke

- [ ] 7.1 dev box 本机起 isales-api + isales-engine 串通：UI 改一个 key → 重启 engine → 拨豆包 LLM 测试通
- [ ] 7.2 `make test-all` 全绿
- [ ] 7.3 ECS 部署：① 4 个 sub-repo git bundle scp 上 ECS git fetch；② alembic upgrade head（建 provider_credential 表 + alter callback signing_secret 类型）；③ 4 env 文件加 `ISALES_FERNET_KEY`（同一值）；④ `isales-cred-migrate import-env --env-file /etc/isales/env/api.env --apply` 读旧 env 凭据 → 加密写 DB；⑤ pip install -e isales-common（0.4.0）；⑥ systemctl restart isales-{api,engine,worker,scheduler}；⑦ journalctl grep `credentials_loaded` 确认装载成功
- [ ] 7.4 浏览器烟测：模型厂商 view → 改一个 endpoint → 提交看 mask preview 更新；后端检查 `psql -c "select provider_id, field_name, updated_at from provider_credential"` 验证写入
- [ ] 7.5 真拨号 / mock 拨号验证 engine 用 DB 凭据：拨 13301035545 听 AI 开场白（与 [[project-a2-d1-joint-mvp-gate]] 联合 MVP 同步）
- [ ] 7.6 清 ECS 4 env 文件的旧 provider 密钥字段（per 6.1 同 diff）→ systemctl reload-or-restart engine → 再次验证 startup 装载（不再读 env）
- [ ] 7.7 isales-web build + scp dist + nginx reload（per memory [[feedback-build-then-deploy-atomic]] 原子化执行）
- [ ] 7.8 跑 `npm run check:api --endpoint=http://121.89.85.150/api` 确认新 endpoint 401 mount OK + 0 dead
- [ ] 7.9 更新 `deploy/cloud/STATE.md`：凭据来源段落（env → DB） + alembic head bump + 加密 fabric 说明

## 8. 清理 + 验证 + archive

- [ ] 8.1 grep 确认无残留：`ISALES_VOLCENGINE_APP_KEY` / `ISALES_OPENAI_API_KEY` 等密钥字段在 isales-engine `Settings` 模型 + env-template 中均不存在
- [ ] 8.2 grep 确认前端无 `useLocalConfigStash<.*model-providers` 残留
- [ ] 8.3 跑 `openspec validate impl-provider-credential-db-ssot --strict` 通过
- [ ] 8.4 跑 `openspec validate --specs && --changes` 全绿
- [ ] 8.5 补 `acceptance.md`（verified local + verified cloud + spec deltas + cloud deploy log + deviations）
- [ ] 8.6 commit + push 各 sub-repo + meta-repo + openspec archive impl-provider-credential-db-ssot --yes
