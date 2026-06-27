## MODIFIED Requirements

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
  `ISALES_DASHSCOPE_API_KEY` / `ISALES_DASHSCOPE_BASE_URL` /
  `ISALES_VOLCENGINE_*_ENDPOINT` 等字段；4 个 env 文件 SHALL 仅持有
  `ISALES_FERNET_KEY`（同一值，4 处一致）以及非凭据配置（数据库
  URL / Redis URL / JWT secret / DingRTC AppId/AppKey 等）

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
  provider 分支；运行时调用 build_volcengine / build_dashscope 等真 provider
  SHALL 抛 `NotImplementedError` 明示原因
