## MODIFIED Requirements

### Requirement: 已 spec 能力的 UI 暴露

`isales-web` SHALL 在 view 中暴露以下 backend 已 spec 的能力：

- 多并行 prompt 配置（`role-prompt`、`filler`、`goal-achievement`、
  `ai-pipeline`）— 在 **campaign 详情 view** 中按 4 个 tier（对话策略 /
  垫词 / 质量判别 / 润色）分组，per-campaign 增删改 + enable switch +
  temperature/topP 滑杆 + provider/model 选择器
- 可通话时段配置（`time-window`）— 在 **campaign 详情 view** 中以多个时段
  卡片形式列出，每段含开始时间、结束时间、周一至周日 7 个 checkbox，写入
  该 `campaign.time_windows`
- AI 服务商凭据管理（`provider-abc` + `provider-credential`）— 在「模型
  厂商」view 中统一管理 LLM / ASR / TTS provider，按 provider 分卡片，含
  API key 密码输入 + endpoint + 默认 model + enable switch + 状态徽标。
  **凭据 SHALL 通过 `/api/provider-credentials` admin API 直接落库**
  （`provider_credential` 表，Fernet 加密；MUST NOT 用 localStorage 兜
  底）。UI 仅显示 mask preview，改 key = 整段替换。volcengine 一套
  app_key/token 同时供 LLM / ASR / TTS（凭据一体，故不为 ASR/TTS 单设
  view）；ASR/TTS provider 为引擎进程级全局，非 per-campaign
- ASR 完整对话内容（`transcript`）— 在外呼记录 view 的每条记录上以可折叠
  面板展示，AI 与客户消息用左右气泡区分
- 目标达成评分（`goal-achievement`）— 在外呼记录卡片中展示评分、客户意向、
  是否成功预约、已覆盖的关键要点列表

#### Scenario: 多并行 prompt 编辑（per-campaign）

- **WHEN** 用户在 campaign 详情 view 添加一条新的对话策略
- **THEN** 表单 SHALL 提供 name / model provider / model name /
  temperature(0–2) / topP(0–1) / prompt 文本 / enable 开关；保存后 SHALL
  通过 admin API 写入归属该 campaign 的 `role_config` + `prompt_version`

#### Scenario: provider 选项对齐引擎实装

- **WHEN** 用户在 prompt 配置或 provider 配置中选择 model provider
- **THEN** 可选项 SHALL 对齐 `isales-engine` factory 实装的 provider
  （LLM：volcengine / openai / mock），MUST NOT 列出引擎未对接的
  provider（dashscope 等占位 provider 在 ModelProviderConfig 中以单独
  「占位」分类显示，banner 必须明确"engine 未对接"避免误导）

#### Scenario: 模型厂商配置写入 DB

- **WHEN** 用户在「模型厂商」view 输入 / 修改 / 删除一个 provider 的
  api_key / app_key / app_token / endpoint / default_model / enabled
- **THEN** UI SHALL 调用 `/api/provider-credentials` POST / DELETE
  接口；后端 SHALL Fernet 加密后 upsert 行；UI MUST NOT 把任何 provider
  密钥写入 localStorage（旧 `useLocalConfigStash` key `model-providers-v*`
  SHALL 不再被读写；本 change 同时 emit 一次性 cleanup 把残留 key
  从 localStorage 删除）

#### Scenario: API key 仅显示 mask preview

- **WHEN** 用户进入「模型厂商」view 看到已配置的 provider 卡片
- **THEN** API key / app_token 等敏感字段输入框 SHALL 显示
  `<前 4 字符>********<后 4 字符>` 形式（前后 4 字符之间 `*` 固定 8 个，
  不暴露真实长度）；MUST NOT 显示明文；改密钥 SHALL 整段替换（空输入
  代表"保持不变"，不发请求）

#### Scenario: 通话气泡显示

- **WHEN** 用户在外呼记录中点击"查看通话内容"
- **THEN** SHALL 展开可折叠区域，按 transcript 顺序逐条渲染气泡，AI 消息
  靠左、客户消息靠右，气泡上方 SHALL 显示角色标签
