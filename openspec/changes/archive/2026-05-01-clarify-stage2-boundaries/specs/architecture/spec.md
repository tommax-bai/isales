## ADDED Requirements

### Requirement: 内部 HTTP 服务的统一 JWT 鉴权

`isales-api` 与 `telephony-api` SHALL 共享同一套 JWT 鉴权体系：isales-api 为唯一签发方，telephony-api 仅验证；HMAC 签名密钥经环境变量分发到两个服务；isales-web SHOULD 直连 telephony-api 而非经 isales-api 转发。

#### Scenario: isales-api 是唯一 JWT 签发方

- **WHEN** 前端用户登录
- **THEN** SHALL 由 isales-api 签发 JWT；MUST NOT 由 telephony-api 或任何其他服务签发；telephony-api 不暴露 `/login` 等签发端点

#### Scenario: telephony-api 仅验证 JWT

- **WHEN** telephony-api 收到来自前端的 HTTP 请求
- **THEN** SHALL 用与 isales-api 相同的密钥验证 JWT；MUST NOT 自行刷新或重签发；验证失败 SHALL 返回 401

#### Scenario: HMAC 密钥经环境变量分发

- **WHEN** 部署 isales-api 与 telephony-api
- **THEN** 共享 HMAC 密钥 SHALL 通过环境变量（命名约定 `ISALES_JWT_SECRET`）注入两个服务；MUST NOT 在 DB 或代码中写死；MUST NOT 经 isales-common 的 Python 模块导出（避免库变成密钥分发渠道）

#### Scenario: isales-web 直连 telephony-api

- **WHEN** isales-web 需要调用 device / sim_card / device_sim_binding 等 telephony 资源
- **THEN** SHOULD 直接 HTTP 请求 telephony-api，使用从 isales-api 拿到的 JWT；MUST NOT 强制经 isales-api 转发（避免引入无收益的 BFF 层）

#### Scenario: 服务间内部调用免 JWT

- **WHEN** scheduler 调用 telephony-api 的 `POST /devices/select`
- **THEN** v1 单主机部署下 MAY 免 JWT；网络层 SHALL 限制 telephony-api 仅监听 loopback 或内部网段；多主机扩展（v2）MUST 引入服务账号 JWT 或 mTLS

#### Scenario: JWT 配置不属于 isales-common 业务范围

- **WHEN** 在 isales-common 添加内容
- **THEN** isales-common MUST NOT 提供 JWT 签发函数；MAY 提供 JWT 验证的工具函数（如解码与签名校验），前提是不绑定特定密钥来源
