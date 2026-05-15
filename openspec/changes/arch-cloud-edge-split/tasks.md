## 1. Sprint 0 准备（与 A2 impl 并行，不阻塞）

- [ ] 1.1 阿里云 QA 环境开通：ECS 4C16G Ubuntu 22.04 + RDS PG16 + Redis 1G + OSS bucket + 域名 + Let's Encrypt
- [ ] 1.2 阿里 RTC 应用创建（拿 AppId / AppKey）+ 工单确认计费套餐细节（参考 PoC §9 三题工单稿）
- [x] 1.3 ARTC SDK for Linux Python 与 macOS Python 压缩包下载、放入内部 artifact 仓 / OSS 私有 bucket  <!-- Linux SDK 在 ~/codes/vendor/AliRTCSDK_Linux-7.10.2/；macOS 在 ~/codes/vendor/AliRTCSdk_macos/（注：macOS 是纯 Obj-C framework，无 Python wrapper —— audio_bridge 走 mock 实装而非真 SDK，见 reference_artc_sdk.md 决策记录） -->
- [ ] 1.4 跑 PoC Day 2 实测脚本（[PoC §8](../../v1-roadmap-aliyun-rtc-poc-result.md#8-day-2-实测脚本sprint-0-期间执行)），把决策表"实测"列填实
- [ ] 1.5 Mac mini QA 边缘机准备：插 GSM modem 确认 USB 串口、装 macOS 通过 `impl-deploy-macos` 既有 launchd 套件

## 2. isales-common：proto 定义 + transport 抽象

- [x] 2.1 新增 `isales_common/proto/cloud_edge.proto`，定义 `service CloudEdge` + `Edge2Cloud` / `Cloud2Edge` 两个 oneof message + `DialCommand` / `CancelCommand` / `Heartbeat` / `CallEvent` / `HardwareAlert` / `ConfigUpdate` / `RtcCredentials` / `DialAck` 字段（与 service-communication spec § 服务定义 一致）  <!-- isales-common v0.2.0 (7426d79) -->
- [x] 2.2 配置 `make proto` 跑 `protoc` 生成 `cloud_edge_pb2.py` / `cloud_edge_pb2_grpc.py` 编译产物；产物随 pip 包分发  <!-- v0.2.0 + v0.2.1 (31b1f83) sed post-process 修了 pb2_grpc package-relative import -->
- [x] 2.3 新增 `isales_common/transport/cloud_edge_abc.py` 抽象基类：`CloudEdgeServer`（云端起 server）+ `CloudEdgeClient`（边缘 client）+ 心跳 / 重连 / token 验证接口  <!-- 实际命名 transport/cloud_edge.py（不含 _abc 后缀），内容一致 -->
- [x] 2.4 新增 `isales_common/audio/rtc_backend.py` 抽象：`RtcCaptureBackend` / `RtcPlaybackBackend` 与既有 capture / playback ABC 兼容  <!-- 实际命名 audio/rtc.py，单一对称的 RtcSession ABC（join / leave / audio_frames / push_audio），比拆 Capture/Playback 两个更贴近真 SDK；audio_pipe 层的 Capture/Playback adapter 留 caller 在 RtcSession 上薄 wrap -->
- [x] 2.5 单测：proto 双向序列化 + transport 抽象 mock 实现 + audio backend mock  <!-- 27 tests in isales-common v0.2.0 -->

## 3. isales-engine：云端 ARTC SDK 接入

- [x] 3.1 新增 `isales_engine/transport/aliyun_rtc.py`，封装 ARTC SDK Linux Python：`RtcSession(channel, token, uid).join() / leave()` + `async on_audio_frame()` 迭代器 + `async push_audio(pcm, ts)` + buffer-full 反压  <!-- engine PR #1 (924b64b) `AliyunRtcSession` + PR #1 follow-up (ca62824) `_AliyunArtcChannel` 真 SDK adaptor + `InMemorySdkChannel` test double -->
- [x] 3.2 SDK vendor 解压脚本：`deploy/cloud/scripts/install-artc-sdk.sh`，从 OSS 拉压缩包到 `/opt/isales/current/vendor/aliyun-artc-linux-python/`，注入 `sys.path` 或 pip 本地 install  <!-- meta-repo: deploy/cloud/scripts/install-artc-sdk.sh；支持 oss:// / file:// / https:// 三种 URL scheme，VERSION 文件用于幂等，注入路径通过 engine.env 的 LD_LIBRARY_PATH + PYTHONPATH 而非 sys.path/pip install -->
- [ ] 3.3 `isales_engine/audio_pipe.py` 新增 `AliyunRTCCapture` / `AliyunRTCPlayback` backend 实现，桥接 `RtcSession` 的 PCM 回调与推送  <!-- 替代方案：engine PR #5 (2a04c37) `realtime/rtc_telephony.py` `RtcTelephonyClient` 直接包 RtcSession + grpc_server + dispatcher 成 TelephonyClient ABC，跳过单独的 audio_pipe Capture/Playback 层；3.4 跟随 3.3 一起延后 -->
- [ ] 3.4 v1.0 云端默认 backend 切换为 `AliyunRTCCapture/Playback`；本地开发 backend 通过环境变量 `ISALES_AUDIO_BACKEND=local` 切回
- [x] 3.5 单测：用 mock SDK 验证 `RtcSession` 入会 / 离会 / 推帧 / 拉帧的状态机  <!-- 13 tests (engine PR #1) + 4 vendor sanity tests (PR #1 follow-up, gated on $ISALES_RTC_SDK_PATH) -->

## 4. isales-engine：云-边 gRPC server

- [x] 4.1 新增 `isales_engine/transport/grpc_server.py`：起 `CloudEdge.Bidi` server，监听 0.0.0.0:50051（TLS via nginx 反代或 grpcio 内置）  <!-- engine PR #2 (86f433d) `CloudEdgeGrpcServer`；TLS-ready via start(server_credentials=...) -->
- [x] 4.2 实现 token 验证（gRPC metadata `authorization`）→ 绑定 edge_device_id 到 stream context  <!-- engine PR #2 _authenticate via TokenVerifier ABC; UNAUTHENTICATED on failure -->
- [x] 4.3 心跳逻辑：收到 Edge `Heartbeat` 后回 Cloud `Heartbeat` + 更新云内 PG `last_heartbeat`  <!-- gRPC 层心跳收发 ✓（grpc_server 把 Heartbeat 当 oneof payload 路由给 dispatcher，dispatcher 视为 no-op transport layer concern）；"更新云内 PG last_heartbeat" 归 task 9.4 worker watchdog -->
- [x] 4.4 事件路由：`CallEvent` / `HardwareAlert` / `DialAck` 进 engine session dispatcher（按 call_id 找 session）+ 落 PG  <!-- engine PR #4 (e185abe) `EngineSessionDispatcher` 按 call_id 路由 CallEvent / DialAck；HardwareAlert 路由到 process-wide handler。"落 PG" 归 9.3 worker -->
- [x] 4.5 cloud → edge 命令下发：engine session 发起 `DialCommand` / `CancelCommand` / `ConfigUpdate` / `RtcCredentials` 路径  <!-- PR #2 CloudEdgeGrpcServer.send_to_edge() + PR #5 RtcTelephonyClient.dial/hangup 使用 -->
- [x] 4.6 集成测试：本地 grpcio + mock edge client 跑通 dial → call_event → cancel → leave 全链路  <!-- engine PR #2 9 集成 tests 用真 grpc.aio server + _GrpcEdgeProbe helper client -->

## 5. isales-engine：engine session co-location 改造

- [x] 5.1 engine session lifecycle 接 `DialCommand` 触发（替代 Redis Queue 触发）；Redis Queue 接口保留但单实例下走同进程函数  <!-- engine PR #5 (2a04c37) `RtcTelephonyClient.dial` → grpc_server.send_to_edge(DialCommand)；RealTelephonyClient (Unix socket) 保留作为 v1 fallback；wire-up 到 main 留 Task 14 -->
- [x] 5.2 同进程 asyncio dispatcher：按 call_id 维护 active session 字典；`Edge2Cloud.CallEvent: remote_hangup` 与 cancel 路径直接 deliver 到 session  <!-- engine PR #4 EngineSessionDispatcher.register/deregister + on_call_event callback；PR #5 RtcTelephonyClient._CallState.on_call_event 接 dispatcher -->
- [x] 5.3 cancel 路径**确认不走 Redis Pub/Sub**：在云内 api 触发的 cancel 也改为函数调用进 dispatcher  <!-- PR #5 RtcTelephonyClient.hangup → grpc_server.send_to_edge(CancelCommand)；不调任何 Redis -->
- [x] 5.4 RTC token 生成：engine 在派发 DialCommand 前用 AppKey 签发 `engine-{call_id}` 与 `edge-{call_id}` 两个 token，塞进 DialCommand  <!-- engine PR #3 (2eff634) `RtcTokenIssuer` 纯 Python SHA-256 算法（与阿里官方文档一致）；sign_for_call() 返回 (engine_creds, edge_creds) pair -->
- [ ] 5.5 端到端测试：本地 mock 边缘 + 云端 engine + 真 ARTC（QA 环境）跑通一通通话 join → audio → leave  <!-- 单元 + 集成测试 ✓；真 ARTC e2e 需要 ECS 上 vendor SDK + RTC AppId，留 Task 14 -->

## 6. isales-scheduler：dial 路径重构

- [ ] 6.1 选 device 逻辑从"HTTP 调 telephony-api `/devices/select`"改为云内 PG 直查 + 行级锁
- [ ] 6.2 dial 派发：生成 call_id → 写云内 PG call 表 → 通过 engine 暴露的内部接口（云内函数调用 / Redis Queue 保留兜底）发起 → engine 内 grpc_server 发 `DialCommand` 给边缘
- [ ] 6.3 移除 telephony-api HTTP client 代码 + tests
- [ ] 6.4 单测：选 device 算法 + 并发安全（两 dial 不能选同一 idle device）

## 7. isales-telephony：边缘进程重构

- [ ] 7.1 重组 isales-telephony 仓库结构：单一 entry point + asyncio task group（modem-controller / audio-bridge / cloud-edge gRPC client / telephony-api HTTP loopback）  <!-- 依赖 7.3 modem-controller 改造完才能做（destructive，建议 fresh session） -->
- [x] 7.2 新增 `isales_telephony/audio_bridge/__init__.py`：ARTC SDK macOS Python wrapper + `JoinChannel` + `SetExternalAudioSource` + `PushExternalAudioFrameRawData` + `OnSubscribeAudioFrame` + 反压  <!-- telephony PR #2 (a508861) `audio_bridge/` 全套（PcmRingBuffer + Resampler scipy + MacosRtcSession + AudioBridge）。**Deviation**: macOS SDK 是纯 Obj-C Cocoa framework 无 Python wrapper，MacosRtcSession 是 loopback mock + 模拟反压；商用真 SDK 走 D1 Windows 路径（Task 15）。决策见 reference_artc_sdk.md。`PcmFrame` wire-format 与生产一致，engine 业务代码看到的数据形状不变 -->
- [ ] 7.3 modem-controller 重构：上行 PCM 不再直接推 Unix socket，改推同进程上行环形 buffer；下行 PCM 从同进程下行环形 buffer 取  <!-- destructive 改造，建议 fresh session，Task 13c -->
- [x] 7.4 PCM 重采样：上行 8 kHz → 16 kHz、下行 16 kHz → 8 kHz；用 macOS Audio Converter 或 `audioop.ratecv`  <!-- telephony PR #2 audio_bridge/resampler.py，scipy.signal.resample_poly polyphase FIR（audioop 在 Python 3.13+ 移除）；round-trip RMS 误差 < 5% -->
- [x] 7.5 新增 `isales_telephony/transport/grpc_client.py`：与云端 engine 建立 bidi stream + 心跳 + 自动重连 + 本地 SQLite buffer  <!-- telephony PR #1 (4541038) `CloudEdgeGrpcClient`：grpc.aio bidi + Bearer token + auto-reconnect (exponential backoff, infinite retries) + in-memory deque buffer。**SQLite 集成**：telephony PR #4 把 `SqliteEventBuffer` 作为 opt-in `event_buffer` ctor 参数接进客户端；传入即用 sqlite，未传则保留 in-memory deque（测试默认）。`_flush_buffer` 按 seq 顺序 drain + `delete_through` weak-ACK。-->
- [x] 7.6 SQLite buffer 实现：`~/Library/Application Support/isales/sqlite/edge_buffer.db`，存 `CallEvent` / `HardwareAlert` 待补发；server ACK 后删除  <!-- telephony PR #3 (2c72faa) `SqliteEventBuffer` WAL durable buffer，append/iter_pending/delete_through/容量 rotation + 18 tests。集成进 `CloudEdgeGrpcClient` 见 7.5 (telephony PR #4)：opt-in `event_buffer` 参数 + 4 个 integration tests (append while disconnected / critical 仍 raise / 按序 flush + delete_through / 跨 client 实例存活)。-->
- [ ] 7.7 telephony-api HTTP 角色降级：限制 loopback 监听 + `/devices/select` 加 `Deprecation: 1` header  <!-- 跟 7.1 / 7.3 一起做 -->
- [x] 7.8 单测：环形 buffer 容量 + 反压 + gRPC client 断线重连 + SQLite buffer 补发顺序  <!-- 53 个新增测试 split across 三个 PR：grpc_client 11 + audio_bridge 24 + sqlite_buffer 18 -->

## 8. ARTC SDK macOS vendor

**N/A — macOS edge 走 mock 路线**：inspect 后发现 macOS SDK 是纯 Obj-C Cocoa
framework（19 个 .h 头 / 4 个 ALI_RTC_API C 函数全是 video/screenshare），
无 Python wrapper。PyObjC bridge 是数百行投入换 QA-only 形态，与 v1-roadmap
"商用 = Windows / D1" 不符。决策走 mock `MacosRtcSession`（telephony PR #2），
真 audio 集成在 D1 Windows 阶段（Task 15）。详细决策见 reference_artc_sdk.md
"macOS SDK 决策"章节。下面 8.1-8.3 整组 obsolete，归档时合并。

- [ ] 8.1 边缘 deploy 脚本：`deploy/edge/scripts/install-artc-sdk.sh` 解压 ARTC SDK macOS 到 `~/Library/Application Support/isales/vendor/aliyun-artc-macos-python/`  <!-- obsolete -->
- [ ] 8.2 isales-telephony pyproject / requirements 引用 vendor 路径  <!-- obsolete -->
- [ ] 8.3 macOS 上的实际入会测试（独立小脚本，QA 环境）  <!-- obsolete -->

## 9. isales-api / isales-worker：云端调整

- [ ] 9.1 isales-api：新增内部 endpoint 给前端"看哪些边缘机在线"（基于云内 PG `edge_device.last_heartbeat`）
- [ ] 9.2 isales-api：签发 `EDGE_DEVICE_TOKEN` 的内部工具 + 文档
- [ ] 9.3 isales-worker：处理 `HardwareAlert` 事件（A2 范围：仅落 PG 与基础日志告警；详细告警 / 一键诊断 由 D2 处理）
- [ ] 9.4 isales-worker：watchdog 监听 cloud-edge stream 健康度，超 120 s 无心跳的边缘机 device 置 offline

## 10. 云端部署脚本与 RUNBOOK

- [x] 10.1 新增 `deploy/cloud/` 目录：systemd unit (api / engine / scheduler / worker)、nginx 配置（反代 isales-web + isales-api + cloud-edge gRPC SNI）、env.example  <!-- meta-repo: deploy/cloud/{README.md, systemd/4 units, nginx/isales.conf, env/4 .example}；nginx 反代 443→web/api + 50051→engine gRPC，TLS terminate；engine.env 含 ARTC SDK LD_LIBRARY_PATH/PYTHONPATH + RTC AppId/AppKey + gRPC bind -->
- [x] 10.2 `deploy/cloud/scripts/install.sh`：拉代码 + 装依赖（含 ARTC SDK vendor 步骤）+ 跑 alembic + 重启服务  <!-- meta-repo: deploy/cloud/scripts/install.sh；8 步：release dir → git clone → venv → web build → ARTC SDK (delegates to install-artc-sdk.sh) → systemd → nginx (rewrite __ISALES_DOMAIN__) → env drop-ins；`--activate <ts>` 子命令做 symlink swap + 4 cloud services restart + nginx reload；alembic 复用 deploy/linux/scripts/migrate.sh -->
- [x] 10.3 `deploy/cloud/scripts/rollback.sh`：切回历史 release 软链 + 重启服务（不动 schema）  <!-- meta-repo: deploy/cloud/scripts/rollback.sh；`--list` 列 release + active 标记；切 current 软链 + 4 cloud services restart 顺序(scheduler/worker/api/engine) + nginx reload；不动 modem-controller/telephony-api（在 edge）；vendor SDK missing 时 WARN -->
- [x] 10.4 `deploy/cloud/monitoring/`：Prometheus + Grafana + alert rules 模板  <!-- meta-repo: deploy/cloud/monitoring/{README.md, prometheus.yml.example, alert_rules.yml.example, grafana/isales-cloud-edge.json.placeholder}；alert rules 锚 design.md Decision 4 latency budget 800ms + cloud-edge stream/heartbeat 健康度 + ARTC push-audio buffer-full；engine /metrics 实装由 isales-engine 后续 PR 落 -->
- [x] 10.5 RUNBOOK：阿里云资源开通 / 域名 / TLS / RDS 备份恢复演练 / cloud-edge 调试  <!-- meta-repo: deploy/RUNBOOK-cloud.md（与 deploy/RUNBOOK.md single-host 平行），10 章覆盖：阿里云资源开通 / 域名 + Let's Encrypt / 首次部署 / 常规发版 / 回滚 / RDS+Redis+OSS 备份恢复演练 / cloud-edge 调试（gRPC 连通 / token mint / RTC 手工探查）/ 监控告警 / schema rollback 例外 / 应急速查 -->

## 11. 边缘部署脚本与 RUNBOOK

- [x] 11.1 新增 `deploy/edge/` 目录：launchd plist + env.example + vendor 安装脚本  <!-- meta-repo: deploy/edge/{README.md, launchd/com.isales.telephony.plist, env/edge.env.example, scripts/}；单 LaunchAgent 取代 6 个 single-host plist；EnvironmentVariables 指向 ~/.config/isales/edge.env；vendor 安装脚本占位（macOS SDK mock 路径见 8.x obsolete 说明） -->
- [x] 11.2 `deploy/edge/scripts/install.sh`：拉代码 + 装 venv + ARTC SDK 解压 + 注册 launchd  <!-- meta-repo: deploy/edge/scripts/install.sh；5 步：release dir → git clone (isales-common + isales-telephony) → venv (含 scipy for resampler) → LaunchAgent plist (rewrite __HOME__) → bootstrap state dirs + edge.env template；以 LOGIN USER（非 root）跑；ARTC SDK 在 A2 mock 路径下不解压（task 8.1 obsolete 注释提及） -->
- [x] 11.3 `deploy/edge/scripts/rollback.sh` + launchctl kickstart  <!-- meta-repo: deploy/edge/scripts/rollback.sh；`--list` 列 release；切 current 软链 + `launchctl kickstart -k gui/$UID/com.isales.telephony`；SQLite buffer 在用户 state 目录，回滚不丢离线事件 -->
- [x] 11.4 RUNBOOK：边缘机首次配置 / 激活码（A2 用静态 token，多租户由 C2）/ 离线 buffer 排查 / 网络诊断  <!-- meta-repo: deploy/RUNBOOK-edge.md；9 章覆盖：首次配置 / 激活码 + Device Token 签发与轮换（云端 isales-edge-token-mint CLI，A2 静态长 JWT；C2 替换为激活码 → 租户 JWT）/ 常规发版 / 回滚 / SQLite 离线 buffer 排查（sqlite3 查 events 表 + 异常清理）/ 网络诊断（DNS + TLS handshake + grpcurl + mtr）/ 硬件诊断（modem 串口 + AT 命令）/ 日志位置（~/Library/Logs/isales + Apple unified log）/ 应急速查 -->

## 12. 端到端验证

- [ ] 12.1 QA 环境一台 Mac mini + 一台云 ECS：本地拨自己手机 → 听到回声（无 AI 编排，仅验证音频通路）
- [ ] 12.2 接入豆包 ASR/LLM/TTS：拨自己手机 → 听到 AI 念固定开场白 → 挂断 ← **A2 + D1 联合 MVP 验收点**
- [ ] 12.3 端到端 latency 测量 P50 / P95 → 与 design.md Decision 4 budget 对照；如 P95 > 800 ms 触发降级策略（默认 N 角色 = 1）
- [ ] 12.4 故障注入：边缘断网 30 s + cloud engine 重启 + RTC 房间断连 → 验证降级与重连行为符合 spec
- [ ] 12.5 100 seats 压测（QA 环境，模拟边缘）→ 确认单 cloud instance 承载力 + 阿里 RTC SDK 并发上限

## 13. 文档与归档准备

- [x] 13.1 更新 v1-roadmap.md 标注 A2 已 ship + 修正 NAT 穿透段（fallback 路线已用不到）  <!-- meta-repo: openspec/v1-roadmap.md；A2 entry 加 Status 2026-05-15 块（23/63 done + 已 ship 项 + 剩余项 + 归档待 D1 同步）；媒体面从 "WebRTC (aiortc)" 改为 "阿里 RTC PaaS"，删 NAT 穿透 待 PoC 段，并入 ARTC SDK Linux Python + macOS 决策；A2/A3 风险节标注 NAT 穿透项 strikethrough + 新增 ARTC PCM 回调延迟与 macOS SDK 决策两项风险 -->
- [ ] 13.2 更新 PoC 结果文档：把 Day 2 实测数据补到决策表"实测"列
- [ ] 13.3 准备 A2 archive PR：等 D1 也接近完成时一起规划归档（device-hardware / deployment-topology spec delta 冲突需手工 merge）
- [ ] 13.4 整理 A3 `edge-vad-and-opener-prefetch` propose 阶段需要的上下文（cancel 通道接口 + OSS 开场白预渲染目录）
