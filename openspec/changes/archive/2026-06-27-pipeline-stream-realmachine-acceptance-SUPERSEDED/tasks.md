# Tasks — pipeline-stream-realmachine-acceptance

> 自 `pipeline-stream-and-referee` §13.2 + §15 拆出。纯验收，无代码改动；发现 bug 另起修复 change。
> 阻塞条件：物理 Windows 盒子 ready + 真人在 mac 听说。

## 1. mac dev 真人对话验收

- [ ] 1.1 mac dev 真 mic 跑 5 通真对话，戴耳机听质量（话术自然度 + 首音频听感 + barge-in 手感）<!-- 自 pipeline-stream-and-referee 13.2 -->

## 2. Windows 真拨号联合验收

- [ ] 2.1 Windows 真拨号 13301035545 e2e ≥ 10 通：覆盖 goal_achieved（成功约见）/ customer_decline（客户拒绝）/ transfer（要求人工）/ continue（普通多轮聊）四路径 <!-- 自 15.1 -->
- [ ] 2.2 验证首音频 ≤ 1.5s（戴耳机听感 + journalctl grep first_audio_ms）<!-- 自 15.2 -->
- [ ] 2.3 验证 referee 决策驱动 WRAPPING_UP / TRANSFERRING 状态机转移正确 <!-- 自 15.3 -->
- [ ] 2.4 验证 post-call extractor 异步写入 call_record.extracted（SQL 查 + worker 日志）<!-- 自 15.4 -->
- [ ] 2.5 验证 5/28 barge-in 在新 streaming 链路下不回归 <!-- 自 15.5 -->
- [ ] 2.6 验证 main streaming 网络抖动场景：mac 网络模拟 200ms 延迟 + 5% 丢包，看 fallback chat() 是否触发 + 通话能完成 <!-- 自 15.6 -->

## 3. 合并自 2026-06-15 已归档 change 的真机验收

> 2026-06-15:把多个「代码已部署、仅剩真机/点测验收」change 的验收项收口到本 change（用户指示「打电话验收合并到一个」）。这些 change 的代码与 spec 已 archive；以下仅为待执行的真机验收，发现回归→另起修复 change。

- [ ] 3.1 [engine-main-native-multiturn 5.2] 真人 mic：同 campaign 同话术，main 对话衔接自然度改前/改后对比，记录主观结论。
- [ ] 3.2 [engine-auto-restructure-on-interrupt 5.6] 垫词("嗯"/"你继续")打断 → AI 自动续说被切的话；真异议("我没空"/"多少钱")打断 → AI 正常回应（验 veto）。
- [ ] 3.3 [fix-goal-achievement-pipeline 6.2b] 拨「成功」电话：transcript 出 `ai_reply{goal_achieved:true, goal_type:intent_confirmed}` + 独立 `goal_achieved` 事件。
- [ ] 3.4 [web-admin-scene-single-page-config 7.4] 浏览器点测：进度/启停/监控不回归；基本信息+TTS 试听；9 小节编辑+统一保存；422 标红；AI 角色/垫词即时存（保存不清空角色）。
- [ ] 3.5 [engine-turn-latency-and-tts-guard §6] 新通话 pipeline_trace 见 `main_first_token_ms`/`main_first_sentence_ms` 落值、restructure 轮有独立行、无 `No readable text` TTS error；smoke `phase_dialog_timeline` 打印逐节点耗时。
- [ ] 3.6 [engine-llm-disable-thinking 4.2] volcengine 路径关思考真机生效（待火山账号有可用豆包模型）。

## 4. 验收收口

- [ ] 4.1 验收结论写入 STATE.md（mac / cloud / Windows edge 相应节标「真机验收 verified」+ 日期 + call_record 抽样）
- [ ] 4.2 若任一项发现回归 → 另起修复 change，并在此记录指针；全绿 → archive 本 change
