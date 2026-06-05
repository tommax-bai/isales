## ADDED Requirements

### Requirement: 开场白文案试听

管理端场景编辑的「基础」配置 SHALL 允许运营在保存前对"当前开场白文案 + 当前音色"现合成语音并在浏览器试听，无需真实拨号。试听 MUST 使用表单当前（可能未保存）的 `greeting` 与 `voice_id`，且 MUST NOT 写入或依赖已持久化的 campaign 记录。

#### Scenario: 文案与音色齐备时可试听

- **WHEN** 运营在场景编辑「基础」tab 填写了非空"开场白文案"并选定了"音色"，点击"试听"
- **THEN** 系统 SHALL 调用后端合成端点，取回浏览器可直接播放的音频并播放该句开场白；播放期间按钮 MUST 呈现 loading 态

#### Scenario: 文案或音色缺失时禁用试听

- **WHEN** "开场白文案"为空或未选"音色"
- **THEN** "试听"按钮 MUST 处于 disabled 状态，不发起合成请求

#### Scenario: 合成失败给出可读反馈

- **WHEN** 后端合成端点返回错误（凭据缺失 / vendor 失败 / 超长）
- **THEN** 前端 MUST 展示可读错误提示且不崩溃，按钮 MUST 退出 loading 态可重试

### Requirement: 开场白试听合成端点

isales-api SHALL 提供一个无状态的开场白试听合成端点：入参为文案与音色，输出浏览器可直接播放的音频；端点 MUST 经现有管理端鉴权，MUST NOT 读写 campaign 持久化数据。

#### Scenario: 合成并返回可播放音频

- **WHEN** 已认证管理端用户以 `{text, voice_id}` 请求试听端点，且 `text` 非空且不超过长度上限
- **THEN** 端点 SHALL 用现有 `provider_credential` 凭据合成 TTS，并以浏览器可直接播放的音频内容类型返回

#### Scenario: 拒绝超长或缺参请求

- **WHEN** `text` 为空、超过长度上限，或 `voice_id` 缺失
- **THEN** 端点 MUST 返回校验错误（4xx），MUST NOT 调用 TTS 供应商

#### Scenario: 未认证拒绝

- **WHEN** 请求未携带有效管理端身份
- **THEN** 端点 MUST 拒绝（401/403），MUST NOT 消耗供应商配额
