## MODIFIED Requirements

### Requirement: engine ↔ modem-controller IPC 协议

通信通道 SHALL 为本地 Unix socket（单主机部署）+ JSON 消息。指令与事件方向严格区分。`session_id` SHALL 是 caller（engine）提供的相关 ID；事件帧 MUST 仅暴露 `session_id` 字段，不暴露 modem-controller 内部生成的 UUID。

#### Scenario: engine → modem-controller 指令格式

- **WHEN** engine 发起拨号 / 挂断 / 推送下行音频
- **THEN** 消息格式 MUST 形如：
  ```json
  {"cmd": "dial",   "device_id": 3, "number": "13800138000", "session_id": "abc"}
  {"cmd": "hangup", "session_id": "abc"}
  {"cmd": "audio_downstream", "session_id": "abc", "pcm_chunk": "<base64>"}
  ```

#### Scenario: modem-controller → engine 事件格式

- **WHEN** modem-controller 上报通话进展 / 音频 / 错误
- **THEN** 消息格式 MUST 形如：
  ```json
  {"event": "call_progress", "session_id": "abc", "state": "ringing"}
  {"event": "connected",     "session_id": "abc"}
  {"event": "audio_upstream","session_id": "abc", "pcm_chunk": "<base64>"}
  {"event": "remote_hangup", "session_id": "abc", "cause": "no_answer"}
  {"event": "device_error",  "session_id": "abc", "code": "signal_lost"}
  ```

#### Scenario: 音频流 v1 走同一 IPC

- **WHEN** v1 实施
- **THEN** 音频流 SHALL 与控制消息走同一 Unix socket（v1 简化）；后期可改为独立流通道（pcm_upstream / pcm_downstream）减少 JSON 编解码开销

#### Scenario: session_id 缺省时的回退

- **WHEN** 调用方（如手工调试 / 旧客户端）省略 `session_id` 字段
- **THEN** modem-controller MAY 用内部生成的 UUID 作为 session_id 回填到 ack 与所有后续事件帧；MUST NOT 把这个 UUID 以 `call_id` 字段单独暴露（事件帧只允许 `session_id` 一个对应字段）；engine 路径正常使用时 MUST 自带 session_id

#### Scenario: 事件帧字段最小化

- **WHEN** modem-controller 发送任何 event 帧
- **THEN** 帧 MUST 仅包含 `event` + `session_id` + 该事件类型语义所需字段（如 `cause` / `code` / `pcm_chunk` / `state`）；MUST NOT 同时回 `call_id` 等内部值（删除 stage-2 留下的 backward-compat 字段）
