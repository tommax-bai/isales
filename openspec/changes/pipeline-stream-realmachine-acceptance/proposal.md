## Why

`pipeline-stream-and-referee`（main 流式 + referee 旁路 + post-call extractor 双 LLM 架构）的**代码实装、全仓 pytest、mac dev 机制验证（call_record 137：首音频 678-1106ms / referee 决策驱动状态机 / extractor 离线写库 / fallback=false）、ECS 部署（alembic head `c3d4e5f6a7b8`，4 服务 restart 无异常）已全部完成并 archive**。但「真人 + 真机端到端验收」因物理 Windows 盒子 / 真人交互 blocker 未做（详见 `[[project_session_2026_06_04_handoff]]`：barge-in 真机验证长期卡在 mac edge 起不来 / 用户声音太轻 / Windows 盒子未 ready）。本 change 把这批验收从 `pipeline-stream-and-referee` 拆出独立追踪，待物理条件 ready 时执行，避免阻塞依赖它的 `engine-multi-referee-and-restructure` 开工。

## What Changes

- **无代码 / 无 spec 改动**：本 change 是**纯验收**，验收对象是已 archive 的 `pipeline-stream-and-referee` 行为。
- 执行 mac dev 真 mic 真人对话质量验收（话术 + barge-in 听感）。
- 执行 Windows 真拨号 ≥ 10 通联合验收，覆盖 goal_achieved / customer_decline / transfer / continue 四条状态机路径。
- 验证首音频 ≤ 1.5s、referee 驱动 WRAPPING_UP/TRANSFERRING、extractor 异步写库、5/28 barge-in 在新 streaming 链路不回归、main streaming 网络抖动下 fallback 行为。
- **若验收发现 bug**：另起修复 change（不在本 change 内改代码），本 change 仅记录验收结论。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

无。本 change 不改任何 spec 行为，仅对已实装并合并的 `ai-pipeline` / `goal-achievement` / `transcript` 行为做真机验收。

## Impact

- **无代码改动**。受影响的是验收流程与运维记录。
- 依赖物理资源：Windows 客户端盒子（SIM7600G-H 调制解调器 + 测试 SIM）、测试手机号 `13301035545`、mac dev rig 真 mic + 耳机。
- 验收通过后：在 `deploy/cloud/STATE.md` / 相关 STATE.md 记录「真机验收 verified」。
- 验收若发现回归：触发独立修复 change。
