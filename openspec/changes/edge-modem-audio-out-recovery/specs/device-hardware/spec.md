## ADDED Requirements

### Requirement: SIM7600 音频 OUT 卡死检测与 modem 软复位

边缘 Windows SerialPcm playback backend SHALL 把 audio COM 口的**持续写超时**判定为 modem 音频 OUT 端点卡死信号,并触发可观测的告警 + modem 软复位编排,而非静默忽略。背景事实:2026-05-31 真拨 13301035545 实测确认 SIM7600G-H 的 USB 音频上行在 Windows 下可用(对端听到 tone),但 modem 音频 OUT 会进入跨通话、跨 `AT+CPCMREG=0/1` 都清不掉、仅整机重启复位的卡死态;当前 `windows_serial_pcm.py::write_chunk()` 静默吞掉 `SerialTimeoutException`,导致卡死态下边缘"看似在跑、对端零音频"且现场只能人工物理重插。

#### Scenario: 持续写超时升级为卡死告警

- **WHEN** `WindowsSerialPcmPlayback.write_chunk()` 在一个短窗口内(默认连续 ~25–50 帧 @20ms,即 ~0.5–1s)**每一帧 write 都抛 `SerialTimeoutException`**
- **THEN** backend SHALL 判定音频 OUT 卡死,上报 `HardwareAlert{kind="audio_out_stuck"}`(或等价 kind),MUST NOT 继续静默吞掉超时假装正常
- **AND** 单次偶发写超时(未达连续阈值)SHALL 仍被容忍(瞬时背压),MUST NOT 单帧超时即触发复位

#### Scenario: 卡死触发 modem 软复位编排

- **WHEN** orchestrator 收到 `audio_out_stuck` 告警
- **THEN** SHALL 调用 `AtClient.reset_modem()`(默认 `AT+CRESET`;失败再 `AT+CFUN=1,1`)对 modem 软复位;复位后 SHALL 经既有 USB watcher(按 pyserial `description` 含 `Audio`/`AT` 子串匹配,不依赖 COM 号)重新识别并重建 capture/playback backend
- **AND** 软复位 SHALL 中断当前通话(可接受,优于永久静默卡死)
- **AND** 若软复位实测**无法**清除卡死态,则 backend SHALL 上报需人工干预的 `HardwareAlert` 并给出明确文案,MUST NOT 堆叠无效 fallback 假装已恢复

#### Scenario: 会话从干净 modem 状态起步

- **WHEN** 边缘 daemon 冷启动,或在发起新一通呼叫前
- **THEN** orchestrator SHALL 确保上一会话的 `AT+CPCMREG=0` 已执行(释放 PCM 字节流);daemon 冷启动 MAY 执行一次软复位以清除继承的残留 OUT 状态

#### Scenario: 禁忌操作避免(防止诱发卡死)

- **WHEN** 生产音频写路径运行
- **THEN** SHALL NOT 向 audio COM 口写非 8kHz/16bit/mono 格式 PCM;SHALL NOT 使用阻塞 `write_timeout=None`(MUST 保持有限 write_timeout);`AT+CFTRANRX` 大文件上传 MUST NOT 出现在生产音频路径(实测会把整机 modem AT 口搞挂,仅诊断脚本使用且需备物理重插预案)
