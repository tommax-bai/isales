## ADDED Requirements

### Requirement: TTSProvider 连接复用

TTSProvider 实装 SHOULD 跨多次 `synthesize_stream` 调用复用底层 HTTP 连接（keep-alive 连接池），MUST NOT 每句新建并丢弃整个 client / 连接而无故付重复 TLS 握手。Provider MUST 提供释放底层连接的方式（如 `async def aclose()`），并在进程退出 / provider 弃用时调用。

复用 MUST 对正确性透明：连接半开 / vendor 空闲断连时，实装 SHALL 透明重连（或按现有 `ProviderError` 重试语义处理），调用方行为不变。

#### Scenario: 跨句复用连接

- **WHEN** 同一通话内连续多句调用 `synthesize_stream`
- **THEN** provider SHOULD 复用同一持久 client 的连接池；MUST NOT 每句重建 client 而付一次完整 TLS 握手

#### Scenario: 连接释放

- **WHEN** provider 弃用 / 进程退出
- **THEN** provider MUST 释放其持久连接（`aclose()` 或等价），MUST NOT 泄漏连接
