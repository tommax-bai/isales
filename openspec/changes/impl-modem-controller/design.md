## Context

Stage 6 是整个 v1 系统的最后一块物理拼图：前面 1-5 / 7 把所有上游（schema、API、scheduler、worker、engine 含真实 LLM/ASR/TTS Provider、web 管理面）跑通了，但拨号还停留在 MockTelephony。本 change 把 `device-hardware` spec（已经存在、已审过）转成第一份可运行的实施。

约束：

- 单主机 ≤ 8 路并发（spec § 自研控制层与单主机部署，硬约束）
- Linux + ALSA + udev（macOS / Windows 不支持，开发机用 fake-modem 走 pty 替代）
- 不引入 FreeSWITCH / Asterisk / chan_dongle 等开源 PBX（spec 硬约束）
- engine ↔ modem-controller IPC 帧格式按 spec § IPC 帧格式 NDJSON（已规约，不动）
- 通话录音落本地 wav，上传 OSS 走已有的 isales-worker（impl-worker 已交付）
- isales-common v0.x 已含 device / sim_card / device_sim_binding / call_record schema；v0.1.4 仅可选 bump（last_seen_at 列已在表上）

## Goals / Non-Goals

**Goals:**

- 新仓 `isales-modem-controller`：一个独立的 systemd-managed Linux 守护进程
- AT 命令异步客户端（pyserial-asyncio）覆盖 `ATD<n>;` / `ATH` / `AT+CSQ` / `AT+CCID` / `AT+CGSN` / `AT+CGREG` + URC 解析（`RING` / `NO CARRIER` / `BUSY` / `+CLIP`）
- ALSA PCM 双向管道：上行 8kHz → 16kHz、下行 16kHz → 8kHz；jitter buffer ≤ 200ms
- udev 监听：USB 插拔同步 device 表（`detected → registered → idle` / `→ offline`）
- IPC server：Unix socket NDJSON，多并发会话共用同一进程
- 录音：每通整段 stereo 16kHz wav 落本地，结束后入 worker 队列上传 OSS
- engine 侧 RealTelephonyClient：连本地 socket，行为对齐 MockTelephony 接口（CallSession 类型不变）
- 心跳：modem-controller → isales-api 每 30s 心跳；worker watchdog 把 > 120s 无心跳的 device 置 `offline`
- 验收：插一枚 A7670 / SIM800C / Quectel UC20 任一型号 + 一张可拨打 SIM，主仓开发机端到端打自己手机至少 3 轮真实对话

**Non-Goals:**

- 多主机分布式 modem 农场（v2，spec 已限单主机）
- DTMF 收号 / IVR 菜单（v2）
- SMS 收发（仅可选 USSD 余额查询走 AT，不做 SMS）
- T.38 fax / 视频
- 多 SIM 卡热切（v2，绑定只支持单 SIM）
- WebSocket IPC backend（spec 留作 v2 候选；v1 仅 Unix socket）
- 真账号灰度（stage 8 跟进；本 change 只确保单机端到端能跑）
- macOS / Windows 开发机的真硬件支持（用 fake-modem 走 pty 即可）

## Decisions

### 1. 仓库划分：独立 isales-modem-controller 仓 vs 并入 isales-telephony

- **选择**：独立新仓 `isales-modem-controller`
- **理由**：
  - device-hardware spec § "仓库与进程关系"明示 isales-telephony 仓内可承载 telephony-api 与 modem-controller 两个 entry point，但 v1 实操：modem-controller 依赖系统级 pyalsaaudio / pyudev / pyserial-asyncio，不能在 mac 安装；telephony-api 是普通 fastapi 服务，跨平台 dev 友好。两者放一仓会让 telephony-api 的开发/CI 跑不了
  - 独立仓让 systemd 部署 + udev rules + audio device 权限脚本独立打包，更清爽
  - spec § "仓库与进程关系"是 SHALL 不是 MUST，允许 v1 拆仓
- **替代**：
  - 并入 isales-telephony → CI 跑不了，dev 限定 Linux 体验差
  - 并入 isales-engine → 进程职责不分离（engine 跨主机，modem 单主机）

### 2. 串口异步：pyserial-asyncio vs raw asyncio + serial 文件描述符

- **选择**：`pyserial-asyncio`（封装 `serial.aio` 的协议级 StreamReader/Writer）
- **理由**：成熟、维护活跃；URC 与命令-响应交错的解码逻辑借助 StreamReader 写得最清晰
- **替代**：
  - 直接 `os.open + asyncio.add_reader` → 更轻但要自己管字符串边界
  - `pexpect` → 同步 API，会卡 event loop

### 3. AT 命令-响应配对：行内序列号 vs 严格时序队列

- **选择**：严格时序队列（`asyncio.Queue` 串行发送，等响应或超时再下一条）
- **理由**：GSM modem 不支持 AT command pipelining；URC（`RING` / `NO CARRIER` / `+CLIP`）通过独立 reader 协程旁路给状态机
- **替代**：行内序列号 → 大多数 modem 不识别

### 4. ALSA 重采样：libsoxr vs scipy.signal vs 手写

- **选择**：`scipy.signal.resample_poly`（多相滤波，质量足够 GSM 8k↔16k）
- **理由**：scipy 已是 numpy 配套，无新原生依赖；resample_poly 用整数比 (1:2) 时极快
- **替代**：
  - libsoxr → 装 native lib 麻烦
  - 手写 → 8k↔16k 是经典整数比，但抗混叠滤波器手写易出 bug
  - `audioop.ratecv` → stdlib，C 实现快，兼容性最好；可作为兜底；本 change 主路径用 scipy 走数值精度，cleanup 后切 audioop 也容易

### 5. Jitter buffer 实现：固定大小环形 vs 自适应延迟

- **选择**：固定 200ms 环形 buffer，不足填静音、过多丢最旧
- **理由**：v1 延迟敏感（首字 < 1.5s 目标，spec ai-pipeline）；自适应算法引入延迟波动反而难调
- **替代**：自适应 → v2

### 6. IPC 帧解析：本仓内统一 helper

- **选择**：`modem_controller/ipc_codec.py` 提供 `read_frame(reader) -> dict` / `write_frame(writer, dict) -> None`；engine 侧复制一份（避免引入 modem 仓做 dep）
- **理由**：codec 极简（< 50 行），跨仓共享 schema 用 isales-common 加一个 `ipc_messages` 模块更合适；本 change 不动 isales-common，把 codec 各仓一份
- **替代**：抽 isales-common → v2 候选（顺带把 length-prefix / WebSocket 都规约进来）

### 7. PCM chunk 大小

- **选择**：上行 50ms（16kHz mono 16-bit = 1600 samples = 3200 bytes raw → base64 ~4.3 KB JSON 帧），下行同
- **理由**：50ms 是 ASR provider 通用粒度；与 stage 5 真实 ASR Provider 已经磨合过的 chunk 大小一致
- **替代**：20ms 太碎、IPC 开销高；100ms 端到端延迟 +50ms

### 8. 录音格式：stereo 16kHz wav vs mp3 / opus

- **选择**：stereo 16kHz 16-bit linear wav，左 = 用户上行（ASR 输入）、右 = AI 下行（TTS 输出）
- **理由**：
  - 无损，便于事后回放对齐 transcript
  - stereo 分轨简化 transcript ts 的回放映射
  - mp3/opus 有损 + 编码 CPU 成本（v1 不值得）
  - OSS 上传费用 / 存储不是瓶颈（每通约 5 MB = 1 元/万通）
- **替代**：mp3/opus → v2 候选（量级大了再压）

### 9. 设备注册：IMEI 作天然主键 vs api 自增 ID

- **选择**：api 自增 ID 作主键；IMEI 唯一索引；first-seen 由 modem-controller `POST /devices` 触发，已存在则 `PATCH`
- **理由**：device 表已经在 telephony 域用自增 ID（schema 已固化）
- **替代**：IMEI 主键 → 已经太晚改

### 10. 心跳路径：HTTP（PATCH /devices/{id}/heartbeat）vs Redis pub

- **选择**：HTTP（modem-controller → isales-api）
- **理由**：modem-controller 已经要调 isales-api 做 register / state report；多一个 endpoint 比起再引 Redis 客户端更轻
- **替代**：Redis pub → modem-controller 多一个外部依赖

### 11. fake-modem 测试脚手架：pty pair 模拟串口 + ALSA loopback

- **选择**：fake-modem.py 起 pty pair（`os.openpty`），一端给 at_client、一端模拟 modem 回应；ALSA 用 `aloop` snd-aloop 内核模块走 loopback；本 change 在 CI 跑这套 fake stack 端到端
- **理由**：真硬件不能在 CI 跑；pty + aloop 让 IPC + AT + audio_pipe 全链路测试通过
- **替代**：纯 unit mock → 漏端到端联调
- **限制**：aloop 要 `modprobe snd-aloop` 才能用；GitHub Actions 默认有，本地 mac 没（用 mock fallback）

### 12. engine MockTelephony 保留 vs 删除

- **选择**：保留；env `ISALES_TELEPHONY_BACKEND=mock|real` 切换
- **理由**：
  - 本地脱机调试 / unit test 需要
  - prod 万一 modem 全坏，切 mock 也可应急（开发模式 fallback）
- **替代**：删 → 调试体验降级

### 13. 录音上传链路：modem-controller 直传 vs 通过 worker 队列

- **选择**：modem-controller 写本地 wav → 挂断后 push 到 Redis 队列 `worker:recording-upload` → worker 上传 OSS（impl-worker 已实现 worker 侧）
- **理由**：上传走 worker 让 modem-controller 不操心 OSS 鉴权；worker 已经有重试 / 失败队列
- **替代**：modem-controller 直传 → 又一份 OSS 凭据，且重试逻辑要复制

## Risks / Trade-offs

| 风险 | 缓解 |
|---|---|
| 不同 modem 型号 AT 兼容性差异（A7670 / SIM800C / Quectel UC20 行为微差） | v1 在 `at_client.py` 抽 `ModemDriver` ABC，三型号各一个驱动子类；首推 A7670（库存最稳）；spec hangup_cause 映射做型号无关、按返回码映射 |
| URC 异步事件与 ATD 命令响应交错 | 单 reader 协程负责按行分类：以 `OK / ERROR / +<TAG>` 起头的视为命令响应入响应队列；其他视为 URC，按类型 fan-out 给状态机 |
| ALSA card index 不稳定（USB 插拔后变化） | 用 udev rule 给 modem 挂稳定别名 `/dev/snd/by-id/usb-ZTE-Modem`；`audio_pipe.py` 用别名打开；插拔重启时由 udev 重建别名 |
| ALSA 双向 IO 不同步（rec/play 时钟漂移） | rec / play 各自起一个独立 stream，不强行同步；jitter buffer 吃掉短时漂移；长漂用周期性 `snd_pcm_drop()` 校准（5 分钟一次） |
| pyserial-asyncio 在长时间运行下偶发 file descriptor leak | tested 至 v0.6.x；`at_client.py` 用 `asynccontextmanager`，确保任意路径下 close；新增 watchdog：> 5 分钟未发命令就 ping `AT` 探活（spec § device 状态机：流量稀疏时 modem 进省电模式，需要保活） |
| 录音文件落盘磁盘满 | `recorder.py` 启动时检查 `/var/lib/isales/recordings` 剩余空间 < 1GB → 拒绝接受新拨号 + ipc_server 回 `device_error("disk_full")`；worker 上传成功后立即删本地文件（impl-worker 已就位） |
| 心跳 PATCH 风暴（每 30s × 8 路 = 16 次/分钟）打到 isales-api | 走专用 endpoint `/devices/{id}/heartbeat`，免 auth check 由 service-account JWT 替代；后端只更新 last_seen_at + signal_strength（不动其他字段，无 race） |
| systemd 启动顺序：modem-controller 先于 udev / ALSA 依赖就绪 | unit `After=systemd-udev-settle.service sound.target`；启动失败重启 5 次内退避，超出停服并报警 |
| device 状态在 udev 拔出 vs 心跳 watchdog 双路触发竞态 | watchdog 跑 idempotent UPDATE WHERE last_seen_at < threshold AND status != 'offline'；udev path 直接 PATCH status='offline'；DB UPDATE 自带行锁，无须显式同步 |
| modem-controller 进程 crash 时正在通话的 session 处理 | engine 侧 RealTelephonyClient detect socket EPIPE / 长 30s 无 inbound_audio → emit ABNORMAL_END；call_record 标 hangup_cause=engine_error |
| pyalsaaudio 在某些发行版需 libasound2-dev 编译 | deploy/install.sh 检查并自动 apt install；docs/HARDWARE_SETUP.md 列出系统包清单 |
| 真号码灰度泄露隐私 / 法规风险 | 本 change 不上线灰度；docs 标注"开发机自用，禁外呼"；stage 8 才走灰度审批 |

## Migration Plan

新仓首次部署：

1. `git clone` isales-modem-controller 到目标主机
2. `apt install libasound2-dev libudev1 udev` + `pip install -e .`
3. 拷 `deploy/udev/99-isales-modem.rules` 到 `/etc/udev/rules.d/` + `udevadm control --reload`
4. 拷 `deploy/systemd/modem-controller.service` 到 `/etc/systemd/system/` + `systemctl daemon-reload`
5. 创建 `/var/lib/isales/recordings/` + chown isales:isales
6. 设置 env：`ISALES_API_BASE_URL` / `ISALES_MODEM_AUTH_TOKEN` / `ISALES_TELEPHONY_BACKEND=real`
7. `systemctl start modem-controller`，`journalctl -f -u modem-controller` 看启动日志
8. 插 USB GSM modem，验证 udev → POST /devices → status=idle
9. engine 侧重启使 `ISALES_TELEPHONY_BACKEND=real` 生效

回滚：

1. `systemctl stop modem-controller`
2. engine 侧 `ISALES_TELEPHONY_BACKEND=mock` + 重启
3. 拔出 USB modem（避免误触发）

数据：本 change 不动 schema，纯新仓 + engine 配置切换；不需要数据迁移。

## Open Questions

- modem 型号优先级：A7670 vs SIM800C 哪个作 v1 默认？等运维同学定（影响 ModemDriver 默认实现 + docs 优先级）
- ALSA 还是 OSS（Open Sound System）：v1 锁 ALSA；如未来要支持 macOS dev 用 OSS via VirtualBox passthrough → v2
- 录音 stereo 是否要带 transcript timestamp 起点对齐：v1 录音 ts=0 对齐 call_started；transcript 自带 ms-since-call-start 已经够（impl-engine 已实现）
- modem 型号探测：v1 启动时一次 `AT+GMI` + `AT+GMM` 拉厂商 / 型号，按结果选 driver；如无返回则按 env `ISALES_MODEM_DRIVER` 兜底
- 多 modem 同主机：本 change 只验证 1 枚；ipc_server / udev_watcher 设计上支持多枚（同一进程多串口），实际验收 v2
- 在通话期间 USB 拔出的清理时序：udev remove → ipc_server 关本路 socket → engine 收 EPIPE → ABNORMAL_END。是否需要 graceful 30s 排空 buffer？v1 不做（拔出已经断电，buffer 数据无效）
- AGC / 噪音抑制：8kHz GSM 上行噪音可能高，要不要在 audio_pipe 里串个 webrtcvad / rnnoise？v1 不做，先看真打测试效果再决定 v2
- 整体并发上限验证：spec 说单主机 ≤ 8 路；v1 验收只跑 1 路，8 路压测列入 stage 8
