## ADDED Requirements

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
