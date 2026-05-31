## 1. 验证核心假设:软复位能否清卡死态(impl 关卡,先做)

- [ ] 1.1 写可控诱发脚本:真拨通话中故意让音频 OUT 进卡死态(如对音频口阻塞写 `write_timeout=None` 触发挂死,或写错格式),复现 `write()` 持续 `SerialTimeoutException`
- [ ] 1.2 卡死后从 AT 口发 `AT+CRESET`,等 modem 重新枚举,重连音频口,真拨复测上行是否复活(对端听 tone);记录是否替代物理重插
- [ ] 1.3 若 `AT+CRESET` 无效,实测 `AT+CFUN=1,1` 与(admin 下)Disable/Enable-PnpDevice;把结论写回 `isales-telephony/deploy/edge/windows/STATE.md` § "SIM7600 USB audio uplink — 实测可用"
- [ ] 1.4 据 1.1–1.3 结论确定:走"软复位自愈"还是"仅告警需人工干预"(不堆叠无效 fallback)

## 2. AtClient 软复位链路

- [ ] 2.1 `at_client.py` 新增 `reset_modem()`：默认 `AT+CRESET`，失败再 `AT+CFUN=1,1`，每层有明确放弃条件；与 `cpcmreg_enable/disable` 同层
- [ ] 2.2 复位后等待 modem 重新就绪（AT 回 `OK` + `PB DONE`/`+CPIN: READY`）的探测，超时上报 `HardwareAlert`
- [ ] 2.3 单测：mock AT 通道覆盖 CRESET 成功 / CRESET 失败转 CFUN / 两者皆失败上报

## 3. SerialPcm 写超时语义改造

- [ ] 3.1 `windows_serial_pcm.py::WindowsSerialPcmPlayback.write_chunk()`：维护"连续写超时计数"，连续 N 帧（可配置常量，保守默认 ~25–50 帧）全超时 → 升级为 `audio_out_stuck` 信号；单次偶发超时仍容忍
- [ ] 3.2 移除"静默吞 `SerialTimeoutException` 只 log warning"的旧行为；保留有限 `write_timeout`，禁用阻塞 `write_timeout=None`
- [ ] 3.3 单测（注入 fake Serial）：连续超时达阈值触发信号；偶发单次超时不触发；正常写不触发

## 4. orchestrator 编排：卡死 → 复位 → 重建

- [ ] 4.1 orchestrator/`_CallContext` 订阅 `audio_out_stuck`：触发 `reset_modem()` → 经 USB watcher（认 description 不认 COM 号）重新识别 → 重建 capture/playback backend
- [ ] 4.2 复位中断当前通话的清理路径（`CPCMREG=0` best-effort、grpc 上报、状态机回收）
- [ ] 4.3 daemon 冷启动 / 新呼叫前确保上一会话 `CPCMREG=0`；冷启动可选一次软复位（按 1.4 结论决定是否启用）

## 5. 禁忌操作护栏

- [ ] 5.1 生产音频写路径断言/保证：仅写 8kHz/16bit/mono；非 8K 格式与 `write_timeout=None` 在代码层禁用
- [ ] 5.2 `AT+CFTRANRX` 大文件不出现在生产路径；诊断脚本注释明确"会搞挂 modem，需备物理重插"

## 6. 测试与文档同步

- [ ] 6.1 集成/真硬件冒烟：干净启动 → 正常上行可用（对端听 tone，复用 `retest_audio_write.py` 思路）→ 诱发卡死 → 软复位自愈（或如实告警）端到端走通
- [ ] 6.2 `openspec validate --strict` 通过；归档时把已验证事实/阈值标定结果回写 device-hardware spec
- [ ] 6.3 确认 `windows_serial_pcm.py` docstring 与 STATE.md、本 change spec 三者一致（写语义、禁忌操作、软复位结论）

## 7. 上行写口 + 共享句柄（2026-05-31 已实现并真拨验证）

- [x] 7.1 `windows_serial_pcm.py::_SerialPortHolder` 加 `_owns` + `adopt_serial_from()`，close 借用句柄为 no-op
- [x] 7.2 `main_windows.py`：playback 改用 Audio 口 + `adopt_serial_from(capture)`，删除写 COM10 的 `ISALES_MODEM_PCM_WRITE_SERIAL_PATH`
- [x] 7.3 `edge/main.py::_build_audio_backends` windows 分支同样改共享句柄 + Audio 口
- [x] 7.4 `main_windows.py` CPCMFRM=1→0（8K 对齐数据路径）
- [x] 7.5 真拨 13301035545 用生产类（`validate_shared_handle_dial.py`）验证：`cap._serial is pb._serial`、并发读写、**对端听到 tone**

## 8. COM 口按 USB 描述符自动发现（无 env 兜底）（2026-05-31 已实现）

- [x] 8.1 `windows_serial.py` 加 `discover_modem_serial_paths()` + `_probe_at_ok()` + `ModemDiscoveryError` + `AT_DESCRIPTION_TOKEN`
- [x] 8.2 `main_windows.py` + `edge/main.py` 改自动发现，删 `ISALES_MODEM_SERIAL_PATH` / `ISALES_MODEM_AUDIO_SERIAL_PATH` 使用；发现失败 fail-loud
- [x] 8.3 `env.example.txt` 删 COM 号变量，改"自动发现"说明
- [x] 8.4 `tests/windows/test_modem_discovery.py` 6 例 + 真机实测返回 COM16/COM17

## 9. WIP 行为单测对齐（2026-05-31 已修绿）

- [x] 9.1 `test_serial_pcm_audio` read_chunk 空读重试 50 次断言
- [x] 9.2 `test_audio_io` playback pump 320B 整帧合并断言
- [x] 9.3 `bridge.py` 重采样改 rate-aware（用 `frame.sample_rate`，非写死 48kHz `[::6]`）
- [x] 9.4 `test_audio_bridge` 两例随 9.3 修绿
- [ ] 9.5 **遗留（非本会话引入）**：`test_grpc_client::test_reconnect_after_unavailable_during_stream_read` 稳定失败，源自 `grpc_client.py` WIP 改动，待 grpc 路径单独排查；`test_modem_ipc` 4 ERROR 为 Windows+Py3.14 AF_UNIX/asyncio 平台限制（非回归）
