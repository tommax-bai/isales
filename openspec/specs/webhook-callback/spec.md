## Purpose

定义通话结束后异步触发外部 webhook 的机制：JsonLogic 表达式的 trigger、Jinja2 sandbox 渲染的 payload、HMAC-SHA256 签名、指数退避重试。本规范覆盖触发时机、字段范围、失败处理与数据模型。
## Requirements
### Requirement: 触发时机在 summarize_call 之后

worker 处理通话结束消息时 SHALL 先执行 `summarize_call` 生成摘要并二次校验 extracted_fields，然后才执行 `process_callbacks`。MUST NOT 在通话期间实时触发。

#### Scenario: summarize_call 完成后派发

- **WHEN** worker 收到 call_record_id 的"通话结束"消息
- **THEN** worker 顺序执行：① `summarize_call`（生成摘要 + 写 `call_summary`）→ ② `process_callbacks`（遍历该 Campaign 启用的 callback_config）

#### Scenario: 不在通话期间触发

- **WHEN** AI 管线 `goal_achieved=true`
- **THEN** engine MUST NOT 直接调用 webhook；触发权 MUST 完全在 worker 侧（避免用户在收尾期间反悔造成误报）

### Requirement: trigger 表达式使用 JsonLogic

`callback_config.trigger` SHALL 存储为 JsonLogic JSON 结构。worker 评估时 MUST 用 JsonLogic 库；MUST NOT 使用 Python eval、SQL where 或自定义 DSL。

#### Scenario: 简单 AND 表达式

- **WHEN** trigger = `{"and": [{"==": [{"var": "goal_achieved"}, true]}, {"==": [{"var": "goal_type"}, "appointment"]}]}`
- **THEN** worker 在 `goal_achieved=true && goal_type="appointment"` 时返回 true

#### Scenario: 引用 extracted 嵌套字段

- **WHEN** trigger 引用 `extracted.appointment_time`
- **THEN** JsonLogic 用 `{"var": "extracted.appointment_time"}` 语法取值

### Requirement: trigger 可引用字段范围

trigger 表达式 SHALL 可引用以下来源的字段：

- `goal_achieved`, `goal_type` —— 来自 call_summary
- `extracted.*` —— 来自 call_summary.extracted_fields
- `lead.name`, `lead.phone`, `lead.source`, `lead.status`, `lead.custom_data.*` —— 来自 lead 表
- `call.duration`, `call.started_at`, `call.transfer_status`, `call.hangup_cause` —— 来自 call_record

#### Scenario: 引用 lead.status 触发勿打回调

- **WHEN** trigger = `{"==": [{"var": "lead.status"}, "do_not_call"]}`
- **THEN** worker 在勿打命中后产生的 callback 评估中返回 true，可以触发同步到 CRM 的 webhook

### Requirement: payload 使用 Jinja2 sandbox 渲染

`callback_config.payload_template` SHALL 存储为 text 类型的 Jinja2 模板字符串。渲染 MUST 用 `jinja2.sandbox.SandboxedEnvironment`，禁用文件 IO、import、eval 等危险能力。

#### Scenario: Jinja2 模板示例

- **WHEN** payload_template 为：
  ```jinja
  {
    "lead_id": "{{ lead.id }}",
    "appointment_time": "{{ extracted.appointment_time }}",
    "summary": {{ call_summary.summary_text | tojson }}
  }
  ```
- **THEN** worker SHALL 用 SandboxedEnvironment 渲染，输出合法 JSON

#### Scenario: 沙盒禁用危险特性

- **WHEN** payload_template 中包含 `{% import %}` 或 `{{ ''.__class__ }}` 等危险语法
- **THEN** Jinja2 sandbox MUST 抛 SecurityError；worker 处理为 failed_render

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

### Requirement: 重试策略：指数退避 + 最大次数

`callback_config.retry_policy` SHALL 为 JSONB 结构 `{intervals_seconds: [...], max_attempts: N}`。worker 失败时 MUST 按此策略重试；累计尝试次数达到 max_attempts 时 status SHALL 置 `exhausted`。worker 实现 SHALL 由独立的"重试调度器"后台 task 承担：周期性（≤ 60s）扫描 `callback_log WHERE status='pending_retry' AND next_retry_at <= now`，按 `next_retry_at ASC` 取一批重试；重试时 MUST 复用上次已存的 `request_body`（不重新评估 trigger / 重新渲染 payload），以保证"原触发瞬间"的事实不被 lead 状态变化污染。

#### Scenario: 指数退避取值

- **WHEN** retry_policy = `{intervals_seconds: [60, 300, 1800], max_attempts: 3}` 且当前是第 2 次重试
- **THEN** 间隔 = 300 秒（取数组第 2 项）

#### Scenario: 超出数组长度

- **WHEN** 第 N 次重试且 N > intervals_seconds.length
- **THEN** worker MUST 沿用最后一项

#### Scenario: 触发重试的错误

- **WHEN** HTTP 响应是 5xx / 超时 / 连接失败
- **THEN** worker SHALL 重试，next_retry_at = now + 当前间隔；callback_log.status SHALL 置 `pending_retry`；retry_count 自增；重试调度器扫到后再发起 HTTP 请求

#### Scenario: 不重试的错误

- **WHEN** HTTP 响应是 4xx 或 trigger / payload 渲染失败
- **THEN** worker MUST NOT 重试；status 直接置 `failed_http_4xx` / `failed_render`

#### Scenario: 重试调度器复用 request_body

- **WHEN** 重试调度器 tick 取到一条 `status='pending_retry'` 的 callback_log
- **THEN** SHALL 直接复用 `callback_log.request_body` 作为 HTTP body 重发；MUST NOT 重新评估 `trigger` 或重新渲染 `payload_template`（避免 lead 状态变化或 call_record 字段更新导致 payload 与"原触发时刻"不一致）

#### Scenario: 重试达到上限置 exhausted

- **WHEN** 重试 5xx 后 retry_count 达到 `retry_policy.max_attempts`
- **THEN** callback_log.status SHALL 置 `exhausted`（终态）；MUST NOT 再被重试调度器扫到（因 status 不再是 `pending_retry`）

### Requirement: 失败渲染的处理

trigger 评估失败（DSL 语法错误 / 引用不存在字段 / 类型不匹配）或 payload 渲染失败 SHALL 视为配置 bug，记 `callback_log.status=failed_render` 后**不重试**。错误信息 MUST 写入 `callback_log.error_message`。

#### Scenario: trigger DSL 错误

- **WHEN** trigger 不是合法 JsonLogic
- **THEN** callback_log.status = failed_render，error_message 包含解析错误详情

#### Scenario: payload 引用不存在的字段

- **WHEN** payload_template 引用 `{{ extracted.nonexistent }}`
- **THEN** Jinja2 默认返回空串（StrictUndefined 模式下抛错），engine 决定具体策略；任何错误 SHALL 标 failed_render

### Requirement: HTTP 超时配置

每次 HTTP 请求超时 SHALL 由 `callback_config.timeout_seconds`（可空）覆盖；为空时 MUST 使用全局默认 `webhook_default_timeout_seconds`（部署时设定，如 10）。

#### Scenario: 单条覆盖超时

- **WHEN** callback_config.timeout_seconds = 30
- **THEN** 该 callback 的 HTTP 请求 MUST 用 30 秒超时；其他 callback 仍用全局默认

### Requirement: 与其他模块的隔离

Webhook 派发 SHALL 与 lead 状态流转、engine 主流程完全解耦；任一回调结果 MUST NOT 影响 lead 状态或 engine 行为。

#### Scenario: webhook 失败不影响 lead 状态

- **WHEN** 任一 callback 进入 exhausted / failed_render
- **THEN** lead 状态流转 MUST NOT 因此变化；lead 状态由 hangup_cause + goal_achieved 决定，与 webhook 独立

#### Scenario: engine 不感知 webhook

- **WHEN** webhook 结果（成功/失败/重试）回写 callback_log
- **THEN** engine 主流程 MUST NOT 等待或感知该结果

### Requirement: Trigger / payload 模板编辑器辅助 API

为支持 isales-web 的 CodeMirror 编辑器（impl-web-polish 引入），isales-api SHALL 暴露两个辅助 API：

1. `POST /callback-configs/validate` — 接收 `{trigger, payload_template, sample_context}` body，**仅做 dry-run 校验**：① 用 `json-logic-py` 评估 trigger 是否能解析（不要求命中）；② 用 Jinja2 SandboxedEnvironment 渲染 payload_template；返回 `{trigger_parses: bool, payload_renders: bool, render_output: str | null, errors: [{field, message}]}`。MUST NOT 写 DB / 队列。
2. `POST /callback-configs/{id}/rotate-secret` — 服务端生成新的 `signing_secret`（同 webhook-callback spec § signing_secret 加密路径），写入 callback_config 表，**一次性**返回明文给调用方（前端弹窗显示一次后丢弃）；后续 GET /callback-configs/{id} MUST 仅返回掩码 `****`。

这两个 endpoint 把"前端编辑回调配置时的安全 + 校验流程"从"前端可能裸存明文 secret + 配错语法"提升为硬契约，同时保持 webhook-callback spec § signing_secret 加密 + 不可读的安全约束不变。

#### Scenario: validate 请求 trigger 语法错

- **WHEN** 客户端 POST /callback-configs/validate 时 trigger JSON 不合法
- **THEN** API SHALL 返回 `{trigger_parses: false, payload_renders: <可选 bool>, errors: [{field: "trigger", message: "<json 错误>"}]}` 200 OK；MUST NOT 抛 5xx

#### Scenario: validate 请求 payload Jinja2 渲染错

- **WHEN** payload_template 引用未定义变量或语法错
- **THEN** API SHALL 返回 `{trigger_parses: <可选 bool>, payload_renders: false, errors: [{field: "payload_template", message: "<jinja2 错误>"}]}` 200 OK

#### Scenario: validate 不写副作用

- **WHEN** validate 调用成功 / 失败
- **THEN** API MUST NOT 写 callback_config 表 / MUST NOT 推 callback_log 队列 / MUST NOT 触发外部 HTTP

#### Scenario: rotate-secret 返回明文

- **WHEN** 客户端 POST /callback-configs/{id}/rotate-secret
- **THEN** API SHALL 生成新 secret（强随机 ≥ 32 字节）+ 加密写 callback_config 表 + **一次性**在 200 响应里返回明文 `{secret: "<plaintext>"}`；前端 MUST 提示用户复制保存

#### Scenario: 后续 GET 仅返回掩码

- **WHEN** 客户端 GET /callback-configs/{id} 或 GET /callback-configs
- **THEN** API MUST 把 `signing_secret` 字段替换为掩码 `"****"`（或返回 null）；MUST NOT 返回原文（即使刚刚 rotate 过）

#### Scenario: 缺权限或不存在

- **WHEN** rotate-secret 时 callback-config id 不存在
- **THEN** API SHALL 返回 404；MUST NOT 创建新记录

## Data Schema

| 字段 / 表 | 类型 / 用途 |
|---|---|
| `callback_config.trigger` | JSONB（JsonLogic 表达式） |
| `callback_config.url` | text |
| `callback_config.method` | enum (POST/PUT/PATCH...) |
| `callback_config.headers` | JSONB（额外请求头） |
| `callback_config.payload_template` | text（Jinja2 模板） |
| `callback_config.retry_policy` | JSONB `{intervals_seconds, max_attempts}` |
| `callback_config.signing_secret` | text（加密存储） |
| `callback_config.timeout_seconds` | int (nullable, 覆盖全局) |
| `callback_config.enabled` | bool |
| `callback_log.status` | enum: pending / success / failed_render / failed_http_4xx / failed_http_5xx / pending_retry / exhausted |
| `callback_log.request_body` | text |
| `callback_log.response_code` | int |
| `callback_log.response_body` | text |
| `callback_log.retry_count` | int |
| `callback_log.attempt_at` | timestamp |
| `callback_log.next_retry_at` | timestamp (nullable) |
| `callback_log.error_message` | text (nullable) |
