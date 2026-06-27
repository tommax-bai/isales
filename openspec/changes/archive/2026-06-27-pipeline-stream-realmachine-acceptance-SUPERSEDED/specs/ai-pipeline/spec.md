<!-- 纯验收 change：把「双 LLM 架构上线前真机验收」固化为一条发布门禁需求。
     archive 本 change 时该需求并入 ai-pipeline spec，成为永久 pre-launch hard-gate。 -->

## ADDED Requirements

### Requirement: 双 LLM 架构真机验收门禁

main 流式 + referee 旁路 + post-call extractor 双 LLM 架构在面向真实外呼上线前 SHALL 通过真机端到端验收门禁。验收 MUST 在真实电话链路（Windows 客户端 + USB GSM 调制解调器 + 真 SIM + 真拨号）上执行，覆盖状态机全部出口路径，并 MUST 把验收结论记录到对应 STATE.md。任一路径回归 MUST 阻断上线并触发修复 change。

#### Scenario: 四条状态机路径全覆盖

- **WHEN** 执行真机拨号验收
- **THEN** 验收 SHALL 至少完成 10 通真拨号，覆盖 `goal_achieved`（成功约见）/ `customer_decline`（客户拒绝）/ `transfer`（要求人工）/ `continue`（普通多轮聊）四条路径
- **AND** referee 决策驱动的 `WRAPPING_UP` / `TRANSFERRING` 状态转移 MUST 与预期一致

#### Scenario: 首音频延迟达标

- **WHEN** 真机通话中用户说完一句
- **THEN** 首音频延迟 SHALL ≤ 1.5s（戴耳机听感 + 日志 `first_audio_ms` 双证）

#### Scenario: barge-in 与抖动不回归

- **WHEN** 在真机链路上触发 barge-in 打断 + 模拟网络抖动（200ms 延迟 + 5% 丢包）
- **THEN** barge-in MUST 不回归（用户打断能及时中止播放），main streaming 网络异常时 `chat()` fallback MUST 正确触发且通话能完成

#### Scenario: extractor 异步写库

- **WHEN** 真机通话结束
- **THEN** post-call extractor MUST 异步写入 `call_record.extracted`（SQL 查询 + worker 日志双证）

#### Scenario: 验收结论留痕

- **WHEN** 真机验收完成
- **THEN** 结论 MUST 写入对应 STATE.md（mac / cloud / Windows edge），含日期与 call_record 抽样；未通过 MUST 阻断上线
