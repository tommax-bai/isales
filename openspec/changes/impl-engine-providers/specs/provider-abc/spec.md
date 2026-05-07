## MODIFIED Requirements

### Requirement: 统一错误模型

三类 Provider 的实现 SHALL 把供应商原生异常包装为 `ProviderError` 体系（基类 + 子类：`ProviderTimeout` / `ProviderRateLimited` / `ProviderInvalidRequest` / `ProviderServerError`）；MUST NOT 让供应商 SDK 原生异常直接抛到业务层。

每种异常子类的触发条件 SHALL 严格按以下硬契约（本 Requirement 把"哪种 HTTP / 协议响应触发哪类异常"从隐式约定提升为硬契约）：

| 触发条件 | 抛出 |
|---|---|
| HTTP 429 / 协议层限流 | `ProviderRateLimited` |
| HTTP 5xx / 连接错误 / DNS 失败 / SSL 错误 / WebSocket 1006 / WebSocket 服务端关闭 | `ProviderServerError` |
| 请求超时（asyncio.timeout / read timeout / 连接 timeout） | `ProviderTimeout` |
| HTTP 400 / 401 / 403 / 422 / 其他 4xx（非 429） | `ProviderInvalidRequest` |
| 响应非 JSON / JSON 缺必填字段 / 格式不符合 Provider 契约 | `ProviderInvalidRequest` |

orchestrator / 实时模块 / 重试调度依赖这套异常分类做降级决策（当前 v1：候选淘汰 / 默认回复兜底；v2 候选：`ProviderRateLimited` 切备 Provider）。

#### Scenario: 超时统一

- **WHEN** 任何 Provider 调用超时
- **THEN** 实现 MUST 抛 `ProviderTimeout`，业务层据此触发 `ai-pipeline` spec 的降级路径（润色失败兜底 / 默认回复）

#### Scenario: 限流统一

- **WHEN** 供应商返回 429
- **THEN** 实现 MUST 抛 `ProviderRateLimited`，业务层据此决策重试或切换 Provider

#### Scenario: 服务端错误统一

- **WHEN** 供应商返回 5xx，或 HTTP 连接 / WebSocket 出现网络层错误（含 1006）
- **THEN** 实现 MUST 抛 `ProviderServerError`；业务层 MAY 重试（webhook-callback / asr 重连等场景），但不能假设可恢复

#### Scenario: 非法请求统一

- **WHEN** 供应商返回 4xx（非 429），或响应体不符合契约（缺字段 / 类型错）
- **THEN** 实现 MUST 抛 `ProviderInvalidRequest`；业务层 MUST NOT 重试（请求本身有问题，重试无意义），SHALL 走兜底

#### Scenario: SDK 原生异常隔离

- **WHEN** 供应商 SDK / httpx / websockets 抛原生异常
- **THEN** 实现 MUST 在 `try/except` 中转换为 `ProviderError` 子类后再抛；MUST NOT 让原生异常逃出 Provider 实现层
