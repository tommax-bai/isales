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

## 3. 验收收口

- [ ] 3.1 验收结论写入 STATE.md（mac / cloud / Windows edge 相应节标「真机验收 verified」+ 日期 + call_record 抽样）
- [ ] 3.2 若任一项发现回归 → 另起修复 change，并在此记录指针；全绿 → archive 本 change
