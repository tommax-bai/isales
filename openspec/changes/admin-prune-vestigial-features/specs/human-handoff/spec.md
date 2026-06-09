## MODIFIED Requirements

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

## REMOVED Requirements

### Requirement: 坐席工作流

**Reason**: 坐席任务队列依赖 `handoff_task` 表，而该表从未被任何运行时路径写入（worker 只标 `lead.status=transferred`，从不 insert handoff_task）。表 + GET-only api router + 死 web 页随 drop 迁移 `c4d5e6f7a8b9` 一并删除；`human-handoff` 的 Data Schema 表同步删去 `handoff_task` 行（保留 `agent` 行、`campaign.transfer_*`、`call_record.transfer_status/reason`）。转人工**检测**（4 种触发 + TRANSFERRING 话术挂断）完整保留。
