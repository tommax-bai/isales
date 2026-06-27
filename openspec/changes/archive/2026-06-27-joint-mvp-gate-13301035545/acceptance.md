# Acceptance: joint-mvp-gate-13301035545

> 硬门：真拨自己手机 `13301035545`、听到 AI 开场白并完成双向对话。**PASS 2026-06-06**。

## MVP gate 通过证据

- **真机拨通**：2026-06-06，Windows edge（SIM7600G-H）全栈真拨 `+8613301035545`（telephony origin/main `176faee` "🎉 全栈真拨 13301035545 PASS — 电话→AI 打通"）。
- **call_record #157**：~114s 完整**双向** AI 对话（不止开场白，含多轮 user↔AI）。`transcript[0]` 为 AI 开场白文本。
- **"听到 AI 开场白？" = yes**：接听端（dev 本人手机）确认听到 AI 语音开场白并能对话。两份 STATE.md 均记录该 gate 证据（`deploy/cloud/STATE.md` + `isales-telephony/deploy/edge/windows/STATE.md`，§13301035545 joint MVP gate）。
- **链路全 GREEN**：Windows DingRTC binding（§7，telephony origin/main `4748c0c/30a96de/ada5df5/0e6e015/c669afe/5e1ab5f`）+ cloud-edge gRPC + scheduler→engine→edge→modem→RTC→TTS→PCM→接听端 端到端跑通。`mint_rtc_token` CLI 已 ship（engine `a200e26`）。
- **真凶修复**："电话→AI" 之前不通的真因 = 引擎 48k stereo→mono 未下混（engine `e7b1c66`），已修并部署。

## 归档说明

- 本 change 与 `engine-rtc-dingrtc-migration` 同期归档（共享 device-hardware / deployment-topology spec；deltas 已对齐 DingRTC 实况，ARTC 字样已清）。
- checkbox 15/47 严重低估：硬门已过、Windows §7 早 GREEN；未勾项多为 ARTC pybind 路线（已随 ARTC→DingRTC 作废）与历史脚手架。

## 不阻塞本 gate 的残留（已分流到其它 change）

- **bug2 远端挂断不 finalize**（call_record 卡 init / pipeline_trace 空）：真因为引擎 GIL 死锁，已由 binding 0.1.1 修（engine `753ff13`，`deploy/cloud/STATE.md:1135`）；device 复位由现有心跳路径承担——见已撤回的 `device-status-reset-on-call-end`（SUPERSEDED）。
- **modem 采集坏态需 USB 物理重插**：归 `edge-modem-audio-out-recovery`（blocked on 硬件 rig）。
- **裁判挂断 / 转人工 routing_rules 配回**：归后续 campaign 配置 / 引擎 change。
