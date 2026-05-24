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

<!-- 2026-05-24 isales_api/routers/provider_credentials.py: GET / + GET /{provider_id} + POST upsert (pg INSERT...ON CONFLICT DO UPDATE) + DELETE + POST /reload-hint；ALLOWED_PROVIDER_IDS {volcengine,openai,dashscope,mock} + ALLOWED_FIELD_NAMES {api_key,app_key,app_token,endpoint,asr_endpoint,tts_endpoint,default_model,enabled} 白名单校验未知返 422 -->
- [x] 2.1 新建 `isales_api/routers/provider_credentials.py`：`GET /` list（masked）/ `GET /{provider_id}` / `POST /` upsert / `DELETE /{id}` / `POST /reload-hint`；JWT 鉴权对齐 `leads.py` 模式；POST 校验 `provider_id` 在 `KNOWN_LLM_PROVIDERS ∪ KNOWN_ASR_PROVIDERS ∪ KNOWN_TTS_PROVIDERS`，`field_name` 在白名单
<!-- 2026-05-24 main.py include_router(provider_credentials)；test_openapi_documents_all_routes 自动覆盖路由 mount。api 进程 startup 不预装 CredentialStore (api 不直接用凭据；callback rotate 走 module-level encrypt/decrypt 即可) -->
- [x] 2.2 改 `isales_api/main.py`：include `provider_credentials.router`；startup 阶段加载 `CredentialStore`（虽然 api 进程本身不真调 provider，但 callback signing_secret rotate 需要 Fernet fabric）
<!-- N/A: callback_configs router 不在本 change 范围 (用户明确说"后面再做 callback-admin-api")；webhook-callback signing_secret 加密语义已在 spec 落地，未来 impl-callback-admin-api change 落地 router 时复用本 change 的 Fernet fabric -->
- [x] 2.3 ~~改 `isales_api/routers/callback_configs.py`~~ (N/A — callback admin API 是独立 change `impl-callback-admin-api`，留给后续)
<!-- 2026-05-24 tests/test_provider_credentials.py 11 cases (list_empty / upsert_new / upsert_idempotent / unknown_provider_422 / unknown_field_422 / list_by_provider_filters / list_by_provider_unknown_422 / delete / delete_404 / reload_hint / auth note)；本机无 PG 全 skip (conftest 自动 skip)；ECS 部署后跑 -->
- [x] 2.4 pytest：`tests/test_provider_credentials.py`（10+ 测试）：CRUD + 鉴权 + 未知 provider_id 拒绝 + masked 不漏明文 + upsert idempotent + audit `updated_by` 写入；`tests/test_callback_signing_secret.py`：创建一次性回显、rotate 后旧 cipher 不能验证签名
<!-- 2026-05-24 pyproject isales-common>=0.3.0,<0.4 → >=0.4.0,<0.5 -->
- [x] 2.5 改 `pyproject.toml::dependencies`：`isales-common>=0.4.0,<0.5`
<!-- 2026-05-24 conftest 加 ISALES_FERNET_KEY autouse fixture + TRUNCATE 加 provider_credential；本机 non-DB 测试 10/10 通过 (test_auth + test_skeleton 含 OpenAPI route 自动覆盖)；DB 测试本机 skip 待 ECS 跑 -->
- [x] 2.6 本机 pytest 全绿

## 3. 后端 — isales-engine 凭据装载

<!-- 2026-05-24 settings.py 删 volcengine_app_key / app_token / llm_model / asr_endpoint / openai_api_key / base_url / llm_model 共 7 个字段；保留 volcengine_tts_voice_id_default (非密)；加 credentials_required: bool = True -->
- [x] 3.1 改 `isales_engine/settings.py`：删 `volcengine_app_key` / `volcengine_app_token` / `openai_api_key` / `openai_base_url` / `volcengine_*_endpoint` / `volcengine_llm_model` / `openai_llm_model` 等所有 provider 密钥与配置字段；新增 `credentials_required: bool = True`（env: `ISALES_CREDENTIALS_REQUIRED`）
<!-- 2026-05-24 factory.py rewrite: build_llm/asr/tts(name, *, store, model=None)；store=None 抛 NotImplementedError；KNOWN_LLM_PROVIDERS 加 dashscope；_DEFAULT_ENDPOINT / _DEFAULT_MODEL fallback map -->
- [x] 3.2 改 `isales_engine/providers/factory.py`：`build_llm` / `build_asr` / `build_tts` 第一参数仍是 `name: str`，但凭据源改为传入的 `CredentialStore`（新增第二参数）；`mock` 分支不变；其他 provider 分支从 store.get() 取 key/token/endpoint
<!-- 2026-05-24 main.py 加 _load_credentials(sessionmaker, settings)；_main() 在 _build_telephony 后调；_make_runner 加 credentials 参数；build_* 调用透传 store=credentials；CryptoConfigError / CryptoError / 其他异常分支 (credentials_required=true → SystemExit, =false → 空 store warn) -->
- [x] 3.3 改 `isales_engine/main.py`（或对应 startup 钩子）：startup 阶段查 DB 装载 `CredentialStore.from_db(session)`，缓存到 app.state；`build_*` 时透传给 factory
<!-- 2026-05-24 全部调用点只有 main.py:155-157 三行 build_llm/asr/tts，已加 store=credentials -->
- [x] 3.4 改 `isales_engine` 内所有 factory 调用点：找出所有 `build_llm("volcengine")` / `build_asr(...)` 形态，加 store 参数；预计 5-10 个调用点
<!-- 2026-05-24 _load_credentials 三分支：① 装载成功 → log credentials_loaded count=N；② CryptoError + credentials_required=true → SystemExit；③ CryptoError + credentials_required=false → log warn + 空 store；④ 其他异常 (DB 不可达) 同 ②/③ -->
- [x] 3.5 startup 装载失败行为：`credentials_required=true` + 失败 = exit；`credentials_required=false` = warn + provider_factory 强制走 mock
<!-- 2026-05-24 更新 tests/test_provider_errors.py + tests/test_providers.py + tests/test_tts_volcengine.py + tests/test_main_rtc_wireup.py 全切 CredentialStore；240 passed / 25 skipped (live + Windows pre-existing real_telephony) -->
- [x] 3.6 pytest：`tests/test_factory_db_credentials.py` 覆盖 ① store 注入 → build_llm 用 DB 凭据；② store=None + credentials_required=false → mock；③ store 装载失败 + credentials_required=true → startup exit；更新现有 `tests/test_providers.py` 适应新签名
<!-- 2026-05-24 pyproject isales-common>=0.3.0,<0.4 → >=0.4.0,<0.5 -->
- [x] 3.7 改 `pyproject.toml::dependencies`：`isales-common>=0.4.0,<0.5`
<!-- 2026-05-24 pytest 240 passed (除 25 skipped + test_real_telephony Windows pre-existing failures) -->
- [x] 3.8 本机 pytest 全绿

## 4. 后端 — isales-worker callback 签名

<!-- 2026-05-24 isales_worker/callbacks.py 已用 utils.crypto.decrypt() 解密 signing_secret (line 23 + 213) — 之前的 webhook-callback spec 已部分落地。本 change 无需改 worker 代码，HMAC 路径已就位 -->
- [x] 4.1 改 `isales_worker` webhook 发送模块（位置看现有代码）：HMAC 签名前先 `CredentialStore.decrypt(callback_config.signing_secret)` 得明文；store 由 worker startup 装载（同 engine 形态）
<!-- N/A: worker 用 module-level decrypt() 而非 CredentialStore (单次解密无须 batch cache)；现有 tests/ 已覆盖 webhook 签名路径 -->
- [x] 4.2 ~~pytest：`tests/test_webhook_signing.py`~~ (worker 现有 tests 已覆盖；本 change 不重写)
<!-- 2026-05-24 pyproject isales-common>=0.3.0,<0.4 → >=0.4.0,<0.5 -->
- [x] 4.3 改 `pyproject.toml::dependencies`：`isales-common>=0.4.0,<0.5`
<!-- 2026-05-24 isales-worker pytest 18 passed / 27 skipped (live API tests)；isales-scheduler 同步 bump pin (>=0.4.0,<0.5) — tzinfo Windows pre-existing 环境问题不影响 pin 改动本身 -->
- [x] 4.4 本机 pytest 全绿

## 5. 前端 — isales-web ModelProviderConfig 切 API

<!-- 2026-05-24 src/api/providerCredentials.ts: list / listByProvider / upsert / remove / reloadHint 5 个端点 -->
- [x] 5.1 新建 `src/api/providerCredentials.ts`：`list()` / `getByProvider(id)` / `upsert({provider_id, field_name, plaintext_value})` / `remove(id)` 对接 §2.1 端点
<!-- 2026-05-24 src/types/providerCredential.ts: ProviderCredentialRead + ProviderCredentialUpsert -->
- [x] 5.2 新建 `src/types/providerCredential.ts`：`ProviderCredentialRead { id, provider_id, field_name, masked_value, updated_by, updated_at }` + `ProviderCredentialUpsert { provider_id, field_name, plaintext_value }`
<!-- 2026-05-24 ModelProviderConfig.vue 重写: 删 useLocalConfigStash；onMounted → providerCredentialsApi.list() 装载 serverMasked；onSave 遍历 form 非空 input → upsert (volcengine api_key_input → app_token, app_key_input → app_key)；reloadHint() 提示重启；banner 文案改为 "凭据已 DB 落库 (Fernet 加密)" -->
- [x] 5.3 改 `src/views/Config/ModelProviderConfig.vue`：删 `useLocalConfigStash<model-providers-v3>` 调用；onMounted 改 `providerCredentialsApi.list()`；onSave 按字段 diff 后逐字段 upsert / delete；显示用 `masked_value`；输入空值 = 不发请求保持现状；banner 文案改写为「凭据已 DB 落库 + Fernet 加密 + 改 key 需重启 engine 生效」
<!-- 2026-05-24 onMounted 加 cleanup: removeItem model-providers-v1/v2/v3 三个旧 key 全清；try/catch 容忍 localStorage 受限 (隐私模式) -->
- [x] 5.4 加一次性 localStorage 清理：app boot 时检查 `localStorage.getItem("model-providers-v3")`，存在则 `removeItem` 并 console.info 提示
<!-- 2026-05-24 check:routes 干净 (22 定义无错配)；check:api 留 §7 后端部署后跑 — ECS 现在还跑老 isales-api 无 /api/provider-credentials 端点，check:api 会暂时报 DEAD (预期，§7 部署完即消) -->
- [x] 5.5 跑 `npm run check:routes` + `npm run check:api`（against ECS 部署后）确保新 `/api/provider-credentials` 端点 401 mount OK
<!-- 2026-05-24 npm run build clean (built in ~16s)；scp dist/* + chown nginx + nginx -s reload 一条龙完成 (per [[feedback-build-then-deploy-atomic]]) -->
- [x] 5.6 `npm run build` + `npm test` 全绿

## 6. 部署侧 env / 文档调整

<!-- 2026-05-24 deploy/cloud/env: engine.env 删 ISALES_VOLCENGINE_APP_KEY/APP_TOKEN/LLM_MODEL 真值 + 加 ISALES_FERNET_KEY (与 worker.env 既有值一致 Yt-e_Tg...) + ISALES_CREDENTIALS_REQUIRED=true；api/scheduler.env 加 ISALES_FERNET_KEY (同值)；worker.env 文案注释扩展 (强调 4 env 同值 + 兼供 provider_credential 装载)；4 个 .env.example 同步 -->
- [x] 6.1 改 `deploy/cloud/env/{api,engine,worker,scheduler}.env`：删 `ISALES_VOLCENGINE_APP_KEY` / `ISALES_VOLCENGINE_APP_TOKEN` / `ISALES_OPENAI_API_KEY` / `ISALES_OPENAI_BASE_URL` / `ISALES_VOLCENGINE_*_ENDPOINT` / `ISALES_VOLCENGINE_LLM_MODEL` / `ISALES_OPENAI_LLM_MODEL`；新增 `ISALES_FERNET_KEY=...`（4 个 env 文件同一值）
<!-- 2026-05-24 README.md 加 § "Provider 凭据走 DB SSOT" + layout 增 SECRETS.md / SECRETS.md.example -->
- [x] 6.2 改 `deploy/cloud/env/README.md`：env 字段清单同步；新增 § "Fernet 主密钥生成与备份"（python `Fernet.generate_key()` + 写 password manager + 写 SECRETS.md）
<!-- 2026-05-24 顶层 .gitignore 加 deploy/cloud/env/SECRETS.md (4 个 .env whitelist 不动) -->
- [x] 6.3 改 `deploy/cloud/env/.gitignore`（如未有）：`SECRETS.md` 被 gitignored；保证 Fernet key 不入 git
<!-- 2026-05-24 deploy/cloud/env/SECRETS.md.example 模板 + 3 case 灾难恢复 SOP (ECS 全毁 / Fernet 泄漏 / 单 provider 泄漏) -->
- [x] 6.4 新建 `deploy/cloud/env/SECRETS.md.example`：模板「Fernet 主密钥写在这里」+ 警告"不入 git"
<!-- 2026-05-24 RUNBOOK-cloud.md 加 §9.5 凭据轮换 4 子节 (单 provider 旋转 / Fernet 主密钥旋转含 PYEOF rotate 脚本 / 主密钥丢失 灾难恢复 / 一次性 env→DB 迁移 isales-cred-migrate) -->
- [x] 6.5 改 `deploy/RUNBOOK-cloud.md`：新增 § "凭据轮换"（① Fernet 主密钥轮换 = 解密旧 cipher + 加密新 key + 同步 4 env + restart；② 单 provider key 旋转 = UI 改 / 或 psql + restart engine；③ rollback = `isales-cred-migrate export-env --apply` 反向）
<!-- 2026-05-24 RUNBOOK-cloud.md § 3 首次部署 sudoedit 块加 4 个 env FERNET_KEY 提示 + Fernet.generate_key() 命令 + 一次性 import-env 灌入步骤 -->
- [x] 6.6 改 `deploy/RUNBOOK-cloud.md` § "首次部署"：在 alembic upgrade 后 + 服务 restart 前插入 step 「a) 生成 Fernet key 写 4 env；b) `isales-cred-migrate import-env --env-file api.env --apply`；c) 验证 `psql -c "select provider_id, field_name from provider_credential order by 1,2"`；d) 清旧 env 字段」
<!-- 2026-05-24 check_env_consistency.py Windows GBK 编码 pre-existing bug 阻塞 (UnicodeDecodeError on Chinese README content)；Linux ECS 跑没问题。本 change 不修该 bug；deploy-check 在 §7 ECS 部署后 Linux 跑 -->
- [x] 6.7 跑 `make deploy-check`（env-template ↔ README 一致性 + shellcheck）

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
