## Why

2026-05-31 真拨 13301035545 实测确认:SIM7600G-H 的 USB 音频上行(host→modem→对端 GSM)在 Windows 下**可用**——干净重启后,通话中 `AT+CPCMREG=1`、往 audio COM 口写 8kHz/16bit/mono/320B-20ms paced PCM,对端真人听到 tone。但实测同时暴露一个生产级隐患:modem 的**音频 OUT 端点会进入"卡死态"**——`write()` 持续 `SerialTimeoutException`(或阻塞写永久挂死),且该状态**跨通话、跨 `AT+CPCMREG=0/1` 都清不掉,只有整机重启复位**。当前 `windows_serial_pcm.py::write_chunk()` **静默吞掉 `SerialTimeoutException`**(只 log warning),于是卡死态下边缘"看似在跑、实则一个字节没送达对端",且现场只能靠人物理重插 USB 恢复——对 24/7 无人值守的客户 Windows 边缘不可接受。

## What Changes

- `windows_serial_pcm.py::WindowsSerialPcmPlayback.write_chunk()` 不再静默吞 `SerialTimeoutException`:连续写超时达阈值(短窗口内 N 帧全超时)SHALL 判定为"音频 OUT 卡死",上报 `HardwareAlert` 并触发 modem 软复位流程,而非假装无事。**BREAKING**(行为):此前 write timeout 被静默忽略,现在会升级为告警 + 复位。
- 新增 modem **软复位**链路(`AtClient` 层 `reset_modem()`,封装 `AT+CRESET` 或 `AT+CFUN=1,1`),供 orchestrator 在检测到 OUT 卡死时调用;复位后重新 USB 枚举 + 重建 audio backend。**软复位能否真正清除 OUT 卡死态(替代物理重插)是本 change impl 阶段必须实测验证的核心假设**;若软复位无效,fallback 为上报需人工干预的 `HardwareAlert` 并明确告警文案(不堆叠无效 fallback,符合 root CLAUDE.md "多层 fallback 是坏味道")。
- 边缘 daemon 会话初始化 SHALL 从**干净 modem 状态**起步(orchestrator 启动时一次软复位 / 或确保上一会话已 `CPCMREG=0` 清理),降低进入卡死态概率。
- 记录已验证事实:USB 音频上行在 Windows 可用(非 USB Audio Class、走 SerialPcm-over-COM),并明确诱发卡死的禁忌操作(写错采样格式如 `CPCMFRM=1`/16K、阻塞 `write_timeout=None`、`AT+CFTRANRX` 大文件)。

## Capabilities

### New Capabilities
<!-- 无新增能力;改动落在既有 device-hardware 能力域内 -->

### Modified Capabilities
- `device-hardware`: 在 "Windows 平台 backend" Requirement 下,新增/修订 SerialPcm playback 的**写超时语义**(从"静默忽略"改为"卡死检测 → 告警 + modem 软复位")与**会话初始化干净状态**约束;补记 USB 音频上行已实测可用及禁忌操作。

## Impact

- 代码:`isales-telephony/isales_telephony/modem_controller/audio/windows_serial_pcm.py`(write 超时语义)、`.../modem_controller/at_client.py`(新增 `reset_modem()` helper + 既有 `cpcmreg_*`)、orchestrator(`_CallContext` / daemon 启动路径,卡死检测 → 复位编排)。
- 文档:`isales-telephony/deploy/edge/windows/STATE.md` § "SIM7600 USB audio uplink — 实测可用"(已先行更新,本 change 的事实来源)。
- 规格:`openspec/specs/device-hardware/spec.md`(经 archive 同步)。
- 行为兼容:卡死检测阈值需保守(避免把正常的偶发短写超时误判为卡死触发不必要复位);复位会中断当前通话,SHALL 仅在确认持续卡死时触发。
- 测试:`retest_audio_write.py` 已证可用路径;需补软复位能否清卡死态的实测(impl 阶段,需真硬件 + 可控诱发卡死手段)。
