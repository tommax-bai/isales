# Tasks

## 1. 实装（已完成，QA 实证）

- [x] `asr_volcengine._push_audio` 攒包到 ~100ms 再 ws.send（替代 1:1 转发 10ms 帧）<!-- engine e0bb356 -->
- [x] `rtc_telephony._inbound_loop` 噪声门（env 可调，默认 RMS<1500 + 300ms hangover → 喂数字静音），仅 ASR 路，VAD 路保持原始 <!-- engine e0bb356 -->
- [x] noise-gate 状态转换日志 `asr_noise_gate sid=.. state=ENGAGED/RELEASED ..`（便于真机量化）<!-- engine e0bb356 -->

## 2. 部署（已完成）

- [x] scp `asr_volcengine.py` + `rtc_telephony.py` → ECS `/opt/isales/current/isales-engine/` <!-- 2026-06-05, md5 mac==ECS: rtc 2ff6f91 / asr 2c032ae -->
- [x] `systemctl restart isales-engine` + 启动无 traceback 确认 <!-- isales_engine_started -->

## 3. 真机验收（已完成，mac dev-no-modem）

- [x] call 152：ASR finalize 0.2–0.46s（vs call 150 无改 5–11s / call 151 仅门 1.2–4.3s）<!-- ENGAGED→FINAL 每轮 <0.5s -->
- [x] call 152：一通内 `volcengine_asr_reconnect` = 0（vs 150/151 各 1 次）
- [x] call 152：8 轮自然销售对话走到"好,再见"，未中途 silence_max 崩
- [x] `call_timeline.py --call-id 152` 零空档告警 <!-- isales-telephony f93ac02 -->

## 4. 诊断工具（已完成）

- [x] `isales-telephony/scripts/call_timeline.py`：合并 edge + engine 双端日志成一条 wall-clock 时间线，折叠噪声流、派生每轮 engine内部-vs-mac扬声器延迟、自动标 ASR finalize-tail 空档 <!-- telephony f93ac02 -->

## 5. Followup（未做，需独立推进）

- [ ] 噪声门 env → `campaign` 配置固化（`campaign.asr_noise_gate_rms` / `asr_noise_gate_hangover_ms`）：isales-common schema + Pydantic + alembic + engine 读取 + api/web 暴露（4 仓）
- [ ] 隔离测试：单靠 100ms 攒包、去掉噪声门是否就够（call 152 两刀同上，未单独验证；生产 GSM 线路底噪特征不同，可能不需门）
- [ ] 评估改用 vendor `bigmodel_async` endpoint（首尾字时延更优）是否进一步降低 finalize；权衡结果解析路径改动
- [ ] keepalive：攒包后重连已消失，暂不加 application-level ping；若生产复现 1011 再评估
- [ ] DIAG 清理：`asr_noise_gate` 转换日志在验收稳定后降级为 DEBUG 或移除（与 `[[joint-mvp-gate-13301035545]]` 真拨验收一并处理）

## 6. 收尾

- [ ] `openspec validate asr-vendor-packet-cadence --strict`
- [ ] 跨平台确认：Windows 真拨（同 engine 代码，无平台差异）验证 finalize 同样落到亚秒级后，archive 本 change
