> 实施在新仓 `isales-modem-controller`（待创建）+ engine / api / worker 三仓微调。每组对应 1~2 个 PR，按顺序合入。
> 真硬件验收（11.x）需要插一枚 USB GSM modem，可推迟到 stage 8 与端到端联调一起跑。

## 1. 新仓 isales-modem-controller 骨架（PR #1）

- [ ] 1.1 `git init isales-modem-controller`；`pyproject.toml` 写依赖（`isales-common >=0.1.4`, `pyserial-asyncio`, `pyalsaaudio`, `pyudev`, `httpx`, `numpy`, `scipy`）+ uv-managed venv
- [ ] 1.2 仓库目录结构：`modem_controller/{__init__,main,at_client,audio_pipe,udev_watcher,ipc_server,ipc_codec,recorder,health}.py` + `tests/`
- [ ] 1.3 `modem_controller/main.py`：进程入口；async main 跑 udev watcher + ipc server + 心跳协程；signal handler graceful shutdown
- [ ] 1.4 `pyproject.toml` console_scripts：`modem-controller = modem_controller.main:cli`
- [ ] 1.5 README.md：仓职责 / 依赖系统包 / 启动 / 调试 / 与 isales-engine 关系
- [ ] 1.6 GitHub Actions CI：ruff + mypy + pytest（fake-modem 跑端到端）

## 2. AT 客户端 + URC 解析（PR #2）

- [ ] 2.1 `at_client.py`：`AtClient` 类；`async open(serial_path) → context manager`；启动后 `AT` ping 探活
- [ ] 2.2 命令-响应配对：`async send(cmd, timeout=5.0) → AtResponse(text, ok)`；asyncio.Queue 串行；超时返回 `AtTimeoutError`
- [ ] 2.3 URC reader 协程：按行读串口；`OK / ERROR / +CME` 入响应队列；`RING / NO CARRIER / BUSY / +CLIP` 派发到 URC handler 回调
- [ ] 2.4 `ModemDriver` ABC + `A7670Driver` 默认实现：拨号 / 挂断 / 信号查询 / ICCID 查询 / IMEI 查询；hangup_cause 映射按 spec § GSM hangup_cause 映射 写代码
- [ ] 2.5 `SIM800CDriver` / `QuectelUC20Driver` 子类（v1 stub，遇到差异再覆盖）；型号检测 `AT+GMI / AT+GMM`
- [ ] 2.6 保活：> 5 分钟无命令时自动 `AT` ping
- [ ] 2.7 测试：`tests/at_client/`；mock pty pair + 写 fake-modem 响应脚本，覆盖 ATD ok / ATD busy / ATD no_carrier / URC 异步 RING / 命令超时 / 探活

## 3. PCM 音频管道 + 重采样（PR #3）

- [ ] 3.1 `audio_pipe.py`：`PcmCapture` / `PcmPlayback` 用 pyalsaaudio 打开 `/dev/snd/by-id/usb-...-modem`；8kHz mono 16-bit LE
- [ ] 3.2 重采样：上行 8→16kHz 用 `scipy.signal.resample_poly(up=2, down=1)`；下行 16→8kHz 用 `(up=1, down=2)`；用 numpy int16 ndarray
- [ ] 3.3 Jitter buffer：固定 200ms 环形 deque；不足填静音、过多丢最旧；`pop_chunk(50ms)` 与 ALSA period_size 对齐
- [ ] 3.4 双向独立 stream（rec / play 各起协程）；不强同步时钟；周期性 `snd_pcm_drop()` 校准（5min 一次）
- [ ] 3.5 测试：`tests/audio_pipe/`；用 sine 1kHz 生成 8kHz 上行 → 重采样 → 验证主频不变；下行同
- [ ] 3.6 mock pyalsaaudio 用 numpy queue 替代真实硬件，跑测试不需要 ALSA

## 4. udev 监听 + 设备注册（PR #4）

- [ ] 4.1 `udev_watcher.py`：`pyudev.Context() + Monitor.from_netlink('udev')`；filter `subsystem='tty'`
- [ ] 4.2 add 事件：解 USB vendor/product ID 识别 GSM modem；通过 AT 拉 IMEI；调 `POST /devices` 创建（404 兜底 `PATCH`）；status `detected → registered → idle`
- [ ] 4.3 remove 事件：调 `PATCH /devices/{id}` status=offline；通知 ipc_server 触发 in-call session 走 device_error
- [ ] 4.4 deploy/udev/99-isales-modem.rules：USB modem 自动 chown isales:dialout + 创建稳定别名 `/dev/ttyUSB-isales-modem` 和 `/dev/snd/by-id/usb-isales-modem`
- [ ] 4.5 测试：`tests/udev_watcher/`；mock pyudev events，断言 add → POST/PATCH 调用、remove → status=offline 调用

## 5. IPC server（Unix socket NDJSON）（PR #5）

- [ ] 5.1 `ipc_codec.py`：`async read_frame(reader) → dict`（按 `\n` 切；JSON parse；> 1 MiB error）+ `async write_frame(writer, dict)`（json.dumps + `\n`）
- [ ] 5.2 `ipc_server.py`：asyncio Unix server 监听 `/run/isales/modem.sock`（0660 isales:isales）
- [ ] 5.3 协议指令（spec § engine ↔ modem-controller IPC 协议）：
  - 收 `{type:"dial", call_id, device_id, phone, caller_id}` → 走 at_client.dial → 起 audio_pipe 双向流
  - 收 `{type:"hangup", call_id}` → at_client.hangup → 关 audio_pipe → 推 recording 队列
  - 收 `{type:"send_audio_chunk", call_id, pcm_b64}` → 解 base64 → 入 jitter buffer → ALSA playback
- [ ] 5.4 协议事件：
  - 推 `{type:"call_state", call_id, state, reason}`（dialing / connected / hangup）
  - 推 `{type:"inbound_audio_chunk", call_id, pcm_b64, ts_ms}` 每 50ms 一次
  - 推 `{type:"device_error", call_id, code, message}`
- [ ] 5.5 多并发会话支持：每 call_id 独立 audio_pipe instance；ipc_server 单进程串口资源池化
- [ ] 5.6 测试：`tests/ipc_server/`；真 Unix socket + 真 NDJSON 帧；并发 4 client + dial/hangup 序列

## 6. 录音 + 上传链路（PR #6）

- [ ] 6.1 `recorder.py`：每通起一个 stereo 16kHz wav 写入器；左轨 = 用户上行（重采样后）、右轨 = AI 下行（送 ALSA 之前）
- [ ] 6.2 通话结束 finalize wav 文件（写 RIFF header）→ 路径 `/var/lib/isales/recordings/{call_id}.wav`
- [ ] 6.3 push Redis 队列 `worker:recording-upload`（impl-worker 已实现 worker 侧消费）；payload `{call_id, local_path, sha256}`
- [ ] 6.4 磁盘满守卫：每次新拨号前查 disk free；< 1GB 拒绝 + `ipc_server` 回 `device_error("disk_full")`
- [ ] 6.5 测试：`tests/recorder/`；mock pcm 输入，断言 wav 文件生成 + RIFF 合法 + 入队列调用

## 7. 心跳 + isales-api 端点（PR #7）

- [ ] 7.1 isales-api 仓：alembic migration `add_device_last_seen_at_index`（last_seen_at 列已在 schema；本步加 BTree 索引方便 worker watchdog）
- [ ] 7.2 isales-api 仓：router 加 `PATCH /devices/{id}/heartbeat`；body `{signal_strength: int}`；只更 last_seen_at + signal_strength；service-account JWT 鉴权（spec § 心跳端点不修改其他字段）
- [ ] 7.3 isales-api 测试：test_devices_heartbeat.py：成功 / 不存在 → 404 / 鉴权失败 → 401
- [ ] 7.4 modem-controller 心跳协程：每 30s 对每 registered device 调一次心跳 endpoint；signal_strength 取自 `AT+CSQ` 缓存（10s 拉一次，避免命令风暴）
- [ ] 7.5 isales-worker 仓：新增 `worker/jobs/device_watchdog.py`；30s 周期跑 `UPDATE device SET status='offline' WHERE last_seen_at < now() - interval '120s' AND status != 'offline'`
- [ ] 7.6 isales-worker 测试：fixture 插入 stale device → run watchdog → 断言 status=offline；二次跑幂等

## 8. engine 侧 RealTelephonyClient（PR #8）

- [ ] 8.1 isales-engine 仓：`engine/telephony_client.py`；`RealTelephonyClient` 实现现 `MockTelephony` 接口（`dial / hangup / iter_inbound_audio / send_outbound_audio`）
- [ ] 8.2 连 `/run/isales/modem.sock`（path 来自 env `ISALES_MODEM_IPC_PATH`）；用 ipc_codec 同样的 NDJSON 帧
- [ ] 8.3 dial：发 `{type:"dial",...}`；await 第一个 `call_state=connected`（带 timeout 30s）→ return CallSession；`call_state=hangup` 提前到达 → raise `TelephonyDialFailed(reason)`
- [ ] 8.4 inbound audio：起后台 task 读 `inbound_audio_chunk` 推 asyncio.Queue；`iter_inbound_audio()` 异步 yield
- [ ] 8.5 outbound audio：`send_outbound_audio(pcm_chunk)` → base64 → 发 `{type:"send_audio_chunk",...}`；50ms 节奏由调用方（engine TTS pipe）保证
- [ ] 8.6 device_error 事件：抛 `TelephonyDeviceError` → run_loop catch → ABNORMAL_END / hangup_cause=engine_error
- [ ] 8.7 socket 断连（EPIPE / 长 30s 无 inbound）→ 抛 TelephonyDeviceError 同路径
- [ ] 8.8 `engine/factory.py`：env `ISALES_TELEPHONY_BACKEND=real|mock` 切换；prod 默认 real，CI / dev 默认 mock
- [ ] 8.9 测试：`tests/telephony_client/`；起 fake-modem socket server，断言 dial → connected / dial → busy / inbound chunk → queue / device_error → 抛错

## 9. systemd + udev 部署（PR #9）

- [ ] 9.1 `deploy/systemd/modem-controller.service`：unit `After=systemd-udev-settle.service sound.target`；`Restart=on-failure`；`StartLimitBurst=5`；env 从 `/etc/isales/modem-controller.env` 加载
- [ ] 9.2 `deploy/udev/99-isales-modem.rules`：USB modem ttyUSB / ALSA card 自动 chown + 稳定别名
- [ ] 9.3 `deploy/install.sh`：apt install 系统依赖 + 创建 isales 用户 + `/var/lib/isales/recordings/` 目录骨架 + 拷 systemd / udev 文件 + reload
- [ ] 9.4 `docs/HARDWARE_SETUP.md`：A7670 / SIM800C / Quectel UC20 三型号接入步骤；常见问题（ALSA 找不到 modem / udev rule 没加载 / serial 权限）

## 10. fake-modem 端到端联调脚手架（PR #10）

- [ ] 10.1 `tests/fake_modem/__init__.py`：用 `os.openpty()` 模拟串口；脚本化 AT 响应（拨号 OK → ALERTING → CONNECT → 双向音频 → user-NO CARRIER）
- [ ] 10.2 ALSA loopback：检测 `aloop` 内核模块；存在则用 `hw:Loopback,0,0`；缺失走 numpy queue mock
- [ ] 10.3 端到端 pytest：起 fake-modem + 真 ipc_server + 真 RealTelephonyClient（engine 侧）→ 走完整 dial → audio → hangup 周期
- [ ] 10.4 录入 fake transcript / inbound audio = sine 1kHz 5 秒；断言 wav 落盘 + 队列 push 调用 + transcript ts 单调

## 11. 真硬件验收

- [ ] 11.1 单 USB GSM modem 插开发机 → udev → device 注册 → status=idle
- [ ] 11.2 主仓 / scheduler 投一条线索 → engine 真打自己手机
- [ ] 11.3 至少 3 轮真实对话（greeting + 2 轮 user-AI）；transcript / call_record / pipeline_trace 正确写入
- [ ] 11.4 挂断后录音 wav 上传 OSS 成功；recording_url 回写 call_record
- [ ] 11.5 拔出 modem → udev → device.status=offline；正在通话的 session 走 ABNORMAL_END
- [ ] 11.6 modem-controller 进程 kill -9 → 30s 后心跳停 → 120s 后 watchdog 标 offline
- [ ] 11.7 IMPLEMENTATION_PLAN 阶段 6 验收清单全部勾选；v1 完成标准 #5 真达成

## 12. 收尾

- [ ] 12.1 主仓 commit 标记 impl-modem-controller 实施完成
- [ ] 12.2 archive 由 /opsx:archive 触发
