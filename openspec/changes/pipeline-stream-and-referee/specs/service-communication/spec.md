## MODIFIED Requirements

### Requirement: 通信通道矩阵

各服务 SHALL 按以下表使用对应通道；MUST NOT 引入未列出的通道（除非经 change proposal）。本 change 新增 `engine → worker (isales:extract)` 一条 Redis Queue 条目。

| 从 | 到 | 通道 | 用途 |
|---|---|---|---|
| scheduler | engine | Redis Queue | "拨打这条线索"（消息体含 lead 信息 + 历史摘要 + prompt_versions 快照） |
| engine | worker | Redis Queue (`isales:call_ended`) | "通话已结束，请处理"（摘要 + webhook 触发） |
| **engine** | **worker** | **Redis Queue (`isales:extract`)** | **"请抽取这通的客户信息"（post-call extractor 任务，详见 `ai-pipeline` spec § "post-call extractor 异步抽取"）** |
| api | engine | Redis Pub/Sub | 实时控制（手动挂断、转人工指令） |
| engine | api | Redis Pub/Sub | 通话事件推送（状态变更、ASR 文本） |
| api | scheduler | Redis Queue | 启动 / 暂停 Campaign |
| scheduler | telephony-api | HTTP | 拨号前选 device（含 caller_id） |
| engine | modem-controller | 本地 Unix socket / WebSocket | 拨号、挂断、PCM 音频流双向 |
| modem-controller | telephony DB | 直连 | 设备状态 / SIM 状态实时回写 |
| modem-controller | USB GSM modem | AT 命令（`/dev/ttyUSB*`）+ 音频（ALSA） | 物理设备控制 |
| worker | 外部 | HTTP | Webhook 回调外部业务系统 |
| 全部 | PostgreSQL | 直连（通过 isales-common 模型） | 数据持久化 |
| 全部 | Redis | 直连 | 队列、缓存、计数器 |

#### Scenario: 通道选型一致性

- **WHEN** 引入新的服务间调用
- **THEN** 调用 SHALL 复用上表中已有的通道与协议风格；如需新增通道（如 gRPC），MUST 经 change proposal 明确论证

#### Scenario: isales:extract 队列消息 schema

- **WHEN** engine LPUSH 一条到 `isales:extract`
- **THEN** payload SHALL 是 JSON 字符串，schema：
  ```json
  {
    "call_record_id": <BigInt>,
    "transcript_snapshot": [
      {"role": "assistant" | "user", "text": "...", "ts_ms": <int>}
    ],
    "extractor_role_config_id": <BigInt>,
    "extractor_prompt_version_id": <BigInt>
  }
  ```
- **AND** engine MUST 在 LPUSH 同时 UPDATE `call_record.extract_status='pending'`；worker BLPOP 处理完成后 UPDATE 为 `'done'` 或 `'failed'`

#### Scenario: isales:extract 队列消息容错

- **WHEN** worker BLPOP 后处理失败（LLM 超时 / JSON 校验失败 / DB 写失败）
- **THEN** worker MUST NOT 重 LPUSH（防雪崩）；MUST UPDATE `call_record.extract_status='failed'` + `extract_error=<reason>`；ops 通过 SQL 查询 `WHERE extract_status='failed'` 手工触发重跑
