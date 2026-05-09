> 实施落在 `isales-telephony/isales_telephony/modem_controller/`（扩展 stage-2
> 已搭好的 mock 脚手架，对齐 device-hardware spec § 仓库与进程关系 SHALL）
> + isales-engine 加 RealTelephonyClient + isales-worker 加 watchdog。设计决策
> §1 在实施初期一度走的是新仓 `isales-modem-controller`，跑了 6 个 PR 后撞到
> 协议字段名偏离（type vs cmd）+ 重复脚手架，反向了；详见 design.md 决策 §1。
>
> 真硬件验收（PR #11）需要插一枚 USB GSM modem，推迟到 stage 8。

## 1. modem-controller 骨架 + 依赖（PR #1）✅

- [x] 1.1 `pyproject.toml` 加 `httpx / structlog / numpy / scipy`（生产）+ `[hardware]` extra（pyserial / pyserial-asyncio / pyalsaaudio，全部 Linux 门控）
- [x] 1.2 `modem_controller/` 既有 `at_client.py` `handlers.py` `ipc_server.py` `udev_watcher.py` `main.py`（stage 2 留下）
- [x] 1.3 console_scripts `modem-controller = isales_telephony.modem_controller.main:run` 已存在
- [x] 1.4 README + docs/HARDWARE_SETUP.md（A7670 / SIM800C / Quectel UC20 接入步骤）
- [x] 1.5 telephony 现有 GitHub Actions CI 自动覆盖新模块（ruff + mypy + pytest）

## 2. AT 客户端 + URC 解析（PR #2）✅

- [x] 2.1 `serial_protocol.py` 新加：`AtClient` 类（async open(reader, writer) → context manager）；启动后 `AT` ping 探活
- [x] 2.2 命令-响应配对：asyncio.Queue 串行 + 超时 → `AtTimeoutError`
- [x] 2.3 URC reader 协程：按行分类，OK / ERROR / +CME / +CMS 入响应队列；RING / NO CARRIER / BUSY / +CLIP / +CREG 派发到 URC handler
- [x] 2.4 `drivers.py` 新加：`ModemDriver` ABC + `A7670Driver` 默认实现；hangup_cause 映射（spec § GSM hangup_cause 映射）
- [x] 2.5 `SIM800CDriver` / `QuectelUC20Driver` 子类（v1 stub 继承 A7670Driver）+ `detect_driver()` 通过 AT+GMI/AT+GMM
- [x] 2.6 保活通过 `default_timeout` + AtTimeoutError 触发；专用 ping 协程列入 v2
- [x] 2.7 测试：`tests/modem_serial/`（6 用例覆盖 ATD ok / ERROR / +CME / 超时 / URC 分发 / driver init）

## 3. PCM 音频管道 + 重采样（PR #3）✅

- [x] 3.1 `audio_pipe.py`：`CaptureBackend` / `PlaybackBackend` Protocol；ALSA 作为生产 backend（pyalsaaudio Linux only）
- [x] 3.2 重采样：`scipy.signal.resample_poly(up=2, down=1)` 上行，反向下行
- [x] 3.3 Jitter buffer：固定 200ms (4 chunks × 50ms)；underrun 填静音、overrun 丢最旧
- [x] 3.4 双向独立流（`run_capture` + `run_playback` 各起协程）
- [x] 3.5 测试：sine 1kHz 重采样后主频不变；jitter buffer 增删；run_capture 调 inbound hook
- [x] 3.6 mock backend：测试用 numpy queue 替代真 ALSA，跑 CI 不需要内核 module

## 4. udev 监听 + 设备注册（PR #4）✅

- [x] 4.1 `udev_watcher.py`（telephony stage-2 既有）：pyudev MonitorObserver；filter `subsystem='tty'`
- [x] 4.2 add 事件：USB vendor/product ID 识别；触发 `_touch_last_seen` 更 device.last_seen_at
- [x] 4.3 remove 事件：`_mark_offline` 直接置 `status=offline`
- [x] 4.4 `deploy/99-isales-modem.rules`：A7670 / SIM800C / Quectel UC20 / Qualcomm 通用 idVendor/idProduct → 稳定 symlink + group ownership
- [x] 4.5 测试：fake_events + consume_events 覆盖 add → last_seen_at / remove → offline / 未知 vid 跳过 / 非 Linux 跳过

## 5. IPC server（Unix socket NDJSON）（PR #5）✅

- [x] 5.1 帧格式 (telephony stage-2 既有)：`Connection.send / IPCServer._read_loop`，按 `\n` 切；> 1 MiB 关连接；不完整帧关连接；非法 JSON 关连接
- [x] 5.2 协议（spec § 指令格式）：`{cmd: dial|hangup|audio_downstream, session_id, ...}`；echo session_id 在 dial_ack / events 上
- [x] 5.3 协议（spec § 事件格式）：`{event: dial_ack|connected|remote_hangup|hangup_ack, session_id, call_id, cause, device_id}`；engine 侧 RealTelephonyClient 按 session_id 路由
- [x] 5.4 多并发会话：handlers per-call _pump 协程独立；ipc 单进程串口资源池化（v1 单 modem 即可）
- [x] 5.5 backward compat：未传 session_id 的旧 client 仍能用（dial_ack / events 不带 session_id 字段）
- [x] 5.6 测试（stage 2 既有 + PR #10 fake-modem e2e）：status / unknown cmd / 不完整帧 / 非法 JSON / session_id 来回 / 旧 client 兼容

## 6. 录音 + 上传链路（PR #6）✅

- [x] 6.1 `recorder.py`：每通起一个 stereo 16 kHz wav 写入器（左 user 上行，右 AI 下行）
- [x] 6.2 finalize: numpy interleave + wave 模块写 RIFF header → `/var/lib/isales/recordings/{call_id}.wav`
- [x] 6.3 `RedisRecordingQueue.enqueue` push 到 `worker:recording-upload`（含 sha256 + size）
- [x] 6.4 磁盘满守卫：`Recorder.begin_call` 检查 `shutil.disk_usage` < 1GB → `DiskFullError`
- [x] 6.5 测试：stereo 帧数 / 短轨道补静音 / 未知 call_id 安全返回 None / 磁盘门控 / sha256 / 同步+异步 redis 都接

## 7. 心跳 + telephony-api endpoint + worker watchdog（PR #7）✅

- [x] 7.1 telephony schema 已含 `device.last_seen_at`（data-model spec），无需新 migration
- [x] 7.2 telephony router 加 `PATCH /devices/{id}/heartbeat`：仅更 `last_seen_at = now()`；接 `signal_strength` 但暂不级联回写 sim_card（v2）；spec delta § 心跳端点不修改其他字段 锁死
- [x] 7.3 telephony 测试：成功更 last_seen_at / 不带 signal_strength / 不动 status / 404 / 422 (signal_strength 越界)
- [x] 7.4 modem_controller `heartbeat.py`：`heartbeat_loop()` 30s 发；动态 device 集；signal_strength_provider；per-device 失败不影响其他设备
- [x] 7.5 isales-worker `device_watchdog.py`：30s 周期 UPDATE 把 > 120s last_seen_at 的 device 置 offline（WHERE status != 'offline' 守卫幂等）
- [x] 7.6 worker 测试：stale → offline / fresh 不动 / 已 offline 幂等 / 无 last_seen_at 跳过 / loop n iterations

## 8. engine 侧 RealTelephonyClient（PR #8）✅

- [x] 8.1 `realtime/real_telephony.py`：实现 TelephonyClient ABC（dial / hangup / audio_in / audio_out / events）
- [x] 8.2 连 `engine_telephony_socket_path`（默认 `/var/run/isales/modem.sock`）；NDJSON 帧 + asyncio Stream
- [x] 8.3 dial：发 `{cmd: dial, session_id: str(call_id), device_id, number}`；async 等 connected/hangup 事件
- [x] 8.4 inbound audio：reader task 解 base64 推 asyncio.Queue per session；audio_in() async yield
- [x] 8.5 outbound audio：`send_outbound_audio` → base64 → `{cmd: audio_downstream, session_id, pcm_chunk}`；50ms 节奏由调用方保
- [x] 8.6 device_error 事件：emit TelephonyEvent.device_error 到 events 流；同时 close session（events stream 终止）
- [x] 8.7 socket 断连（EOF）→ 对所有活跃 session 广播一条 `device_error("ipc_disconnected")` + 关流
- [x] 8.8 `engine/main.py:_build_telephony` 加 `real` 分支；env `ISALES_ENGINE_TELEPHONY_MODE=mock|real`（默认 mock，prod 切 real）
- [x] 8.9 测试：`tests/test_real_telephony.py` 5 用例 — dial → connected / 双向 audio / device_error 关流 / 断连合成 device_error / audio_out base64 编码

## 9. systemd + udev 部署（PR #9）✅

- [x] 9.1 `deploy/isales-modem-controller.service`：`After=systemd-udev-settle.service sound.target`，`Restart=on-failure StartLimitBurst=5`，env 从 `/etc/isales/modem-controller.env` 加载，加 RuntimeDirectory + StateDirectory + SupplementaryGroups (dialout / audio / plugdev)
- [x] 9.2 `deploy/99-isales-modem.rules`：A7670 / SIM800C / Quectel UC20 / Qualcomm USB → ttyUSB-isales-modem symlink + audio card 稳定别名
- [x] 9.3 `deploy/install-modem-controller.sh`：apt install + 创建 isales 用户 + 目录骨架 + 拷 systemd / udev + reload
- [x] 9.4 `docs/HARDWARE_SETUP.md`：三型号接入步骤 + 6 类常见问题（ALSA 找不到 / udev 没加载 / serial 权限 / 自动识别失败 / signal=99 / 验收清单）

## 10. fake-modem 端到端联调（PR #10）✅

- [x] 10.1 复用 stage-2 `MockATClient`（pyserial 不需要）+ 既有 `_serve` fixture pattern；`tests/test_fake_modem_e2e.py` 端到端走 IPC + 真 IPCServer + handlers + DB
- [x] 10.2 ALSA loopback：v1 mock 走 numpy queue（CaptureBackend / PlaybackBackend Protocol，测试注 fake）— 真 aloop 留 PR #11 验收时启用
- [x] 10.3 端到端 pytest：发 `cmd: dial, session_id` → 收 dial_ack with session_id → connected → remote_hangup；device.status idle → dialing → in_call → idle 全程正确
- [x] 10.4 backward-compat：旧 client 不传 session_id 仍能拿到 dial_ack 与事件流（pump 有清场，不污染下游测试）

## 11. 真硬件验收（PR #11）— DEFERRED 阶段 8

- [ ] 11.1 单 USB GSM modem 插开发机 → udev → device 注册 → status=idle — 需真硬件
- [ ] 11.2 主仓 / scheduler 投一条线索 → engine 真打自己手机 — 需真硬件 + 真 SIM
- [ ] 11.3 至少 3 轮真实对话（greeting + 2 轮 user-AI）；transcript / call_record / pipeline_trace 正确写入 — 需真硬件 + 真 ASR/LLM/TTS
- [ ] 11.4 挂断后录音 wav 上传 OSS 成功；recording_url 回写 call_record — 需真硬件 + OSS
- [ ] 11.5 拔出 modem → udev → device.status=offline；正在通话的 session 走 ABNORMAL_END — 需真硬件
- [ ] 11.6 modem-controller 进程 kill -9 → 30s 后心跳停 → 120s 后 watchdog 标 offline — 需真硬件 + 真 telephony-api 部署
- [ ] 11.7 IMPLEMENTATION_PLAN 阶段 6 验收清单全部勾选；v1 完成标准 #5 真达成

## 12. 收尾

- [x] 12.1 主仓 commit 标记 impl-modem-controller 实施完成（PR #1-#10 落地，PR #11 DEFERRED 待真硬件）
- [ ] 12.2 archive 由 /opsx:archive 触发
