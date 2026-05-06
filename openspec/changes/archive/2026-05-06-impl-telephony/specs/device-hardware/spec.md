## ADDED Requirements

### Requirement: IPC 帧格式

`engine` ↔ `modem-controller` 的 Unix socket 通信 SHALL 使用 newline-delimited JSON 帧格式：每条消息以 `\n` 结尾，单条消息内 MUST NOT 出现裸换行；接收方按行读取并 `json.loads()` 解析。本 Requirement 是 device-hardware § engine ↔ modem-controller IPC 协议 的具体化。

#### Scenario: 消息分帧

- **WHEN** 任一端发送一条 IPC 消息
- **THEN** SHALL 在 JSON 序列化结果末尾追加单个 `\n`；JSON 中嵌入的字符串字段若含换行 MUST 按 JSON 标准转义为 `\\n`（不影响分帧）

#### Scenario: 不完整帧的处理

- **WHEN** 接收方读到 EOF 但当前缓冲区有未结束的数据（无 `\n`）
- **THEN** SHALL 视为协议错误，关闭连接并日志告警；MUST NOT 尝试 partial parse

#### Scenario: 单条消息大小上限

- **WHEN** 任一端构造或接收单条消息
- **THEN** SHALL 限制单条 ≤ 1 MiB（覆盖最大 PCM chunk + 控制元数据）；超限发送方 SHALL 拒绝发送、接收方 SHALL 关闭连接并告警

#### Scenario: 双向独立流

- **WHEN** engine 与 modem-controller 同时读写
- **THEN** 双向独立异步 Stream（asyncio StreamReader/Writer），消息不互相阻塞；SHALL NOT 假设请求/响应严格配对（控制指令与音频流交错走同一 socket）
