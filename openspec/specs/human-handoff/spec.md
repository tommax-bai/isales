## Purpose

定义"转人工"在 v1 的衰减实现：标记 + 通知，不做实时话路桥接。本规范覆盖 4 种触发机制、流程、坐席工作流与数据模型。实时 SIP 桥接 / GSM 呼叫转接（AT+CHLD）/ 自研 SIP 软话机三种实时桥接方案 MUST 列入 v2 计划，v1 范围之外。
## Requirements
### Requirement: v1 衰减为标记 + 通知

v1 选择自研 USB GSM modem 方案，**MUST NOT 引入 SIP/PBX 设施**，因此 MUST NOT 做实时话路桥接。转人工 SHALL 衰减为以下流程：AI 识别需要人工介入 → 礼貌告知用户「稍后专员会主动联系您」 → AI 主动结束通话 → 系统派发待回拨任务 → 坐席手动外呼。

#### Scenario: AI 不做实时桥接

- **WHEN** 任一转人工触发条件命中
- **THEN** engine MUST NOT 调用任何 SIP 桥接或 GSM 呼叫转接 API；MUST 走"标记 + 主动挂断"路径

#### Scenario: 坐席通过其他系统回拨

- **WHEN** 坐席从 isales-web 看到 handoff_task 后决定回拨
- **THEN** 坐席 SHALL 通过其他业务电话系统手动外呼，本系统 v1 不提供回拨能力

### Requirement: 4 种独立触发机制

转人工 SHALL 支持 4 种触发：关键词 / 意图分类 / 轮次阈值 / 独立 LLM 判定。每种 MUST 可独立启用与配置；多种同时启用时 MUST 为 OR 关系（任一命中即触发）。

#### Scenario: 关键词触发

- **WHEN** ASR 终态结果包含 `campaign.transfer_keywords` 中任一关键词且 `transfer_keyword_enabled=true`
- **THEN** engine 进入 TRANSFERRING

#### Scenario: 意图分类触发

- **WHEN** 独立的轻量意图分类器输出"转人工意图"概率超过 `campaign.transfer_intent_threshold` 且 `transfer_intent_enabled=true`
- **THEN** engine 进入 TRANSFERRING

#### Scenario: 轮次阈值触发

- **WHEN** 对话轮次超过 `campaign.transfer_round_threshold` 且未达成目标且 `transfer_round_enabled=true`
- **THEN** engine 进入 TRANSFERRING

#### Scenario: 独立 LLM 触发

- **WHEN** 独立判定 LLM（按 `transfer_llm_prompt_version_id` 配置）输出 `{"transfer": true}` 且 `transfer_llm_enabled=true`
- **THEN** engine 进入 TRANSFERRING

### Requirement: TRANSFERRING 流程

进入 TRANSFERRING 后 engine SHALL 顺序执行：播衔接话术 → 等 TTS 播完 → 主动挂断 → 由 worker 把 `lead.status` 标记为 `transferred`（并在命中 callback_config 时发 webhook）。worker MUST NOT 创建 `handoff_task` 记录——该表已删除；转人工的下游只剩「标记 lead 状态 + 可选 webhook」，没有任务队列。

#### Scenario: 衔接话术播放

- **WHEN** state_machine 进入 TRANSFERRING
- **THEN** engine SHALL 从 `campaign.transfer_phrases` 随机抽 1 条 TTS 播放

#### Scenario: 主动挂断与状态写入

- **WHEN** 衔接话术 TTS 播放完成
- **THEN** engine 主动挂断；call_record 字段 MUST 写入：`transfer_status="marked_for_handoff"`、`transfer_reason="<触发类型>"`，并进入 END

#### Scenario: worker 标记 lead 并可选发 webhook

- **WHEN** worker 收到通话结束消息且 transfer_status="marked_for_handoff"
- **THEN** worker SHALL 把关联 `lead.status` 标记为 `transferred`；如配置了 callback_config 且 trigger 命中，MUST 同时触发 webhook；MUST NOT 创建 handoff_task 记录（该表已删除）

#### Scenario: 没有"无坐席兜底"分支

- **WHEN** v1 任一转人工触发命中
- **THEN** 流程 MUST 直接走"标记 + 挂断"，没有"立刻找空闲坐席"或"无空闲坐席兜底话术"分支（这两个分支属于 v2 实时桥接模式）

### Requirement: 与状态机的交互

TRANSFERRING 状态下 engine MUST NOT 调用 AI 管线；衔接话术播完后 SHALL 直接进入 END，**MUST NOT 存在转接成功/失败二级分支**（v1 不实时桥接）。

#### Scenario: TRANSFERRING 期间 ASR 持续

- **WHEN** TRANSFERRING 期间衔接话术 TTS 仍在播放
- **THEN** ASR MAY 继续流式工作，用于补录最后一条 transcript

#### Scenario: 不存在转接成功 / 失败分支

- **WHEN** v1 衔接话术 TTS 播完
- **THEN** engine MUST 直接进入 END (reason=`marked_for_handoff`)；MUST NOT 尝试连接坐席或返回失败兜底

### Requirement: 衔接话术配置

`campaign.transfer_phrases` MUST 至少配置 1 条非空字符串；engine SHALL 在每次进入 TRANSFERRING 时随机抽 1 条。

#### Scenario: 多条话术随机选择

- **WHEN** 进入 TRANSFERRING
- **THEN** engine SHALL 从 `campaign.transfer_phrases`（JSONB 数组）中随机选 1 条；该数组 MUST 至少配置 1 条非空字符串

## Data Schema

| 表 / 字段 | 用途 |
|---|---|
| `campaign.transfer_keyword_enabled` | 启用关键词触发 |
| `campaign.transfer_keywords` (JSONB) | 关键词列表 |
| `campaign.transfer_intent_enabled` | 启用意图分类触发 |
| `campaign.transfer_intent_threshold` | 意图概率阈值 |
| `campaign.transfer_round_enabled` | 启用轮次触发 |
| `campaign.transfer_round_threshold` | 轮次阈值 |
| `campaign.transfer_llm_enabled` | 启用独立 LLM 触发 |
| `campaign.transfer_llm_prompt_version_id` | 独立 LLM 的 prompt 版本引用 |
| `campaign.transfer_phrases` (JSONB) | 衔接话术池，随机选 1 |
| `call_record.transfer_status` | `marked_for_handoff` / null |
| `call_record.transfer_reason` | 命中的触发类型 |
| `agent` 表 | name, login_user, status (online/offline)。v1 不需要 sip_number |
| `handoff_task` 表 | call_record_id, agent_id (nullable), trigger_type, trigger_detail, status, created_at, picked_up_at, completed_at |
