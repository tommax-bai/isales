## Context

边缘 Windows backend 通过 `windows_serial_pcm.py` 在 SIM7600G-H 的 audio COM 口 read/write 原始 8kHz/16bit/mono PCM(SerialPcm-over-COM,非 USB Audio Class;见 device-hardware "Windows 平台 backend")。2026-05-31 真拨实测(`retest_audio_write.py`)确认上行**可用**:干净重启后写音频口对端能听到 tone,三种开口方式(rtscts / dsrdtr / lockstep)全 ok≈149、零超时。

但同次排查发现 modem 音频 OUT 端点会进入**卡死态**:`write()` 持续 `SerialTimeoutException`(ok=0),或阻塞写 `write_timeout=None` 第一帧永久挂死;该状态**跨通话、跨 `AT+CPCMREG=0/1` 清不掉,仅整机重启复位**(本次靠物理重插 USB)。诱因均为非正常操作:`AT+CPCMFRM=1`(16K)格式错配、阻塞写挂死、`AT+CFTRANRX` 灌大文件(后者把整机 AT 口都搞挂)。

当前 `write_chunk()` 把 `SerialTimeoutException` 静默 log 后吞掉(见 `windows_serial_pcm.py:290-295`),后果:卡死态下边缘"看似在跑、对端零音频",且现场只能人工物理重插——对无人值守客户 PC 不可接受。事实来源:`isales-telephony/deploy/edge/windows/STATE.md` § "SIM7600 USB audio uplink — 实测可用"。

## Goals / Non-Goals

**Goals:**
- 把"音频 OUT 卡死"从静默失败变为**可观测 + 可自愈**:持续写超时 → `HardwareAlert` + modem 软复位编排。
- 提供 modem 软复位链路,并**在 impl 阶段实测验证软复位能否替代物理重插**清除卡死态。
- 会话初始化从干净 modem 状态起步,降低进入卡死概率。
- 把已验证事实与禁忌操作沉淀进 spec/STATE.md,防止回归与重复误判。

**Non-Goals:**
- 不改 macOS / Linux backend 的写语义(它们不连此型号 modem;Linux 驱动栈不同)。
- 不引入第二条音频通路(`CCMXPLAYWAV` 文件式仅作备选记录,非本 change 实现项)。
- 不追求"任意卡死都能软件自愈"——若实测软复位无效,如实上报需人工干预,不堆叠无效 fallback。
- 不改音频帧格式 / 重采样 / CPCMREG 启停时序(沿用既有 device-hardware 契约)。

## Decisions

**D1 — 写超时 = 卡死信号,而非可忽略噪声。** `write_chunk()` 维护一个"连续写超时计数";单次偶发超时仍容忍(短写/瞬时背压),但**连续 N 帧(默认窗口 ~0.5–1s,例如连续 25–50 帧 @20ms)全超时**判定为 OUT 卡死,raise/上报而非 swallow。阈值保守,避免把正常偶发超时误判触发不必要的通话中断复位。
- 备选:每次超时即复位 —— 否决,过度敏感会因偶发背压误杀通话。
- 备选:维持静默 —— 否决,正是当前 bug,违背 root CLAUDE.md "静默兜底是坏味道"。

**D2 — 软复位优先 `AT+CRESET`,失败/无效再 `AT+CFUN=1,1`,仍无效则上报人工干预。** 单层有意义的递进,每层有明确触发与放弃条件(符合"fallback 必须有移除/升级触发器")。复位后 modem 会重新 USB 枚举 → COM 号重排 → 由既有 USB watcher(认 description 不认号)重新识别 + 重建 audio backend。
- **核心未验证假设**:软复位能否真正清除 OUT 卡死态。本次只证明了"物理重插能清"。impl 阶段 MUST 用可控手段诱发卡死(如故意阻塞写)后实测 `AT+CRESET` 是否复活上行。
- 备选:USB host 侧 Disable/Enable-PnpDevice(等效断电重枚举)—— 记为 D2 的二级 fallback,但需 admin(本次非 admin 实测失败),且 frozen-exe 现场权限不确定,列为 Open Question。

**D3 — 会话初始化干净状态。** orchestrator 启动 / 每通话前确保上一会话 `CPCMREG=0` 已执行;daemon 冷启动可选一次软复位。避免继承上次残留的 OUT 状态。

**D4 — 禁忌操作硬编码避免。** 音频口 write 路径 MUST NOT 写非 8K 格式、MUST NOT 用阻塞 `write_timeout=None`(保持有限 write_timeout);`AT+CFTRANRX` 大文件上传不在生产音频路径(仅诊断脚本,且已知会搞挂 modem)。

## Risks / Trade-offs

- [软复位实测无效,卡死态只能物理重插] → 那么本 change 退化为"可观测 + 明确告警需人工干预",仍优于现状(静默)。这是 impl 阶段第一个要回答的问题,先验证再写自愈逻辑。
- [复位阈值过松 → 偶发背压误触发,中断正常通话] → 阈值取连续全超时窗口(非累计),配可调常量 + 保守默认 + 日志;impl 阶段用真硬件标定。
- [复位后 COM 重枚举竞态 → audio backend 重建期间丢帧/丢通话] → 依赖既有 USB watcher 的 description 匹配 + 重建;复位本就中断当前通话(可接受,优于永久静默卡死)。
- [Disable/Enable-PnpDevice 需 admin,frozen-exe 现场可能无权限] → Open Question,先验证 AT 软复位是否足够,不足再评估安装期授予权限或 watchdog 服务。
- [仅在单台 dev rig + 单 SIM 验证] → 卡死态的确切触发边界未知;spec 记录已知诱因,生产观测告警频率再迭代阈值。
